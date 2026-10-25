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
        guard let location = library?.location, !ids.isEmpty else { return }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.pioneerdj.rekordboxdj").first != nil {
            errorMessage = "Quit Rekordbox before editing your library in Crate, so neither app overwrites the other's changes."
            return
        }
        let needsBackup = !backedUpLibraries.contains(location)
        do {
            try await Task.detached(priority: .userInitiated) {
                if needsBackup {
                    try Self.backUp(location)
                }
                try RekordboxLibrary.saveColor(color, forTrackIDs: ids, in: location)
            }.value
            backedUpLibraries.insert(location)
            library?.applyColor(color, toTrackIDs: ids)
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
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
