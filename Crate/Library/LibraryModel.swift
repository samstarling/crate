import AppKit
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
    private(set) var isApplying = false
    var alert: AppAlert?
    /// The main window's undo manager, so changes can be undone with ⌘Z.
    @ObservationIgnored var undoManager: UndoManager?

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
                undoManager?.removeAllActions(withTarget: self)
            }
            pendingChanges = pendingChanges.compactMap { $0.revalidated(against: saved) }
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

    /// If there are pending changes, asks whether to apply or discard them before `action` (for
    /// example "quitting"), and does so. Returns whether to go ahead: `false` if the user cancels,
    /// or if applying fails (then `alert` says why and the changes stay pending).
    func askToApplyPendingChanges(before action: String) async -> Bool {
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
        pendingChanges.append(staged)
        self.library = library.applying([change])
        undoManager?.registerUndo(withTarget: self) { model in model.discard(staged) }
        undoManager?.setActionName(actionName)
    }

    /// Discards a pending change, so it won't be applied.
    func discard(_ change: StagedChange) {
        pendingChanges.removeAll { $0.id == change.id }
        library = savedLibrary?.applying(pendingChanges.map(\.change))
    }

    func discardAllPendingChanges() {
        pendingChanges = []
        library = savedLibrary
        undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: Applying

    /// Writes every pending change to the library's `master.db`, in one transaction, then reloads.
    ///
    /// If the library has changed since Crate loaded it (in Rekordbox, say), nothing is written:
    /// Crate reloads it and keeps the pending changes, so the user can review and apply them again.
    func applyPendingChanges() async {
        guard let saved = savedLibrary, !pendingChanges.isEmpty, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        let staged = pendingChanges
        let changes = staged.map(\.change)
        let location = saved.location
        let expectedUpdateCount = saved.updateCount
        do {
            let changeSet = try await write(to: location) {
                try RekordboxLibrary.apply(changes, in: location, expectedUpdateCount: expectedUpdateCount)
            }

            let files = changes.flatMap { change -> [URL] in
                guard case .remove(let ids, true) = change else { return [] }
                return ids.compactMap { saved.tracksByID[$0]?.fileURL }
            }
            let (trashed, failures) = await Task.detached(priority: .userInitiated) { Self.moveToTrash(files) }.value

            let applied = AppliedChange(
                summary: staged.count == 1 ? staged[0].summary : "\(staged.count) changes",
                items: staged.count == 1 ? [] : staged.map(\.summary),
                libraryLocation: location,
                changes: changeSet,
                trashedFiles: trashed
            )
            appliedChanges.insert(applied, at: 0)
            pendingChanges = []
            await reload()

            // Undoing now means reverting what was applied, not discarding pending changes.
            undoManager?.removeAllActions(withTarget: self)
            undoManager?.registerUndo(withTarget: self) { model in
                Task { await model.undo(applied) }
            }
            undoManager?.setActionName("Apply Changes")

            if !failures.isEmpty {
                alert = AppAlert(
                    title: "Couldn\u{2019}t Move Files to the Trash",
                    message: "Your changes were applied, but \(failures.formatted()) couldn\u{2019}t be moved to the Trash."
                )
            }
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

    // MARK: Reverting

    /// Reverts applied changes, putting back everything they changed in the library and any files
    /// moved to the Trash. Throws `RekordboxLibrary.CannotRevert` if something they changed has
    /// been changed again since.
    func revert(_ applied: AppliedChange) async throws {
        // Use the latest version: it may have been reverted since this was asked for.
        guard let index = appliedChanges.firstIndex(where: { $0.id == applied.id }), !appliedChanges[index].isReverted else { return }
        let applied = appliedChanges[index]
        _ = try await write(to: applied.libraryLocation) { try RekordboxLibrary.revert(applied.changes, in: applied.libraryLocation) }

        let failures = await Task.detached(priority: .userInitiated) { Self.restoreFromTrash(applied.trashedFiles) }.value
        if let index = appliedChanges.firstIndex(where: { $0.id == applied.id }) {
            appliedChanges[index].revertedAt = .now
        }
        await reload()
        if !failures.isEmpty {
            throw RevertError.filesNotRestored(failures)
        }
    }

    /// Reverts applied changes from Edit ▸ Undo, reporting any problem.
    private func undo(_ applied: AppliedChange) async {
        do {
            try await revert(applied)
        } catch {
            alert = AppAlert(title: "Couldn\u{2019}t Undo", message: error.localizedDescription)
        }
    }

    enum RevertError: LocalizedError {
        case filesNotRestored([String])

        var errorDescription: String? {
            switch self {
            case .filesNotRestored(let files):
                "Your library was restored, but \(files.formatted()) couldn\u{2019}t be put back from the Trash. You can drag them back from the Trash yourself."
            }
        }
    }

    // MARK: Writing safely

    /// Runs `write` against `master.db` in `location`, after backing up the library the first time
    /// this session. Writes run one at a time.
    private func write<T: Sendable>(to location: URL, _ write: @escaping @Sendable () throws -> T) async throws -> T {
        let previous = latestWrite
        let needsBackup = !backedUpLibraries.contains(location)
        let task = Task.detached(priority: .userInitiated) {
            await previous?.value
            if needsBackup {
                try Self.backUp(location)
            }
            return try write()
        }
        latestWrite = Task { _ = await task.result }
        let result = try await task.value
        backedUpLibraries.insert(location)
        return result
    }

    // MARK: Files

    /// Copies `master.db` (and any WAL files) to `~/Library/Application Support/Crate/Backups/<timestamp>/`,
    /// keeping only the most recent backups.
    nonisolated private static func backUp(_ location: URL) throws {
        let fileManager = FileManager.default
        let backups = URL.applicationSupportDirectory.appending(path: "Crate/Backups", directoryHint: .isDirectory)
        let timestamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let destination = backups.appending(path: timestamp, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["master.db", "master.db-wal", "master.db-shm"] {
            let file = location.appending(path: name)
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.copyItem(at: file, to: destination.appending(path: name))
            }
        }

        // Backup folders are named by timestamp, so they sort oldest first.
        let existing = (try? fileManager.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        for old in existing.filter(\.hasDirectoryPath).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).dropLast(backupsToKeep) {
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
