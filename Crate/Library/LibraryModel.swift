import AppKit
import Observation
import RekordboxKit

@Observable
final class LibraryModel {
    private(set) var library: RekordboxLibrary?
    private(set) var isLoading = false
    var errorMessage: String?
    /// Edits made to the open library, newest first.
    private(set) var history: [JournalEntry]
    /// An edit that wasn't saved because the library changed since Crate loaded it, waiting for the
    /// user to decide whether to reload and apply it again.
    var conflictedEdit: LibraryEdit?
    /// The main window's undo manager, so edits can be undone with ⌘Z.
    @ObservationIgnored var undoManager: UndoManager?

    @ObservationIgnored private let journal: Journal
    /// Libraries already backed up this session, so we only back up before the first edit.
    @ObservationIgnored private var backedUpLibraries = Set<URL>()
    /// The most recent edit or revert, so the next one can wait for it.
    @ObservationIgnored private var latestChange: Task<Void, Never>?

    private static let locationDefaultsKey = "LibraryLocation"
    private static let rekordboxBundleIdentifier = "com.pioneerdj.rekordboxdj"
    nonisolated private static let backupsToKeep = 10

    init(library: RekordboxLibrary? = nil, history: [JournalEntry] = [], journal: Journal = Journal()) {
        self.library = library
        self.history = history
        self.journal = journal
    }

    // MARK: Opening

    /// Opens the last library the user picked, falling back to Rekordbox's standard location.
    func openInitialLibrary() async {
        let saved = UserDefaults.standard.string(forKey: Self.locationDefaultsKey).map { URL(filePath: $0, directoryHint: .isDirectory) }
        let folder = saved ?? RekordboxLibrary.defaultLocation
        guard FileManager.default.fileExists(atPath: folder.appending(path: "master.db").path) else { return }
        await open(folder)
    }

    func open(_ folder: URL) async {
        isLoading = true
        defer { isLoading = false }
        do {
            library = try await Task.detached(priority: .userInitiated) {
                try RekordboxLibrary.load(from: folder)
            }.value
            history = journal.entries(forLibraryAt: folder)
            UserDefaults.standard.set(folder.path, forKey: Self.locationDefaultsKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reload() async {
        guard let location = library?.location else { return }
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
        panel.directoryURL = library?.location ?? RekordboxLibrary.defaultLocation

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        await open(folder)
    }

    // MARK: Editing

    /// Saves a colour for the given tracks to `master.db`, then updates the in-memory library.
    func setColor(_ color: TrackColor?, forTrackIDs ids: [Track.ID]) async {
        guard !ids.isEmpty else { return }
        await apply(.setColor(color, trackIDs: ids))
    }

    /// Removes tracks from the collection (and every playlist), optionally moving their audio files
    /// to the Trash, then reloads the library.
    func removeTracks(_ tracks: [Track], movingFilesToTrash: Bool) async {
        guard !tracks.isEmpty else { return }
        await apply(.remove(tracks, movingFilesToTrash: movingFilesToTrash))
    }

    /// Reloads the library after a conflict, then applies the edit again if its tracks are still there.
    func reloadAndApply(_ edit: LibraryEdit) async {
        conflictedEdit = nil
        await reload()
        guard let library else { return }
        guard let edit = edit.revalidated(against: library) else {
            errorMessage = "Your library was reloaded, but the tracks you were changing are no longer in it."
            return
        }
        await apply(edit)
    }

    private func apply(_ edit: LibraryEdit) async {
        await enqueue { await self.perform(edit) }
    }

    private func perform(_ edit: LibraryEdit) async {
        guard let location = library?.location else { return }
        switch edit {
        case .setColor(let color, let ids):
            guard let changes = await save(edit, { location, expected in
                try RekordboxLibrary.saveColor(color, forTrackIDs: ids, in: location, expectedUpdateCount: expected)
            }) else { return }
            library?.applyColor(color, toTrackIDs: ids, updateCount: changes.updateCount)
            record(JournalEntry(summary: edit.summary, libraryLocation: location, changes: changes))

        case .remove(let tracks, let movingFilesToTrash):
            let ids = tracks.map(\.id)
            guard let changes = await save(edit, { location, expected in
                try RekordboxLibrary.removeTracks(withIDs: ids, in: location, expectedUpdateCount: expected)
            }) else { return }

            let files = movingFilesToTrash ? tracks.map(\.fileURL) : []
            let (trashed, failures) = await Task.detached(priority: .userInitiated) { Self.moveToTrash(files) }.value
            record(JournalEntry(summary: edit.summary, libraryLocation: location, changes: changes, trashedFiles: trashed))
            await reload()
            if !failures.isEmpty {
                errorMessage = "Removed from your collection, but couldn\u{2019}t move \(failures.formatted()) to the Trash."
            }
        }
    }

    /// Writes an edit to the library's `master.db`, after checking Rekordbox isn't running and backing
    /// up the library before the first change this session. `change` is given the library's location
    /// and the update count Crate loaded.
    ///
    /// Returns what changed, or `nil` if the edit wasn't saved: then either `errorMessage` says why,
    /// or `conflictedEdit` is set because the library changed since Crate loaded it.
    private func save(_ edit: LibraryEdit, _ change: @escaping @Sendable (URL, Int?) throws -> ChangeSet) async -> ChangeSet? {
        guard let location = library?.location else { return nil }
        let expectedUpdateCount = library?.updateCount
        do {
            return try await write(to: location) { try change(location, expectedUpdateCount) }
        } catch is RekordboxLibrary.LibraryChanged {
            conflictedEdit = edit
            return nil
        } catch {
            errorMessage = "Couldn\u{2019}t save: \(error.localizedDescription)"
            return nil
        }
    }

    /// Saves a journal entry for an edit, and makes it undoable.
    private func record(_ entry: JournalEntry) {
        do {
            try journal.save(entry)
        } catch {
            errorMessage = "Saved, but couldn\u{2019}t record the change, so it can\u{2019}t be undone: \(error.localizedDescription)"
        }
        history.insert(entry, at: 0)
        undoManager?.registerUndo(withTarget: self) { model in
            Task { await model.undo(entry) }
        }
        undoManager?.setActionName(entry.summary)
    }

    // MARK: Reverting

    /// Reverts an edit, putting back everything it changed in the library and any files it moved to
    /// the Trash. Throws if Rekordbox is running, or if something the edit changed has been changed
    /// again since (`RekordboxLibrary.CannotRevert`).
    func revert(_ entry: JournalEntry) async throws {
        var result: Result<Void, any Error> = .success(())
        await enqueue {
            do {
                try await self.performRevert(entry)
            } catch {
                result = .failure(error)
            }
        }
        try result.get()
    }

    /// Reverts an edit from Edit ▸ Undo, reporting any problem in the main window.
    private func undo(_ entry: JournalEntry) async {
        do {
            try await revert(entry)
        } catch {
            errorMessage = "Couldn\u{2019}t undo \(entry.summary.lowercasedFirst): \(error.localizedDescription)"
        }
    }

    private func performRevert(_ entry: JournalEntry) async throws {
        // Use the latest version of the entry: it may have been reverted from the history window
        // since this undo was registered.
        let entry = history.first { $0.id == entry.id } ?? entry
        guard !entry.isReverted else { return }
        _ = try await write(to: entry.libraryLocation) { try RekordboxLibrary.revert(entry.changes, in: entry.libraryLocation) }

        let failures = await Task.detached(priority: .userInitiated) { Self.restoreFromTrash(entry.trashedFiles) }.value
        var reverted = entry
        reverted.revertedAt = .now
        try? journal.save(reverted)
        await reload()
        if !failures.isEmpty {
            throw RevertError.filesNotRestored(failures)
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

    /// Runs changes one at a time. Each edit expects the update count the previous one left behind,
    /// so overlapping edits would otherwise look like someone else changed the library.
    private func enqueue(_ change: @escaping @MainActor () async -> Void) async {
        let previous = latestChange
        let task = Task {
            await previous?.value
            await change()
        }
        latestChange = task
        await task.value
    }

    /// Runs `write` against `master.db` in `location`, once Rekordbox is confirmed closed and the
    /// library has been backed up this session.
    private func write<T: Sendable>(to location: URL, _ write: @escaping @Sendable () throws -> T) async throws -> T {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.rekordboxBundleIdentifier).isEmpty {
            throw RekordboxRunning()
        }
        let needsBackup = !backedUpLibraries.contains(location)
        let result = try await Task.detached(priority: .userInitiated) {
            if needsBackup {
                try Self.backUp(location)
            }
            return try write()
        }.value
        backedUpLibraries.insert(location)
        return result
    }

    struct RekordboxRunning: LocalizedError {
        var errorDescription: String? {
            "Quit Rekordbox before changing your library in Crate, so neither app overwrites the other\u{2019}s changes."
        }
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

private extension String {
    var lowercasedFirst: String {
        prefix(1).lowercased() + dropFirst()
    }
}
