import SwiftUI

struct SidebarView: View {
    let library: RekordboxLibrary
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("Collection", systemImage: "music.note.house")
                    .badge(library.tracks.count)
                    .tag(SidebarItem.collection)
            }

            Section("Playlists") {
                OutlineGroup(library.playlists, children: \.children) { playlist in
                    Label(playlist.name, systemImage: playlist.systemImage)
                        .badge(playlist.kind == .playlist ? playlist.trackIDs.count : 0)
                        .tag(SidebarItem.playlist(playlist.id))
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }
}
