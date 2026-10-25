//
//  CrateApp.swift
//  Crate
//
//  Created by Sam Starling on 24/10/2026.
//

import SwiftUI

@main
struct CrateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var player = PlayerModel()

    private var model: LibraryModel { appDelegate.model }

    /// Undoes (or redoes) typing in the text field being edited, if it has any to undo. Returns
    /// whether it did.
    private static func undoTyping(redo: Bool = false) -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView, let undoManager = textView.undoManager,
              redo ? undoManager.canRedo : undoManager.canUndo else { return false }
        redo ? undoManager.redo() : undoManager.undo()
        return true
    }

    var body: some Scene {
        Window("Crate", id: "main") {
            ContentView()
                .task { await model.openInitialLibrary() }
                .environment(model)
                .environment(player)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Library…") { Task { await model.showOpenPanel() } }
                    .keyboardShortcut("o")
                Button("Reload Library") { Task { await model.reload() } }
                    .keyboardShortcut("r")
                    .disabled(model.library == nil || model.isLoading || model.isWriting)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Apply Changes to Rekordbox") { Task { await model.applyPendingChanges() } }
                    .keyboardShortcut("s")
                    .disabled(model.pendingChanges.isEmpty || model.isWriting)
            }
            CommandGroup(replacing: .undoRedo) {
                // Undo and Redo step through the changes in the Changes view, except while editing
                // text (the search field), which has its own.
                // While searching, typing comes first; otherwise (or once there's no typing to
                // undo) it's the changes.
                Button(model.isEditingText ? "Undo" : model.undoTitle) {
                    if !(model.isEditingText && Self.undoTyping()) { Task { await model.undo() } }
                }
                .keyboardShortcut("z")
                .disabled(!model.isEditingText && !model.canUndo)
                Button(model.isEditingText ? "Redo" : model.redoTitle) {
                    if !(model.isEditingText && Self.undoTyping(redo: true)) { Task { await model.redo() } }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.isEditingText && !model.canRedo)
            }
            CommandMenu("Controls") {
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(player.track == nil)
            }
        }
    }
}
