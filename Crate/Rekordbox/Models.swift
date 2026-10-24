import SwiftUI

nonisolated struct Track: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let genre: String
    let label: String
    let key: String
    /// Beats per minute; 0 when the track hasn't been analysed.
    let bpm: Double
    /// Length in seconds.
    let duration: Int
    /// 0–5 stars.
    let rating: Int
    /// 0 when unknown.
    let year: Int
    /// `yyyy-MM-dd`, as stored by Rekordbox, so it sorts correctly as a string.
    let dateAdded: String
    let playCount: Int
    let color: TrackColor?
    let comment: String
    let fileURL: URL
    let artworkURL: URL?
}

/// Rekordbox's eight fixed track colours. Their display names can be customised, so we keep the label too.
nonisolated struct TrackColor: Hashable, Sendable {
    let id: Int
    let name: String

    var color: Color {
        switch id {
        case 1: .pink
        case 2: .red
        case 3: .orange
        case 4: .yellow
        case 5: .green
        case 6: .cyan
        case 7: .blue
        default: .purple
        }
    }
}

nonisolated struct Playlist: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case playlist, folder, smart
    }

    let id: String
    let name: String
    let kind: Kind
    /// `nil` for anything that isn't a folder, so `List(children:)` doesn't draw a disclosure triangle.
    var children: [Playlist]?
    var trackIDs: [String]

    var systemImage: String {
        switch kind {
        case .playlist: "music.note.list"
        case .folder: "folder"
        case .smart: "gearshape"
        }
    }
}
