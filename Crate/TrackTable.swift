import SwiftUI

struct TrackTable: View {
    let title: String
    let tracks: [Track]
    let library: RekordboxLibrary

    /// Filtered and sorted rows, cached so redraws (e.g. selection changes) don't redo the work.
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
        Table(visibleTracks, selection: $selection, sortOrder: $sortOrder) {
            descriptionColumns
            analysisColumns
            detailColumns
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            Button("Show in Finder") { reveal(ids) }
                .disabled(ids.isEmpty)
        } primaryAction: { ids in
            reveal(ids)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Title, artist, album…")
        .navigationTitle(title)
        .navigationSubtitle(summary(of: visibleTracks))
        .onAppear(perform: refreshVisibleTracks)
        .onChange(of: tracks) { refreshVisibleTracks() }
        .onChange(of: searchText) { refreshVisibleTracks() }
        .onChange(of: sortOrder) { refreshVisibleTracks() }
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var descriptionColumns: some TableColumnContent<Track, KeyPathComparator<Track>> {
        TableColumn("") { track in
            ArtworkView(url: track.artworkURL)
        }
        .width(28)

        TableColumn("Title", value: \.title, comparator: .localizedStandard) { track in
            HStack(spacing: 6) {
                Circle()
                    .fill(track.color?.color ?? .clear)
                    .frame(width: 7, height: 7)
                    .help(track.color?.name ?? "")
                Text(track.title)
            }
        }
        .width(min: 160, ideal: 260)

        TableColumn("Artist", value: \.artist, comparator: .localizedStandard)
            .width(min: 100, ideal: 180)
        TableColumn("Album", value: \.album, comparator: .localizedStandard)
            .width(min: 80, ideal: 160)
        TableColumn("Genre", value: \.genre, comparator: .localizedStandard)
            .width(min: 60, ideal: 110)
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var analysisColumns: some TableColumnContent<Track, KeyPathComparator<Track>> {
        TableColumn("BPM", value: \.bpm) { track in
            Text(track.bpm > 0 ? track.bpm.formatted(.number.precision(.fractionLength(0...2))) : "")
                .monospacedDigit()
        }
        .width(min: 40, ideal: 55)
        .alignment(.trailing)

        TableColumn("Key", value: \.key)
            .width(min: 30, ideal: 45)

        TableColumn("Time", value: \.duration) { track in
            Text(Duration.seconds(track.duration).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
        }
        .width(min: 40, ideal: 50)
        .alignment(.trailing)

        TableColumn("Rating", value: \.rating) { track in
            Text(String(repeating: "★", count: track.rating) + String(repeating: "☆", count: max(0, 5 - track.rating)))
                .foregroundStyle(track.rating > 0 ? .primary : .tertiary)
        }
        .width(min: 60, ideal: 70)

        TableColumn("Year", value: \.year) { track in
            Text(track.year > 0 ? String(track.year) : "")
                .monospacedDigit()
        }
        .width(min: 35, ideal: 45)
    }

    @TableColumnBuilder<Track, KeyPathComparator<Track>>
    private var detailColumns: some TableColumnContent<Track, KeyPathComparator<Track>> {
        TableColumn("Label", value: \.label, comparator: .localizedStandard)
            .width(min: 60, ideal: 120)
        TableColumn("Date Added", value: \.dateAdded)
            .width(min: 70, ideal: 85)
        TableColumn("Plays", value: \.playCount) { track in
            Text(track.playCount > 0 ? String(track.playCount) : "")
                .monospacedDigit()
        }
        .width(min: 35, ideal: 45)
        .alignment(.trailing)
    }

    private func summary(of tracks: [Track]) -> String {
        let totalSeconds = tracks.reduce(0) { $0 + $1.duration }
        let duration = Duration.seconds(totalSeconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
        return "\(tracks.count) tracks · \(duration)"
    }

    private func reveal(_ ids: Set<Track.ID>) {
        let urls = tracks.filter { ids.contains($0.id) }.map(\.fileURL)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// A small artwork thumbnail, loaded lazily from Rekordbox's artwork cache.
struct ArtworkView: View {
    let url: URL?
    @State private var image: NSImage?

    private static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = Self.cache.object(forKey: url as NSURL) {
                image = cached
            } else if let loaded = NSImage(contentsOf: url) {
                Self.cache.setObject(loaded, forKey: url as NSURL)
                image = loaded
            }
        }
    }
}
