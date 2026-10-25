import AppKit
import CryptoKit
import Observation
import RekordboxKit

/// An error or notice to show the user.
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@Observable
final class LibraryModel {
    /// The library as it's saved in `master.db`.
    private(set) var savedLibrary: RekordboxLibrary?
    /// The library with pending changes made, which is what Crate shows.
    private(set) var library: RekordboxLibrary?
    /// Changes made in Crate but not yet applied to the library, oldest first. They're only kept
    /// while Crate is open: quitting asks to apply or discard them.
    private(set) var pendingChanges: [StagedChange]
    /// Changes applied to the open library since Crate opened it, newest first, so they can be reverted.
    private(set) var appliedChanges: [AppliedChange]
    private(set) var isLoading = false
    /// Whether Crate is applying or reverting changes, from writing to the library through moving
    /// files and reloading. Other writes, undo, redo and discarding wait until it's done.
    var isWriting: Bool { operationsInProgress > 0 }
    /// Whether a text field (the search field) is being edited, so Edit ▸ Undo goes to it.
    var isEditingText = false
    var alert: AppAlert?

    /// Steps Edit ▸ Undo goes back through, newest last.
    private(set) var undoSteps: [ChangeStep] = []
    /// Steps Edit ▸ Redo goes forward through, newest last.
    private(set) var redoSteps: [ChangeStep] = []

    private var operationsInProgress = 0
    /// Libraries already backed up this session, so we only back up before the first write.
    @ObservationIgnored private var backedUpLibraries = Set<URL>()
    /// The most recent write, so the next one can wait for it.
    @ObservationIgnored private var latestWrite: Task<Void, Never>?

    private static let locationDefaultsKey = "LibraryLocation"
    nonisolated private static let backupsToKeep = 10

    init(library: RekordboxLibrary? = nil, pendingChanges: [StagedChange] = [], appliedChanges: [AppliedChange] = []) {
        self.savedLibrary = library
        self.library = library?.applying(pendingChanges.map(\.change))
        self.pendingChanges = pendingChanges
        self.appliedChanges = appliedChanges
    }

    // MARK: Opening

    /// Opens the last library the user picked, falling back to Rekordbox's standard location.
    func openInitialLibrary() async {
        let saved = UserDefaults.standard.string(forKey: Self.locationDefaultsKey).map { URL(filePath: $0, directoryHint: .isDirectory) }
        let folder = saved ?? RekordboxLibrary.defaultLocation
        guard FileManager.default.fileExists(atPath: folder.appending(path: "master.db").path) else { return }
        await open(folder)
    }

    /// Opens a library, or reloads the open one. Reloading keeps pending changes, checked against the
    /// library as loaded (dropping any tracks that are no longer in it); opening a different library
    /// starts afresh.
    func open(_ folder: URL) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let saved = try await Task.detached(priority: .userInitiated) {
                try RekordboxLibrary.load(from: folder)
            }.value
            let isReload = savedLibrary?.location.standardizedFileURL == folder.standardizedFileURL
            if !isReload {
                pendingChanges = []
                appliedChanges = []
                undoSteps = []
                redoSteps = []
            }
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
            UserDefaults.standard.set(folder.path, forKey: Self.locationDefaultsKey)
        } catch {
            alert = AppAlert(title: "Couldn\u{2019}t Open Library", message: error.localizedDescription)
        }
    }

    func reload() async {
        guard let location = savedLibrary?.location else { return }
        await open(location)
    }

    func showOpenPanel() async {
        let panel = NSOpenPanel()
        panel.message = "Choose your Rekordbox library folder (the one containing master.db)."
        panel.prompt = "Open Library"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = savedLibrary?.location ?? RekordboxLibrary.defaultLocation

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if folder.standardizedFileURL != savedLibrary?.location.standardizedFileURL {
            guard await askToApplyPendingChanges(before: "opening another library") else { return }
        }
        await open(folder)
    }

    /// Waits for any write in progress, then, if there are pending changes, asks whether to apply or
    /// discard them before `action` (for example "quitting"), and does so. Returns whether to go
    /// ahead: `false` if the user cancels, or if applying fails (then `alert` says why and the
    /// changes stay pending).
    func askToApplyPendingChanges(before action: String) async -> Bool {
        await waitForWrites()
        guard !pendingChanges.isEmpty else { return true }
        let count = pendingChanges.count
        let alert = NSAlert()
        alert.messageText = "Apply \(count == 1 ? "1 change" : "\(count) changes") to your Rekordbox library before \(action)?"
        alert.informativeText = count == 1
            ? "If you don\u{2019}t apply it, it\u{2019}ll be lost."
            : "If you don\u{2019}t apply them, they\u{2019}ll be lost."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await applyPendingChanges()
            return pendingChanges.isEmpty
        case .alertSecondButtonReturn:
            discardAllPendingChanges()
            return true
        default:
            return false
        }
    }

    /// Returns once no write is in progress.
    func waitForWrites() async {
        while isWriting {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Runs `body` with `isWriting` set, so nothing else changes the library or the pending list
    /// meanwhile.
    private func whileWriting<T>(_ body: () async throws -> T) async rethrows -> T {
        operationsInProgress += 1
        defer { operationsInProgress -= 1 }
        return try await body()
    }

    // MARK: Pending changes

    /// Sets the colour of tracks, as a pending change.
    func setColor(_ color: TrackColor?, forTrackIDs ids: [Track.ID]) {
        stage(.setColor(colorID: color?.id, trackIDs: ids), actionName: "Set Colour")
    }

    /// Removes tracks from the collection (and every playlist), as a pending change. Their audio files
    /// are moved to the Trash when the change is applied, if asked.
    func removeTracks(_ tracks: [Track], movingFilesToTrash: Bool) {
        stage(.remove(trackIDs: tracks.map(\.id), movingFilesToTrash: movingFilesToTrash), actionName: "Remove from Collection")
    }

    private func stage(_ change: PendingChange, actionName: String) {
        guard let library, !change.trackIDs.isEmpty else { return }
        let staged = StagedChange(change, summary: change.summary(in: library))
        add([staged])
        record(.stage(staged, actionName: actionName))
    }

    /// Discards pending changes, so they won't be applied. Not while applying: the changes being
    /// written can't be taken back.
    func discard(_ changes: [StagedChange]) {
        guard !isWriting else { return }
        let discarded = remove(changes)
        guard !discarded.isEmpty else { return }
        record(.discard(discarded))
    }

    func discardAllPendingChanges() {
        discard(pendingChanges)
    }

    /// Adds changes to the pending list, at the given positions or the end.
    private func add(_ changes: [StagedChange], at positions: [Int]? = nil) {
        if let positions {
            for (change, position) in zip(changes, positions).sorted(by: { $0.1 < $1.1 }) {
                pendingChanges.insert(change, at: min(position, pendingChanges.count))
            }
        } else {
            pendingChanges.append(contentsOf: changes)
        }
        if positions == nil, let library {
            self.library = library.applying(changes.map(\.change))
        } else {
            library = savedLibrary?.applying(pendingChanges.map(\.change))
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
        library = savedLibrary?.applying(pendingChanges.map(\.change))
        return removed
    }

    // MARK: Applying and reverting

    /// Writes every pending change to the library's `master.db`, in one transaction, then reloads.
    ///
    /// If the library has changed since Crate loaded it (in Rekordbox, say), nothing is written:
    /// Crate reloads it and keeps the pending changes, so the user can review and apply them again.
    func applyPendingChanges() async {
        guard let saved = savedLibrary, !pendingChanges.isEmpty, !isWriting else { return }
        await whileWriting { await apply(pendingChanges, to: saved) }
    }

    private func apply(_ staged: [StagedChange], to saved: RekordboxLibrary) async {
        let stepsBefore = undoSteps.count
        do {
            let (changeSet, trashed) = try await write(staged.map(\.change), to: saved)
            let applied = AppliedChange(
                summary: staged.count == 1 ? staged[0].summary : "\(staged.count) changes",
                items: staged.count == 1 ? [] : staged.map(\.summary),
                libraryLocation: saved.location,
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
            await reload()
        } catch is RekordboxLibrary.LibraryChanged {
            await reload()
            alert = AppAlert(
                title: "Your Library Has Changed",
                message: "Your Rekordbox library has changed since Crate loaded it, probably in Rekordbox, so nothing was applied. Crate has reloaded it, and your changes are still pending: review them in Changes, then apply them again."
            )
        } catch {
            alert = AppAlert(title: "Couldn\u{2019}t Apply Changes", message: error.localizedDescription)
        }
    }

    /// Reverts applied changes, putting back everything they changed in the library and any files
    /// moved to the Trash.
    func revert(_ applied: AppliedChange) async {
        guard !isWriting else { return }
        do {
            if try await whileWriting({ try await performRevert(applied.id) }) {
                record(.revert(applied.id))
            }
        } catch {
            alert = AppAlert(title: "Couldn\u{2019}t Revert", message: error.localizedDescription)
        }
    }

    /// Applies reverted changes again.
    func applyAgain(_ applied: AppliedChange) async {
        guard !isWriting else { return }
        do {
            if try await whileWriting({ try await performApplyAgain(applied.id) }) {
                record(.apply(applied.id))
            }
        } catch {
            alert = AppAlert(title: "Couldn\u{2019}t Apply Again", message: error.localizedDescription)
        }
    }

    /// Returns whether the changes were reverted: not if they already were. Throws
    /// `RekordboxLibrary.CannotRevert` if something they touched has been changed again since.
    @discardableResult
    private func performRevert(_ id: AppliedChange.ID) async throws -> Bool {
        guard let index = appliedChanges.firstIndex(where: { $0.id == id }), !appliedChanges[index].isReverted else { return false }
        let applied = appliedChanges[index]
        _ = try await serialised { try RekordboxLibrary.revert(applied.changes, in: applied.libraryLocation) }
        let failures = await Task.detached(priority: .userInitiated) { Self.restoreFromTrash(applied.trashedFiles) }.value
        if let index = appliedChanges.firstIndex(where: { $0.id == id }) {
            appliedChanges[index].revertedAt = .now
        }
        await reload()
        if !failures.isEmpty {
            alert = AppAlert(
                title: "Couldn\u{2019}t Put Files Back",
                message: "Your library was restored, but \(failures.formatted()) couldn\u{2019}t be put back from the Trash. You can drag them back from the Trash yourself."
            )
        }
        return true
    }

    /// Writes reverted changes again, checked against the library as it is now. Returns whether they
    /// were written: not if they weren't reverted.
    @discardableResult
    private func performApplyAgain(_ id: AppliedChange.ID) async throws -> Bool {
        guard let saved = savedLibrary, let index = appliedChanges.firstIndex(where: { $0.id == id }),
              appliedChanges[index].isReverted else { return false }
        let changes = appliedChanges[index].pendingChanges.compactMap { $0.revalidated(against: saved) }
        guard !changes.isEmpty else {
            throw TracksGone()
        }
        let (changeSet, trashed) = try await write(changes, to: saved)
        if let index = appliedChanges.firstIndex(where: { $0.id == id }) {
            appliedChanges[index].changes = changeSet
            appliedChanges[index].trashedFiles = trashed
            appliedChanges[index].revertedAt = nil
        }
        await reload()
        return true
    }

    /// Writes changes to `saved`'s `master.db`, expecting it to be unchanged since it was loaded,
    /// then moves files to the Trash for removals that ask for it.
    private func write(_ changes: [PendingChange], to saved: RekordboxLibrary) async throws -> (ChangeSet, [TrashedFile]) {
        let location = saved.location
        let expectedUpdateCount = saved.updateCount
        let changeSet = try await serialised {
            try RekordboxLibrary.apply(changes, in: location, expectedUpdateCount: expectedUpdateCount)
        }
        let files = changes.flatMap { change -> [URL] in
            guard case .remove(let ids, true) = change else { return [] }
            return ids.compactMap { saved.tracksByID[$0]?.fileURL }
        }
        let (trashed, failures) = await Task.detached(priority: .userInitiated) { Self.moveToTrash(files) }.value
        if !failures.isEmpty {
            alert = AppAlert(
                title: "Couldn\u{2019}t Move Files to the Trash",
                message: "Your changes were applied, but \(failures.formatted()) couldn\u{2019}t be moved to the Trash."
            )
        }
        return (changeSet, trashed)
    }

    struct TracksGone: LocalizedError {
        var errorDescription: String? { "The tracks these changes affected are no longer in your library." }
    }

    // MARK: Undo and redo

    /// A step in the history of changes. Undo and redo move back and forth through these, so they
    /// always match what the Changes view shows.
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

        /// Whether undoing or redoing this step writes to the library.
        var writes: Bool {
            switch self {
            case .stage, .discard: false
            case .apply, .revert: true
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
    var canUndo: Bool { !isWriting && !undoSteps.isEmpty }
    var canRedo: Bool { !isWriting && !redoSteps.isEmpty }
    var undoTitle: String { undoSteps.last.map { "Undo \($0.actionName)" } ?? "Undo" }
    var redoTitle: String { redoSteps.last.map { "Redo \($0.actionName)" } ?? "Redo" }

    /// Records a step the user just took, which clears anything that could be redone.
    private func record(_ step: ChangeStep) {
        undoSteps.append(step)
        redoSteps = []
    }

    func undo() async {
        guard canUndo, let step = undoSteps.popLast() else { return }
        do {
            try await whileWriting { try await perform(step, undoing: true) }
            redoSteps.append(step)
        } catch {
            undoSteps.append(step)
            alert = AppAlert(title: "Couldn\u{2019}t \(undoTitle)", message: error.localizedDescription)
        }
    }

    func redo() async {
        guard canRedo, let step = redoSteps.popLast() else { return }
        do {
            try await whileWriting { try await perform(step, undoing: false) }
            undoSteps.append(step)
        } catch {
            redoSteps.append(step)
            alert = AppAlert(title: "Couldn\u{2019}t \(redoTitle)", message: error.localizedDescription)
        }
    }

    private func perform(_ step: ChangeStep, undoing: Bool) async throws {
        switch (step, undoing) {
        case (.stage(let change, _), true): _ = remove([change])
        case (.stage(let change, _), false): add([change])
        case (.discard(let changes), true): add(changes.map(\.change), at: changes.map(\.position))
        case (.discard(let changes), false): _ = remove(changes.map(\.change))
        case (.apply(let id), true), (.revert(let id), false): try await performRevert(id)
        case (.apply(let id), false), (.revert(let id), true): try await performApplyAgain(id)
        }
    }

    // MARK: Writing safely

    /// Runs `write` against the library, one write at a time, after backing up the library the
    /// first time this session.
    private func serialised<T: Sendable>(_ write: @escaping @Sendable () throws -> T) async throws -> T {
        guard let location = savedLibrary?.location else { throw CancellationError() }
        let previous = latestWrite
        let task = Task {
            await previous?.value
            // Recorded before backing up, so a queued write doesn't back up again; forgotten if it fails.
            if backedUpLibraries.insert(location).inserted {
                do {
                    try await Task.detached(priority: .userInitiated) { try Self.backUp(location) }.value
                } catch {
                    backedUpLibraries.remove(location)
                    throw error
                }
            }
            return try await Task.detached(priority: .userInitiated) { try write() }.value
        }
        latestWrite = Task { _ = await task.result }
        return try await task.value
    }

    // MARK: Files

    /// Copies `master.db` (and any WAL files) to `~/Library/Application Support/Crate/Backups/<library>/<time>/`,
    /// keeping each library's first backup (from before Crate changed anything) and its most recent ones.
    nonisolated private static func backUp(_ location: URL) throws {
        let fileManager = FileManager.default
        let digest = SHA256.hash(data: Data(location.standardizedFileURL.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let backups = URL.applicationSupportDirectory.appending(path: "Crate/Backups/\(digest)", directoryHint: .isDirectory)
        let timestamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeSeparator(.omitted))
        var destination = backups.appending(path: timestamp, directoryHint: .isDirectory)
        var attempt = 1
        while fileManager.fileExists(atPath: destination.path) {
            attempt += 1
            destination = backups.appending(path: "\(timestamp)-\(attempt)", directoryHint: .isDirectory)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["master.db", "master.db-wal", "master.db-shm"] {
            let file = location.appending(path: name)
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.copyItem(at: file, to: destination.appending(path: name))
            }
        }

        // Backup folders are named by time, so they sort oldest first.
        let existing = (try? fileManager.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        let sorted = existing.filter(\.hasDirectoryPath).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in sorted.dropFirst().dropLast(backupsToKeep) {
            try? fileManager.removeItem(at: old)
        }
    }

    /// Moves files to the Trash, returning where each went and the names of any that couldn't be moved.
    nonisolated private static func moveToTrash(_ files: [URL]) -> (trashed: [TrashedFile], failures: [String]) {
        var trashed: [TrashedFile] = []
        var failures: [String] = []
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            var inTrash: NSURL?
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: &inTrash)
                if let inTrash = inTrash as URL? {
                    trashed.append(TrashedFile(original: file, inTrash: inTrash))
                }
            } catch {
                failures.append(file.lastPathComponent)
            }
        }
        return (trashed, failures)
    }

    /// Moves files back from the Trash, returning the names of any that couldn't be.
    nonisolated private static func restoreFromTrash(_ files: [TrashedFile]) -> [String] {
        files.compactMap { file in
            let fileManager = FileManager.default
            guard !fileManager.fileExists(atPath: file.original.path) else { return nil }
            do {
                try fileManager.createDirectory(at: file.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: file.inTrash, to: file.original)
                return nil
            } catch {
                return file.original.lastPathComponent
            }
        }
    }
}
