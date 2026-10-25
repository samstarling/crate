import Foundation

/// An ID3v1 tag: the 128 bytes at the end of an MP3, starting with "TAG", with fixed-length
/// Latin-1 fields. ID3v1.1 takes the last two bytes of the comment for a track number.
public struct ID3v1Tag: Sendable, Equatable {
    public let title: String
    public let artist: String
    public let album: String
    public let year: String
    public let comment: String
    /// Only in ID3v1.1 tags.
    public let track: Int?
    /// An index into `id3v1Genres`, or `nil` if unset.
    public let genre: Int?

    public init(title: String, artist: String, album: String, year: String, comment: String, track: Int?, genre: Int?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.comment = comment
        self.track = track
        self.genre = genre
    }

    /// Reads the ID3v1 tag from the end of a file, or returns `nil` if it doesn't have one.
    public static func read(from url: URL) throws -> ID3v1Tag? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 128 else { return nil }
        try handle.seek(toOffset: fileSize - 128)
        return try handle.read(upToCount: 128).flatMap { ID3v1Tag(bytes: [UInt8]($0)) }
    }

    /// Parses a tag from its 128 bytes, or returns `nil` if they aren't one.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 128, bytes.starts(with: "TAG".utf8) else { return nil }
        func field(_ range: Range<Int>) -> String {
            let text = bytes[range].prefix { $0 != 0 }
            return (String(bytes: text, encoding: .isoLatin1) ?? "").trimmingCharacters(in: .whitespaces)
        }
        // In ID3v1.1, a zero before the comment's last byte means that byte is the track number.
        let hasTrack = bytes[125] == 0 && bytes[126] != 0
        self.init(
            title: field(3..<33),
            artist: field(33..<63),
            album: field(63..<93),
            year: field(93..<97),
            comment: field(hasTrack ? 97..<125 : 97..<127),
            track: hasTrack ? Int(bytes[126]) : nil,
            genre: bytes[127] == 255 ? nil : Int(bytes[127])
        )
    }
}
