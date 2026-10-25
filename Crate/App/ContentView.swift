//
//  ContentView.swift
//  Crate
//
//  Created by Sam Starling on 24/10/2026.
//

import RekordboxKit
import SwiftUI

enum SidebarItem: Hashable {
    case collection
    case changes
    case playlist(String)
}

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @State private var selection: SidebarItem? = .collection

    var body: some View {
        // Below the split view rather than over it, so it never covers the bottom of the content.
        VStack(spacing: 0) {
            Group {
                if let library = model.library {
                    NavigationSplitView {
                        SidebarView(library: library, pendingChangeCount: model.pendingChanges.count, selection: $selection)
                    } detail: {
                        detail(for: library)
                    }
                } else if model.isLoading {
                    ProgressView("Loading library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("No Library", systemImage: "music.note.house")
                    } description: {
                        Text("Open a Rekordbox library folder to browse your collection.")
                    } actions: {
                        Button("Open Library…") { Task { await model.showOpenPanel() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            PlayerBar()
        }
        .frame(minWidth: 900, minHeight: 500)
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
        .alert(
            "Couldn't play track",
            isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(player.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func detail(for library: RekordboxLibrary) -> some View {
        switch selection {
        case .playlist(let id):
            if let playlist = library.playlist(withID: id) {
                switch playlist.kind {
                case .playlist:
                    TrackTable(title: playlist.name, tracks: library.tracks(in: playlist), library: library)
                        .id(playlist.id)
                case .smart:
                    switch Result(catching: { try library.smartTracks(in: playlist) }) {
                    case .success(let tracks):
                        TrackTable(title: playlist.name, tracks: tracks, library: library)
                            .id(playlist.id)
                    case .failure(let error):
                        ContentUnavailableView(
                            "Can\u{2019}t Show \u{201C}\(playlist.name)\u{201D}",
                            systemImage: "gearshape",
                            description: Text(error.localizedDescription)
                        )
                    }
                case .folder:
                    ContentUnavailableView(playlist.name, systemImage: "folder", description: Text("Select a playlist."))
                }
            }
        case .changes:
            ChangesView()
        case .collection, nil:
            TrackTable(title: "Collection", tracks: library.tracks, library: library)
                .id("collection")
        }
    }
}

#Preview("Library", traits: .sampleData) {
    ContentView()
}

#Preview("No library") {
    ContentView()
        .environment(LibraryModel())
        .environment(PlayerModel())
}
