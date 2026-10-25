import Foundation

/// A FLAC file's tags: its Vorbis comments and pictures.
///
/// A FLAC file is "fLaC" then metadata blocks, each with a one-byte type (whose top bit marks the
/// last block) and a three-byte big-endian length (see https://xiph.org/flac/format.html).
public struct FLACTags: Sendable, Equatable {
    public struct Tag: Sendable, Equatable {
        /// A Vorbis comment's field name, such as `TITLE`, or `PICTURE` for a picture block.
        public let key: String
        /// A picture's description; empty for comments.
        public let description: String
        public let value: TagValue

        public init(key: String, description: String = "", value: TagValue) {
            self.key = key
            self.description = description
            self.value = value
        }
    }

    /// The software that wrote the comments, such as "reference libFLAC 1.4.3".
    public let vendor: String
    /// Comments and pictures, in the order they appear.
    public let tags: [Tag]

    public init(vendor: String, tags: [Tag]) {
        self.vendor = vendor
        self.tags = tags
    }

    private static let vorbisCommentBlock: UInt8 = 4
    private static let pictureBlock: UInt8 = 6

    /// Reads the tags from a FLAC file, or returns `nil` if it isn't one. Only the comment and
    /// picture blocks are read, not the audio.
    public static func read(from url: URL) throws -> FLACTags? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // Some taggers put an ID3v2 tag before "fLaC".
        var offset: UInt64 = 0
        guard var start = try handle.read(upToCount: 10).map(Array.init), start.count >= 4 else { return nil }
        if start.count == 10, start.starts(with: "ID3".utf8) {
            offset = UInt64(ID3Tag.length(ofTagWithHeader: start))
            try handle.seek(toOffset: offset)
            start = try handle.read(upToCount: 4).map(Array.init) ?? []
        }
        guard start.starts(with: "fLaC".utf8) else { return nil }
        offset += 4

        var vendor = ""
        var tags: [Tag] = []
        while true {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 4).map(Array.init), header.count == 4 else { break }
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = header[1..<4].bigEndianValue
            offset += 4 + UInt64(length)

            if type == vorbisCommentBlock || type == pictureBlock {
                let block = [UInt8](try handle.read(upToCount: length) ?? Data())
                guard block.count == length else { break }
                if type == vorbisCommentBlock, let comments = vorbisComments(block) {
                    vendor = comments.vendor
                    tags += comments.tags
                } else if type == pictureBlock, let picture = picture(block) {
                    tags.append(picture)
                }
            }
            if isLast { break }
        }
        return FLACTags(vendor: vendor, tags: tags)
    }

    /// A Vorbis comment block: a vendor string, then `KEY=value` strings, each prefixed with its
    /// little-endian length (see https://xiph.org/vorbis/doc/v-comment.html).
    static func vorbisComments(_ block: [UInt8]) -> (vendor: String, tags: [Tag])? {
        var position = 0
        func littleEndian() -> Int? {
            guard position + 4 <= block.count else { return nil }
            defer { position += 4 }
            return block[position..<position + 4].littleEndianValue
        }
        func string() -> String? {
            guard let length = littleEndian(), position + length <= block.count else { return nil }
            defer { position += length }
            return String(decoding: block[position..<position + length], as: UTF8.self)
        }

        guard let vendor = string(), let count = littleEndian() else { return nil }
        var tags: [Tag] = []
        for _ in 0..<count {
            guard let comment = string() else { break }
            let parts = comment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            // Field names are case-insensitive.
            let key = parts[0].uppercased()
            let value = parts.count > 1 ? String(parts[1]) : ""
            tags.append(Tag(key: key, value: .text([value])))
        }
        return (vendor, tags)
    }

    /// A picture block: picture type, MIME type, description, dimensions, then the image, with
    /// big-endian lengths.
    static func picture(_ block: [UInt8]) -> Tag? {
        var position = 0
        func bigEndian() -> Int? {
            guard position + 4 <= block.count else { return nil }
            defer { position += 4 }
            return block[position..<position + 4].bigEndianValue
        }
        func bytes() -> ArraySlice<UInt8>? {
            guard let length = bigEndian(), position + length <= block.count else { return nil }
            defer { position += length }
            return block[position..<position + length]
        }

        guard bigEndian() != nil, bytes() != nil, let description = bytes() else { return nil } // Picture type, MIME type
        position += 16 // Width, height, colour depth and palette size
        guard let data = bytes() else { return nil }
        return Tag(key: "PICTURE", description: String(decoding: description, as: UTF8.self), value: .picture(Data(data)))
    }
}
