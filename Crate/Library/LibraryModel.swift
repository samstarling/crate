import AppKit
import Observation
import RekordboxKit

/// An error or notice to show the user.
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// The app's side of an open library: opening and reloading it, and turning what its
/// `LibrarySession` reports into alerts and prompts.
@Observable
final class LibraryModel {
    private(set) var session: LibrarySession?
    private(set) var isLoading = false
    /// The view whose text field (a search field) is being edited, if any, so Edit ▸ Undo goes to it.
    /// Views claim and release it by ID, so one disappearing can't clear another's claim.
    private(set) var textEditor: UUID?
    var isEditingText: Bool { textEditor != nil }
    var alert: AppAlert?

    @ObservationIgnored private let files: FileOperations
    private static let locationDefaultsKey = "LibraryLocation"

    init(session: LibrarySession? = nil, files: FileOperations = .live()) {
        self.session = session
        self.files = files
    }

    // MARK: State

    /// The library with pending changes made, which is what Crate shows.
    var library: RekordboxLibrary? { session?.library }
    var pendingChanges: [StagedChange] { session?.pendingChanges ?? [] }
    var appliedChanges: [AppliedChange] { session?.appliedChanges ?? [] }
    var isWriting: Bool { session?.isWriting ?? false }
    var canUndo: Bool { session?.canUndo ?? false }
    var canRedo: Bool { session?.canRedo ?? false }
    var undoTitle: String { session?.undoActionName.map { "Undo \($0)" } ?? "Undo" }
    var redoTitle: String { session?.redoActionName.map { "Redo \($0)" } ?? "Redo" }

    // MARK: Opening

    /// Opens the last library the user picked, falling back to Rekordbox's standard location.
    func openInitialLibrary() async {
        let saved = UserDefaults.standard.string(forKey: Self.locationDefaultsKey).map { URL(filePath: $0, directoryHint: .isDirectory) }
        let folder = saved ?? RekordboxLibrary.defaultLocation
        guard FileManager.default.fileExists(atPath: folder.appending(path: "master.db").path) else { return }
        await open(folder)
    }

    /// Opens a library, starting afresh: changes pending for another library are gone. Opening the
    /// library that's already open reloads it instead, keeping its changes.
    func open(_ folder: URL) async {
        if folder.standardizedFileURL == session?.location.standardizedFileURL {
            await reload()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            session = try await LibrarySession.open(folder, files: files)
            UserDefaults.standard.set(folder.path, forKey: Self.locationDefaultsKey)
        } catch {
            alert = AppAlert(title: "Couldn\u{2019}t Open Library", message: error.localizedDescription)
        }
    }

    /// Loads the open library again, keeping pending changes.
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await session?.reload()
        } catch {
            alert = AppAlert(title: "Couldn\u{2019}t Reload Library", message: error.localizedDescription)
        }
    }

    func showOpenPanel() async {
        let panel = NSOpenPanel()
        panel.message = "Choose your Rekordbox library folder (the one containing master.db)."
        panel.prompt = "Open Library"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = session?.location ?? RekordboxLibrary.defaultLocation

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if folder.standardizedFileURL != session?.location.standardizedFileURL {
            guard await askToApplyPendingChanges(before: "opening another library") else { return }
        }
        await open(folder)
    }

    /// Waits for any write in progress, then, if there are pending changes, asks whether to apply or
    /// discard them before `action` (for example "quitting"), and does so. Returns whether to go
    /// ahead: `false` if the user cancels, or if applying fails (then `alert` says why and the
    /// changes stay pending).
    func askToApplyPendingChanges(before action: String) async -> Bool {
        await session?.waitForWrites()
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

    // MARK: Changes

    func setColor(_ color: TrackColor?, forTrackIDs ids: [Track.ID]) {
        session?.setColor(color, forTrackIDs: ids)
    }

    func removeTracks(_ tracks: [Track], movingFilesToTrash: Bool) {
        session?.removeTracks(withIDs: tracks.map(\.id), movingFilesToTrash: movingFilesToTrash)
    }

    func discard(_ changes: [StagedChange]) {
        session?.discard(changes)
    }

    func discardAllPendingChanges() {
        session?.discardAllPendingChanges()
    }

    func applyPendingChanges() async {
        await run("Couldn\u{2019}t Apply Changes") { try await $0.applyPendingChanges() }
    }

    func revert(_ applied: AppliedChange) async {
        await run("Couldn\u{2019}t Revert") { try await $0.revert(applied.id) }
    }

    func applyAgain(_ applied: AppliedChange) async {
        await run("Couldn\u{2019}t Apply Again") { try await $0.applyAgain(applied.id) }
    }

    func undo() async {
        await run("Couldn\u{2019}t \(undoTitle)") { try await $0.undo() }
    }

    func redo() async {
        await run("Couldn\u{2019}t \(redoTitle)") { try await $0.redo() }
    }

    /// Runs something on the session, showing an alert titled `failureTitle` if it fails.
    private func run(_ failureTitle: String, _ body: (LibrarySession) async throws -> LibrarySession.WriteReport) async {
        guard let session else { return }
        do {
            report(try await body(session))
        } catch is RekordboxLibrary.LibraryChanged {
            alert = AppAlert(
                title: "Your Library Has Changed",
                message: "Your Rekordbox library has changed since Crate loaded it, probably in Rekordbox, so nothing was changed. Crate has reloaded it, and your changes are still pending: review them in Changes, then try again."
            )
        } catch {
            alert = AppAlert(title: failureTitle, message: error.localizedDescription)
        }
    }

    /// Marks a view's text field as being edited, or not.
    func setEditingText(_ isEditing: Bool, in view: UUID) {
        if isEditing {
            textEditor = view
        } else if textEditor == view {
            textEditor = nil
        }
    }

    /// Tells the user about anything that went wrong after a write that succeeded.
    private func report(_ files: LibrarySession.WriteReport) {
        if let reason = files.notReloaded {
            alert = AppAlert(
                title: "Couldn\u{2019}t Reload Library",
                message: "Your changes were saved, but Crate couldn\u{2019}t load your library again, so what it shows may be out of date. Try File \u{25B8} Reload Library. (\(reason))"
            )
        } else if !files.notMovedToTrash.isEmpty {
            alert = AppAlert(
                title: "Couldn\u{2019}t Move Files to the Trash",
                message: "Your library was changed, but \(files.notMovedToTrash.formatted()) couldn\u{2019}t be moved to the Trash."
            )
        } else if !files.notRestored.isEmpty {
            alert = AppAlert(
                title: "Couldn\u{2019}t Put Files Back",
                message: "Your library was restored, but \(files.notRestored.formatted()) couldn\u{2019}t be put back from the Trash. You can drag them back from the Trash yourself."
            )
        }
    }
}
