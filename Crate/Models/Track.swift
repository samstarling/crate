import Foundation

nonisolated struct Track: Identifiable, Hashable, Sendable {
    let id: String
    /// Position in `RekordboxLibrary.tracks`, used to look up precomputed sort ranks.
    let libraryIndex: Int
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
    /// When the track was added to the collection (`StockDate`), as `yyyy-MM-dd` so it sorts as a string.
    let dateAdded: String
    let playCount: Int
    var color: TrackColor?
    let comment: String
    let fileURL: URL
    let artworkURL: URL?
    /// The track's `ANLZ0000.EXT` analysis file, which holds its colour waveform.
    let analysisURL: URL?
    /// Memory cue positions in seconds, in order. (Hot cues aren't included.)
    let memoryCues: [Double]
    /// IDs of the My Tags applied to this track.
    let myTagIDs: [String]

    var memoryCueCount: Int { memoryCues.count }

    /// Orders tracks by colour in Rekordbox's order, with uncoloured tracks last.
    var colorSortKey: Int { color?.id ?? .max }
}
