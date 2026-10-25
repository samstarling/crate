import AppKit

/// Owns the library, so that quitting can ask to apply or discard pending changes first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LibraryModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.pendingChanges.isEmpty else { return .terminateNow }
        Task {
            let shouldQuit = await model.askToApplyPendingChanges(before: "quitting")
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }
}
