import AppKit
import Observation

@Observable
final class LibraryModel {
    private(set) var library: RekordboxLibrary?
    private(set) var isLoading = false
    var errorMessage: String?

    private static let locationDefaultsKey = "LibraryLocation"

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
