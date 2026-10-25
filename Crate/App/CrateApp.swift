//
//  CrateApp.swift
//  Crate
//
//  Created by Sam Starling on 24/10/2026.
//

import Sparkle
import SwiftUI

@main
struct CrateApp: App {
    @State private var model = LibraryModel()
    @State private var player = PlayerModel()
    private let updater = Updater()

    var body: some Scene {
        Window("Crate", id: "main") {
            ContentView()
                .task { await model.openInitialLibrary() }
                .environment(model)
                .environment(player)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Library…") { Task { await model.showOpenPanel() } }
                    .keyboardShortcut("o")
                Button("Reload Library") { Task { await model.reload() } }
                    .keyboardShortcut("r")
                    .disabled(model.library == nil || model.isLoading)
            }
            CommandMenu("Controls") {
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(player.track == nil)
            }
        }
    }
}
