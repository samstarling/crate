import Foundation

public struct Track: Identifiable, Hashable, Sendable {
    public let id: String
    /// Position in `RekordboxLibrary.tracks`, used to look up precomputed sort ranks.
    public internal(set) var libraryIndex: Int
    public let title: String
    public let artist: String
    public let album: String
    public let genre: String
    public let label: String
    public let key: String
    /// Beats per minute; 0 when the track hasn't been analysed.
    public let bpm: Double
    /// Length in seconds.
    public let duration: Int
    /// 0–5 stars.
    public let rating: Int
    /// 0 when unknown.
    public let year: Int
    /// When the track was added to the collection (`StockDate`), as `yyyy-MM-dd` so it sorts as a string.
    public let dateAdded: String
    public let playCount: Int
    public var color: TrackColor?
    public let comment: String
    public let fileURL: URL
    public let artworkURL: URL?
    /// The track's `ANLZ0000.EXT` analysis file, which holds its colour waveform.
    public let analysisURL: URL?
    /// Memory cue positions in seconds, in order. (Hot cues aren't included.)
    public let memoryCues: [Double]
    /// IDs of the My Tags applied to this track.
    public let myTagIDs: [String]

    public init(
        id: String,
        libraryIndex: Int,
        title: String,
        artist: String,
        album: String,
        genre: String,
        label: String,
        key: String,
        bpm: Double,
        duration: Int,
        rating: Int,
        year: Int,
        dateAdded: String,
        playCount: Int,
        color: TrackColor?,
        comment: String,
        fileURL: URL,
        artworkURL: URL?,
        analysisURL: URL?,
        memoryCues: [Double],
        myTagIDs: [String]
    ) {
        self.id = id
        self.libraryIndex = libraryIndex
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.label = label
        self.key = key
        self.bpm = bpm
        self.duration = duration
        self.rating = rating
        self.year = year
        self.dateAdded = dateAdded
        self.playCount = playCount
        self.color = color
        self.comment = comment
        self.fileURL = fileURL
        self.artworkURL = artworkURL
        self.analysisURL = analysisURL
        self.memoryCues = memoryCues
        self.myTagIDs = myTagIDs
    }

    public var memoryCueCount: Int { memoryCues.count }

    /// The audio file's path.
    public var location: String { fileURL.path(percentEncoded: false) }

    /// Orders tracks by colour in Rekordbox's order, with uncoloured tracks last.
    public var colorSortKey: Int { color?.id ?? .max }
}
