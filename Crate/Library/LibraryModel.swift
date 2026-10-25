import AppKit
import Observation
import RekordboxKit

@Observable
final class LibraryModel {
    private(set) var library: RekordboxLibrary?
    private(set) var isLoading = false
    var errorMessage: String?

    private static let locationDefaultsKey = "LibraryLocation"

    init(library: RekordboxLibrary? = nil) {
        self.library = library
    }

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
            UserDefaults.standard.set(folder.path, forKey: Self.locationDefaultsKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Libraries already backed up this session, so we only back up before the first edit.
    @ObservationIgnored private var backedUpLibraries = Set<URL>()

    /// An edit that wasn't saved because the library changed since Crate loaded it, waiting for the
    /// user to decide whether to reload and apply it again.
    var conflictedEdit: LibraryEdit?

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

    /// The most recent edit, so the next one can wait for it.
    @ObservationIgnored private var latestEdit: Task<Void, Never>?

    /// Applies edits one at a time. Each expects the update count the previous one left behind, so
    /// overlapping edits would otherwise look like someone else changed the library.
    private func apply(_ edit: LibraryEdit) async {
        let previous = latestEdit
        let task = Task {
            await previous?.value
            await perform(edit)
        }
        latestEdit = task
        await task.value
    }

    private func perform(_ edit: LibraryEdit) async {
        switch edit {
        case .setColor(let color, let ids):
            guard let updateCount = await save(edit, { location, expected in
                try RekordboxLibrary.saveColor(color, forTrackIDs: ids, in: location, expectedUpdateCount: expected)
            }) else { return }
            library?.applyColor(color, toTrackIDs: ids, updateCount: updateCount)

        case .remove(let tracks, let movingFilesToTrash):
            let ids = tracks.map(\.id)
            guard await save(edit, { location, expected in
                try RekordboxLibrary.removeTracks(withIDs: ids, in: location, expectedUpdateCount: expected)
            }) != nil else { return }

            let files = movingFilesToTrash ? tracks.map(\.fileURL) : []
            let trashFailures = await Task.detached(priority: .userInitiated) {
                files.compactMap { file -> String? in
                    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                    do {
                        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                        return nil
                    } catch {
                        return file.lastPathComponent
                    }
                }
            }.value
            await reload()
            if !trashFailures.isEmpty {
                errorMessage = "Removed from your collection, but couldn\u{2019}t move \(trashFailures.formatted()) to the Trash."
            }
        }
    }

    /// Writes an edit to the library's `master.db`, after checking Rekordbox isn't running and backing
    /// up the library before the first change this session. `change` is given the library's location
    /// and the update count Crate loaded, and returns the new one.
    ///
    /// Returns the new update count, or `nil` if the edit wasn't saved: then either `errorMessage`
    /// says why, or `conflictedEdit` is set because the library changed since Crate loaded it.
    private func save(_ edit: LibraryEdit, _ change: @escaping @Sendable (URL, Int?) throws -> Int) async -> Int? {
        guard let location = library?.location else { return nil }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.pioneerdj.rekordboxdj").first != nil {
            errorMessage = "Quit Rekordbox before editing your library in Crate, so neither app overwrites the other's changes."
            return nil
        }
        let expectedUpdateCount = library?.updateCount
        let needsBackup = !backedUpLibraries.contains(location)
        do {
            let updateCount = try await Task.detached(priority: .userInitiated) {
                if needsBackup {
                    try Self.backUp(location)
                }
                return try change(location, expectedUpdateCount)
            }.value
            backedUpLibraries.insert(location)
            return updateCount
        } catch is RekordboxLibrary.LibraryChanged {
            conflictedEdit = edit
            return nil
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
            return nil
        }
    }

    /// Copies `master.db` (and any WAL files) to `~/Library/Application Support/Crate/Backups/<timestamp>/`.
    nonisolated private static func backUp(_ location: URL) throws {
        let fileManager = FileManager.default
        let timestamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let destination = URL.applicationSupportDirectory
            .appending(path: "Crate/Backups/\(timestamp)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["master.db", "master.db-wal", "master.db-shm"] {
            let file = location.appending(path: name)
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.copyItem(at: file, to: destination.appending(path: name))
            }
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
}
