import AppKit
import Observation

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

    /// Saves a colour for the given tracks to `master.db`, then updates the in-memory library.
    func setColor(_ color: TrackColor?, forTrackIDs ids: [Track.ID]) async {
        guard !ids.isEmpty else { return }
        let saved = await editLibrary { location in
            try RekordboxLibrary.saveColor(color, forTrackIDs: ids, in: location)
        }
        if saved {
            library?.applyColor(color, toTrackIDs: ids)
        }
    }

    /// Removes tracks from the collection (and every playlist), optionally moving their audio files
    /// to the Trash, then reloads the library.
    func removeTracks(_ tracks: [Track], movingFilesToTrash: Bool) async {
        guard !tracks.isEmpty else { return }
        let ids = tracks.map(\.id)
        let files = movingFilesToTrash ? tracks.map(\.fileURL) : []
        let removed = await editLibrary { location in
            try RekordboxLibrary.removeTracks(withIDs: ids, in: location)
        }
        guard removed else { return }

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

    /// Runs a change to the library's `master.db`, after checking Rekordbox isn't running and backing
    /// up the library before the first change this session. Returns whether the change was saved.
    private func editLibrary(_ change: @escaping @Sendable (URL) throws -> Void) async -> Bool {
        guard let location = library?.location else { return false }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.pioneerdj.rekordboxdj").first != nil {
            errorMessage = "Quit Rekordbox before editing your library in Crate, so neither app overwrites the other's changes."
            return false
        }
        let needsBackup = !backedUpLibraries.contains(location)
        do {
            try await Task.detached(priority: .userInitiated) {
                if needsBackup {
                    try Self.backUp(location)
                }
                try change(location)
            }.value
            backedUpLibraries.insert(location)
            return true
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
            return false
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
