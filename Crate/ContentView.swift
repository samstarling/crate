//
//  ContentView.swift
//  Crate
//
//  Created by Sam Starling on 24/10/2026.
//

import SwiftUI

enum SidebarItem: Hashable {
    case collection
    case playlist(String)
}

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @State private var selection: SidebarItem? = .collection

    var body: some View {
        @Bindable var model = model

        Group {
            if let library = model.library {
                NavigationSplitView {
                    SidebarView(library: library, selection: $selection)
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
        .frame(minWidth: 900, minHeight: 500)
        .task { await model.openInitialLibrary() }
        .alert(
            "Couldn't open library",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
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
                    ContentUnavailableView(
                        "Smart Playlists Aren't Supported Yet",
                        systemImage: "gearshape",
                        description: Text("Rekordbox stores \u{201C}\(playlist.name)\u{201D} as a set of rules rather than a list of tracks.")
                    )
                case .folder:
                    ContentUnavailableView(playlist.name, systemImage: "folder", description: Text("Select a playlist."))
                }
            }
        case .collection, nil:
            TrackTable(title: "Collection", tracks: library.tracks, library: library)
                .id("collection")
        }
    }
}
