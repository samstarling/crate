import AppKit

/// Owns the library, so that quitting can ask to apply or discard pending changes first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LibraryModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting mid-write would lose it, so wait for any write to finish first.
        guard !model.pendingChanges.isEmpty || model.isWriting else { return .terminateNow }
        Task {
            let shouldQuit = await model.askToApplyPendingChanges(before: "quitting")
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }
}
