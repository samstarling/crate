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
    @State private var trackSelection = Set<Track.ID>()
    @AppStorage(TagInspector.visibilityKey) private var showsTagInspector = false

    var body: some View {
        // Below the split view rather than over it, so it never covers the bottom of the content.
        VStack(spacing: 0) {
            mainContent
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
    private var mainContent: some View {
        if let library = model.library {
            NavigationSplitView {
                // Each playlist starts with nothing selected. Clearing it in the same update as the
                // playlist changes means the new table never shows the old selection.
                SidebarView(library: library, pendingChangeCount: model.pendingChanges.count, selection: Binding(get: { selection }, set: {
                    selection = $0
                    trackSelection = []
                }))
            } detail: {
                detail(for: library)
                    .inspector(isPresented: $showsTagInspector) {
                        TagInspector(selectedTracks: trackSelection.compactMap { library.tracksByID[$0] })
                            .inspectorColumnWidth(min: 240, ideal: 300, max: 480)
                    }
                    .toolbar {
                        Button {
                            showsTagInspector.toggle()
                        } label: {
                            Label("Tags", systemImage: "sidebar.trailing")
                        }
                        .help(showsTagInspector ? "Hide Tags" : "Show Tags")
                    }
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

    @ViewBuilder
    private func detail(for library: RekordboxLibrary) -> some View {
        switch selection {
        case .playlist(let id):
            if let playlist = library.playlist(withID: id) {
                switch playlist.kind {
                case .playlist:
                    TrackTable(title: playlist.name, tracks: library.tracks(in: playlist), library: library, selection: $trackSelection)
                        .id(playlist.id)
                case .smart:
                    switch Result(catching: { try library.smartTracks(in: playlist) }) {
                    case .success(let tracks):
                        TrackTable(title: playlist.name, tracks: tracks, library: library, selection: $trackSelection)
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
            TrackTable(title: "Collection", tracks: library.tracks, library: library, selection: $trackSelection)
                .id("collection")
        }
    }
}

#Preview("Library", traits: .sampleData) {
    ContentView()
}

#Preview("No library") {
    ContentView()
        .environment(LibraryModel(files: .none))
        .environment(PlayerModel())
}
