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

    /// Sends an undo or redo to the text field being edited, if there is one. Returns whether there was.
    private static func sendToTextField(_ action: Selector) -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView, let undoManager = textView.undoManager else { return false }
        action == #selector(UndoManager.undo) ? undoManager.undo() : undoManager.redo()
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
                    .disabled(model.library == nil || model.isLoading)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Apply Changes to Rekordbox") { Task { await model.applyPendingChanges() } }
                    .keyboardShortcut("s")
                    .disabled(model.pendingChanges.isEmpty || model.isWriting)
            }
            CommandGroup(replacing: .undoRedo) {
                // Undo and Redo step through the changes in the Changes view, except while editing
                // text (the search field), which has its own.
                Button(model.undoTitle) {
                    if !Self.sendToTextField(#selector(UndoManager.undo)) { Task { await model.undo() } }
                }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
                Button(model.redoTitle) {
                    if !Self.sendToTextField(#selector(UndoManager.redo)) { Task { await model.redo() } }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
            }
            CommandMenu("Controls") {
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(player.track == nil)
            }
        }
    }
}
