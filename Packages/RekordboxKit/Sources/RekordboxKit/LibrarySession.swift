import Foundation
import Observation

/// An open library and the changes made to it in Crate.
///
/// Changes are staged first: they show in `library` straight away, but nothing touches `master.db`
/// until they're applied. Applied changes can be reverted (and applied again) until the session
/// ends. Undo and redo move through the same history, so they always match the pending and applied
/// lists.
@MainActor @Observable
public final class LibrarySession {
    /// The library as it's saved in `master.db`.
    public private(set) var savedLibrary: RekordboxLibrary
    /// The library with pending changes made, which is what to show.
    public private(set) var library: RekordboxLibrary
    /// Changes not yet applied, oldest first.
    public private(set) var pendingChanges: [StagedChange]
    /// Changes applied this session, newest first.
    public private(set) var appliedChanges: [AppliedChange]
    /// Whether changes are being applied or reverted, from writing to the library through moving
    /// files and reloading. Other writes, undo, redo and discarding wait until it's done.
    public var isWriting: Bool { operationsInProgress > 0 }

    /// Steps undo goes back through, newest last.
    private(set) var undoSteps: [ChangeStep] = []
    /// Steps redo goes forward through, newest last.
    private(set) var redoSteps: [ChangeStep] = []
    private var operationsInProgress = 0

    @ObservationIgnored private let files: FileOperations
    @ObservationIgnored private var isBackedUp = false
    /// The most recent write, so the next one can wait for it.
    @ObservationIgnored private var latestWrite: Task<Void, Never>?

    public init(library: RekordboxLibrary, pendingChanges: [StagedChange] = [], appliedChanges: [AppliedChange] = [], files: FileOperations) {
        self.savedLibrary = library
        self.library = library.applying(pendingChanges.map(\.change))
        self.pendingChanges = pendingChanges
        self.appliedChanges = appliedChanges
        self.files = files
    }

    /// Loads the library in `folder` and starts a session for it.
    public static func open(_ folder: URL, files: FileOperations) async throws -> LibrarySession {
        let library = try await Task.detached(priority: .userInitiated) { try RekordboxLibrary.load(from: folder) }.value
        return LibrarySession(library: library, files: files)
    }

    public var location: URL { savedLibrary.location }

    /// Loads the library again, keeping pending changes and the undo history, checked against it:
    /// tracks that are no longer in the library are dropped from them.
    public func reload() async throws {
        let location = location
        let saved = try await Task.detached(priority: .userInitiated) { try RekordboxLibrary.load(from: location) }.value
        pendingChanges = pendingChanges.compactMap { $0.revalidated(against: saved) }
        undoSteps = undoSteps.compactMap { $0.revalidated(against: saved) }
        redoSteps = redoSteps.compactMap { $0.revalidated(against: saved) }
        // Undoing a stage step removes its change from the pending list, so it has to be there.
        let pendingIDs = Set(pendingChanges.map(\.id))
        undoSteps.removeAll { step in
            if case .stage(let change, _) = step { !pendingIDs.contains(change.id) } else { false }
        }
        savedLibrary = saved
        library = saved.applying(pendingChanges.map(\.change))
    }

    /// Returns once no write is in progress.
    public func waitForWrites() async {
        while isWriting {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Pending changes

    /// Sets the colour of tracks, as a pending change.
    public func setColor(_ color: TrackColor?, forTrackIDs ids: [Track.ID]) {
        stage(.setColor(colorID: color?.id, trackIDs: ids), actionName: "Set Colour")
    }

    /// Removes tracks from the collection (and every playlist), as a pending change. Their audio files
    /// are moved to the Trash when the change is applied, if asked.
    public func removeTracks(withIDs ids: [Track.ID], movingFilesToTrash: Bool) {
        stage(.remove(trackIDs: ids, movingFilesToTrash: movingFilesToTrash), actionName: "Remove from Collection")
    }

    private func stage(_ change: PendingChange, actionName: String) {
        guard !change.trackIDs.isEmpty else { return }
        let staged = StagedChange(change, summary: change.summary(in: library))
        add([staged])
        record(.stage(staged, actionName: actionName))
    }

    /// Discards pending changes, so they won't be applied. Not while applying: the changes being
    /// written can't be taken back.
    public func discard(_ changes: [StagedChange]) {
        guard !isWriting else { return }
        let discarded = remove(changes)
        guard !discarded.isEmpty else { return }
        record(.discard(discarded))
    }

    public func discardAllPendingChanges() {
        discard(pendingChanges)
    }

    /// Adds changes to the pending list, at the given positions or the end.
    private func add(_ changes: [StagedChange], at positions: [Int]? = nil) {
        if let positions {
            for (change, position) in zip(changes, positions).sorted(by: { $0.1 < $1.1 }) {
                pendingChanges.insert(change, at: min(position, pendingChanges.count))
            }
            library = savedLibrary.applying(pendingChanges.map(\.change))
        } else {
            pendingChanges.append(contentsOf: changes)
            library = library.applying(changes.map(\.change))
        }
    }

    /// Removes changes from the pending list, returning those that were in it with their positions.
    private func remove(_ changes: [StagedChange]) -> [PositionedChange] {
        let ids = Set(changes.map(\.id))
        let removed = pendingChanges.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { PositionedChange(change: $0.element, position: $0.offset) }
        guard !removed.isEmpty else { return [] }
        pendingChanges.removeAll { ids.contains($0.id) }
        library = savedLibrary.applying(pendingChanges.map(\.change))
        return removed
    }

    // MARK: Applying and reverting

    /// Audio files that couldn't be moved to the Trash or back. The library itself was still changed.
    public struct FileReport: Sendable {
        public var notMovedToTrash: [String] = []
        public var notRestored: [String] = []
        public var isEmpty: Bool { notMovedToTrash.isEmpty && notRestored.isEmpty }
    }

    /// Writes every pending change to `master.db`, in one transaction, then reloads.
    ///
    /// If the library has changed since it was loaded (in Rekordbox, say), nothing is written: the
    /// session reloads, keeps the pending changes, and throws `RekordboxLibrary.LibraryChanged`.
    @discardableResult
    public func applyPendingChanges() async throws -> FileReport {
        guard !pendingChanges.isEmpty, !isWriting else { return FileReport() }
        return try await whileWriting { try await apply(pendingChanges) }
    }

    private func apply(_ staged: [StagedChange]) async throws -> FileReport {
        let stepsBefore = undoSteps.count
        let (changeSet, trashed, report): (ChangeSet, [TrashedFile], FileReport)
        do {
            (changeSet, trashed, report) = try await write(staged.map(\.change))
        } catch let error as RekordboxLibrary.LibraryChanged {
            try? await reload()
            throw error
        }
        let applied = AppliedChange(
            summary: staged.count == 1 ? staged[0].summary : "\(staged.count) changes",
            items: staged.count == 1 ? [] : staged.map(\.summary),
            libraryLocation: location,
            pendingChanges: staged.map(\.change),
            changes: changeSet,
            trashedFiles: trashed
        )
        appliedChanges.insert(applied, at: 0)
        // Only the changes that were applied: more may have been staged while writing.
        let appliedIDs = Set(staged.map(\.id))
        pendingChanges.removeAll { appliedIDs.contains($0.id) }
        // Changes staged while writing come after applying, so undo takes them back first.
        let stagedWhileWriting = Array(undoSteps.dropFirst(stepsBefore))
        undoSteps.removeLast(stagedWhileWriting.count)
        // Staging the applied changes is now part of applying them, so undo reverts the whole batch.
        undoSteps.removeAll { step in
            if case .stage(let change, _) = step { appliedIDs.contains(change.id) } else { false }
        }
        record(.apply(applied.id))
        undoSteps.append(contentsOf: stagedWhileWriting)
        try await reload()
        return report
    }

    /// Reverts applied changes, putting back everything they changed in the library and any files
    /// moved to the Trash. Throws `RekordboxLibrary.CannotRevert` if something they touched has been
    /// changed again since.
    @discardableResult
    public func revert(_ id: AppliedChange.ID) async throws -> FileReport {
        guard !isWriting else { return FileReport() }
        let report = try await whileWriting { try await performRevert(id) }
        if report != nil {
            record(.revert(id))
        }
        return report ?? FileReport()
    }

    /// Applies reverted changes again, checked against the library as it is now.
    @discardableResult
    public func applyAgain(_ id: AppliedChange.ID) async throws -> FileReport {
        guard !isWriting else { return FileReport() }
        let report = try await whileWriting { try await performApplyAgain(id) }
        if report != nil {
            record(.apply(id))
        }
        return report ?? FileReport()
    }

    /// Returns `nil` if the changes were already reverted.
    private func performRevert(_ id: AppliedChange.ID) async throws -> FileReport? {
        guard let index = appliedChanges.firstIndex(where: { $0.id == id }), !appliedChanges[index].isReverted else { return nil }
        let applied = appliedChanges[index]
        let location = location
        _ = try await serialised { try RekordboxLibrary.revert(applied.changes, in: location) }
        let restoreFromTrash = files.restoreFromTrash
        let failures = await Task.detached(priority: .userInitiated) { restoreFromTrash(applied.trashedFiles) }.value
        if let index = appliedChanges.firstIndex(where: { $0.id == id }) {
            appliedChanges[index].revertedAt = .now
        }
        try await reload()
        return FileReport(notRestored: failures)
    }

    /// Returns `nil` if the changes weren't reverted.
    private func performApplyAgain(_ id: AppliedChange.ID) async throws -> FileReport? {
        guard let index = appliedChanges.firstIndex(where: { $0.id == id }), appliedChanges[index].isReverted else { return nil }
        let changes = appliedChanges[index].pendingChanges.compactMap { $0.revalidated(against: savedLibrary) }
        guard !changes.isEmpty else { throw TracksGone() }
        let (changeSet, trashed, report) = try await write(changes)
        if let index = appliedChanges.firstIndex(where: { $0.id == id }) {
            appliedChanges[index].changes = changeSet
            appliedChanges[index].trashedFiles = trashed
            appliedChanges[index].revertedAt = nil
        }
        try await reload()
        return report
    }

    /// Thrown when applying reverted changes again, if none of their tracks are left.
    public struct TracksGone: LocalizedError {
        public var errorDescription: String? { "The tracks these changes affected are no longer in your library." }
    }

    /// Writes changes to `master.db`, expecting it to be unchanged since it was loaded, then moves
    /// files to the Trash for removals that ask for it.
    private func write(_ changes: [PendingChange]) async throws -> (ChangeSet, [TrashedFile], FileReport) {
        let saved = savedLibrary
        let changeSet = try await serialised {
            try RekordboxLibrary.apply(changes, in: saved.location, expectedUpdateCount: saved.updateCount)
        }
        let paths = changes.flatMap { change -> [URL] in
            guard case .remove(let ids, true) = change else { return [] }
            return ids.compactMap { saved.tracksByID[$0]?.fileURL }
        }
        let moveToTrash = files.moveToTrash
        let (trashed, failures) = await Task.detached(priority: .userInitiated) { moveToTrash(paths) }.value
        return (changeSet, trashed, FileReport(notMovedToTrash: failures))
    }

    // MARK: Undo and redo

    /// A step in the history of changes. Undo and redo move back and forth through these.
    enum ChangeStep {
        case stage(StagedChange, actionName: String)
        case discard([PositionedChange])
        case apply(AppliedChange.ID)
        case revert(AppliedChange.ID)

        var actionName: String {
            switch self {
            case .stage(_, let actionName): actionName
            case .discard(let changes): changes.count == 1 ? "Discard Change" : "Discard Changes"
            case .apply: "Apply Changes"
            case .revert: "Revert"
            }
        }

        /// The same step against a reloaded library, with its changes checked the way pending
        /// changes are; `nil` if none of its changes are left.
        func revalidated(against library: RekordboxLibrary) -> ChangeStep? {
            switch self {
            case .stage(let change, let actionName):
                return change.revalidated(against: library).map { .stage($0, actionName: actionName) }
            case .discard(let changes):
                let kept = changes.compactMap { positioned in
                    positioned.change.revalidated(against: library).map { PositionedChange(change: $0, position: positioned.position) }
                }
                return kept.isEmpty ? nil : .discard(kept)
            case .apply, .revert:
                return self
            }
        }
    }

    struct PositionedChange {
        let change: StagedChange
        let position: Int
    }

    // Nothing can be undone or redone while applying or reverting: the pending list and the
    // library are both changing.
    public var canUndo: Bool { !isWriting && !undoSteps.isEmpty }
    public var canRedo: Bool { !isWriting && !redoSteps.isEmpty }
    /// What undo would do, for example "Set Colour" or "Apply Changes".
    public var undoActionName: String? { undoSteps.last?.actionName }
    public var redoActionName: String? { redoSteps.last?.actionName }

    /// Records a step the user just took, which clears anything that could be redone.
    private func record(_ step: ChangeStep) {
        undoSteps.append(step)
        redoSteps = []
    }

    /// Undoes the latest step. If it fails, the step stays to be undone.
    @discardableResult
    public func undo() async throws -> FileReport {
        guard canUndo, let step = undoSteps.popLast() else { return FileReport() }
        do {
            let report = try await whileWriting { try await perform(step, undoing: true) }
            redoSteps.append(step)
            return report
        } catch {
            undoSteps.append(step)
            throw error
        }
    }

    /// Redoes the latest undone step. If it fails, the step stays to be redone.
    @discardableResult
    public func redo() async throws -> FileReport {
        guard canRedo, let step = redoSteps.popLast() else { return FileReport() }
        do {
            let report = try await whileWriting { try await perform(step, undoing: false) }
            undoSteps.append(step)
            return report
        } catch {
            redoSteps.append(step)
            throw error
        }
    }

    private func perform(_ step: ChangeStep, undoing: Bool) async throws -> FileReport {
        switch (step, undoing) {
        case (.stage(let change, _), true): _ = remove([change])
        case (.stage(let change, _), false): add([change])
        case (.discard(let changes), true): add(changes.map(\.change), at: changes.map(\.position))
        case (.discard(let changes), false): _ = remove(changes.map(\.change))
        case (.apply(let id), true), (.revert(let id), false): return try await performRevert(id) ?? FileReport()
        case (.apply(let id), false), (.revert(let id), true): return try await performApplyAgain(id) ?? FileReport()
        }
        return FileReport()
    }

    // MARK: Writing safely

    /// Runs `body` with `isWriting` set.
    private func whileWriting<T>(_ body: () async throws -> T) async rethrows -> T {
        operationsInProgress += 1
        defer { operationsInProgress -= 1 }
        return try await body()
    }

    /// Runs `write` against the library, one write at a time, after backing it up the first time.
    private func serialised<T: Sendable>(_ write: @escaping @Sendable () throws -> T) async throws -> T {
        let location = location
        let backUp = files.backUp
        let previous = latestWrite
        let task = Task {
            await previous?.value
            // Recorded before backing up, so a queued write doesn't back up again; forgotten if it fails.
            if !isBackedUp {
                isBackedUp = true
                do {
                    try await Task.detached(priority: .userInitiated) { try backUp(location) }.value
                } catch {
                    isBackedUp = false
                    throw error
                }
            }
            return try await Task.detached(priority: .userInitiated) { try write() }.value
        }
        latestWrite = Task { _ = await task.result }
        return try await task.value
    }
}
