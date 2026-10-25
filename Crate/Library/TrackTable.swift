import RekordboxKit
import SwiftUI

struct TrackTable: View {
    let title: String
    let tracks: [Track]
    let library: RekordboxLibrary
    @Binding var selection: Set<Track.ID>

    @Environment(LibraryModel.self) private var model
    @Environment(PlayerModel.self) private var player

    /// Filtered and sorted rows, cached so redraws don't redo the work.
    @State private var visibleTracks: [Track] = []
    /// Empty means "playlist order".
    @State private var sortOrder: [KeyPathComparator<Track>] = []
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    /// Identifies this table to the model while its search field is being edited.
    @State private var id = UUID()
    /// Tracks waiting for the user to confirm removing them from the collection.
    @State private var tracksToRemove: [Track]?

    private func refreshVisibleTracks() {
        var result = tracks
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { track in
                [track.title, track.artist, track.album, track.genre, track.label, track.comment]
                    .contains { $0.localizedStandardContains(query) }
            }
        }
        if let comparator = sortOrder.first {
            result = library.sorted(result, by: comparator)
        }
        visibleTracks = result
    }

    var body: some View {
        TrackTableView(
            tracks: visibleTracks,
            colors: library.colors,
            sortOrder: $sortOrder,
            selection: $selection,
            onPlay: { player.play($0) },
            onTogglePlayback: { player.togglePlayPause() },
            onSetColor: { ids, color in model.setColor(color, forTrackIDs: ids) },
            onRemove: { tracksToRemove = $0 }
        )
            .searchable(text: $searchText, placement: .toolbar, prompt: "Title, artist, album…")
            .searchFocused($isSearchFocused)
            .onChange(of: isSearchFocused) { model.setEditingText(isSearchFocused, in: id) }
            .onDisappear { model.setEditingText(false, in: id) }
            .navigationTitle(title)
            .navigationSubtitle(summary(of: visibleTracks))
            .onAppear(perform: refreshVisibleTracks)
            .onChange(of: tracks) { refreshVisibleTracks() }
            .onChange(of: searchText) { refreshVisibleTracks() }
            .onChange(of: sortOrder) { refreshVisibleTracks() }
            .alert(
                removalTitle,
                isPresented: Binding(get: { tracksToRemove != nil }, set: { if !$0 { tracksToRemove = nil } }),
                presenting: tracksToRemove
            ) { tracks in
                Button("Remove and Move to Trash", role: .destructive) {
                    model.removeTracks(tracks, movingFilesToTrash: true)
                }
                Button("Remove from Collection Only") {
                    model.removeTracks(tracks, movingFilesToTrash: false)
                }
                Button("Cancel", role: .cancel) {}
            } message: { tracks in
                Text(removalMessage(for: tracks))
            }
    }

    private var removalTitle: String {
        guard let tracks = tracksToRemove else { return "" }
        return tracks.count == 1
            ? "Remove \u{201C}\(tracks[0].title)\u{201D} from your collection?"
            : "Remove \(tracks.count) tracks from your collection?"
    }

    private func removalMessage(for tracks: [Track]) -> String {
        let pronoun = tracks.count == 1 ? "it" : "them"
        let playlists = library.playlistCount(containing: Set(tracks.map(\.id)))
        let fromPlaylists = switch playlists {
        case 0: ""
        case 1: "1 playlist and "
        default: "\(playlists) playlists and "
        }
        return "This also removes \(pronoun) from \(fromPlaylists)any play history, when you apply your changes. "
            + "Until then, you can undo it or discard it in Changes."
    }

    private func summary(of tracks: [Track]) -> String {
        let totalSeconds = tracks.reduce(0) { $0 + $1.duration }
        let duration = Duration.seconds(totalSeconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
        return "\(tracks.count) tracks · \(duration)"
    }
}

#Preview(traits: .sampleData) {
    @Previewable @State var selection = Set<Track.ID>()
    NavigationStack {
        TrackTable(title: "Collection", tracks: RekordboxLibrary.preview.tracks, library: .preview, selection: $selection)
    }
    .frame(width: 1100, height: 300)
}
