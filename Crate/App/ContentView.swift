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
    case playlist(String)
}

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @State private var selection: SidebarItem? = .collection
    @State private var trackSelection = Set<Track.ID>()
    @AppStorage(TagInspector.visibilityKey) private var showsTagInspector = false

    var body: some View {
        // The player bar sits below everything rather than in a safe area inset, which the sidebar
        // and inspector columns draw underneath.
        VStack(spacing: 0) {
            mainContent
            PlayerBar()
        }
        .frame(minWidth: 900, minHeight: 500)
        .alert(
            "Couldn't open library",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Your Library Has Changed",
            isPresented: Binding(get: { model.conflictedEdit != nil }, set: { if !$0 { model.conflictedEdit = nil } }),
            presenting: model.conflictedEdit
        ) { edit in
            Button("Reload and Apply") { Task { await model.reloadAndApply(edit) } }
            Button("Reload Without Applying") { Task { await model.reload() } }
            Button("Cancel", role: .cancel) {}
        } message: { edit in
            Text("\(edit.summary) wasn\u{2019}t saved, because your Rekordbox library has changed since Crate loaded it, probably in Rekordbox. Crate can reload the library and then apply your change.")
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
                SidebarView(library: library, selection: Binding(get: { selection }, set: {
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
        .environment(LibraryModel())
        .environment(PlayerModel())
}
