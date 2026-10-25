import SwiftUI

struct TrackTable: View {
    let title: String
    let tracks: [Track]
    let library: RekordboxLibrary

    @Environment(LibraryModel.self) private var model

    /// Filtered and sorted rows, cached so redraws don't redo the work.
    @State private var visibleTracks: [Track] = []
    @State private var selection = Set<Track.ID>()
    /// Empty means "playlist order".
    @State private var sortOrder: [KeyPathComparator<Track>] = []
    @State private var searchText = ""

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
            onSetColor: { ids, color in Task { await model.setColor(color, forTrackIDs: ids) } }
        )
            .searchable(text: $searchText, placement: .toolbar, prompt: "Title, artist, album…")
            .navigationTitle(title)
            .navigationSubtitle(summary(of: visibleTracks))
            .onAppear(perform: refreshVisibleTracks)
            .onChange(of: tracks) { refreshVisibleTracks() }
            .onChange(of: searchText) { refreshVisibleTracks() }
            .onChange(of: sortOrder) { refreshVisibleTracks() }
    }

    private func summary(of tracks: [Track]) -> String {
        let totalSeconds = tracks.reduce(0) { $0 + $1.duration }
        let duration = Duration.seconds(totalSeconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
        return "\(tracks.count) tracks · \(duration)"
    }
}
