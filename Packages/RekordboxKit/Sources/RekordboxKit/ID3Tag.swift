import Foundation

/// An ID3v2 tag (v2.2, v2.3 or v2.4), read straight from an audio file's bytes.
///
/// Found at the start of MP3s, or in an `ID3 ` chunk of AIFF and WAV files
/// (see https://id3.org/id3v2.4.0-structure and https://id3.org/id3v2.4.0-frames).
public struct ID3Tag: Sendable, Equatable {
    public struct Frame: Sendable, Equatable {
        /// The frame ID as it appears in the file, such as `TIT2` (or `TT2` in ID3v2.2).
        public let id: String
        /// What some frames say about themselves, such as a `TXXX` frame's name or a `PRIV` frame's owner.
        public let description: String
        public let value: TagValue

        public init(id: String, description: String = "", value: TagValue) {
            self.id = id
            self.description = description
            self.value = value
        }

        /// The ID3v2.3/2.4 equivalent of `id`, so ID3v2.2 frames can be treated like later ones.
        public var canonicalID: String { ID3Tag.v22FrameIDs[id] ?? id }
    }

    /// 2, 3 or 4, for ID3v2.2, v2.3 or v2.4.
    public let majorVersion: Int
    public let frames: [Frame]

    /// Reads the ID3v2 tag from an MP3, AIFF or WAV file, or returns `nil` if it doesn't have one.
    /// The tag is normally at the start of an MP3, but ID3v2.4 also allows one at the end.
    public static func read(from url: URL) throws -> ID3Tag? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let start = try handle.read(upToCount: 12).map(Array.init), start.count == 12 else { return nil }

        let offset: UInt64
        if start.starts(with: "ID3".utf8) {
            offset = 0
        } else if start.starts(with: "FORM".utf8), ["AIFF", "AIFC"].contains(String(decoding: start[8..<12], as: UTF8.self)) {
            guard let chunk = try findID3Chunk(in: handle, littleEndian: false) else { return nil }
            offset = chunk
        } else if start.starts(with: "RIFF".utf8), String(decoding: start[8..<12], as: UTF8.self) == "WAVE" {
            guard let chunk = try findID3Chunk(in: handle, littleEndian: true) else { return nil }
            offset = chunk
        } else {
            guard let appended = try findAppendedTag(in: handle) else { return nil }
            offset = appended
        }

        try handle.seek(toOffset: offset)
        guard let header = try handle.read(upToCount: 10), header.count == 10, header.starts(with: "ID3".utf8) else { return nil }
        let body = try handle.read(upToCount: syncsafe([UInt8](header)[6..<10])) ?? Data()
        return ID3Tag(data: header + body)
    }

    /// Finds an ID3v2.4 tag appended to the end of the file, which has a footer ("3DI" then the same
    /// fields as the header) so it can be found from the end. It may be followed by an ID3v1 tag.
    private static func findAppendedTag(in handle: FileHandle) throws -> UInt64? {
        let fileSize = try handle.seekToEnd()
        for end in [fileSize, fileSize >= 128 ? fileSize - 128 : 0] where end >= 20 {
            try handle.seek(toOffset: end - 10)
            guard let footer = try handle.read(upToCount: 10).map(Array.init), footer.count == 10,
                  footer.starts(with: "3DI".utf8) else { continue }
            let tagLength = UInt64(length(ofTagWithHeader: footer))
            if tagLength <= end {
                return end - tagLength
            }
        }
        return nil
    }

    /// The length of a tag, including its header and any footer, given its header (or footer).
    static func length(ofTagWithHeader header: [UInt8]) -> Int {
        let hasFooter = header[5] & 0x10 != 0
        return 10 + syncsafe(header[6..<10]) + (hasFooter ? 10 : 0)
    }

    /// Walks an AIFF (big-endian) or WAV (little-endian) file's chunks, returning where the `ID3 `
    /// chunk's data starts.
    private static func findID3Chunk(in handle: FileHandle, littleEndian: Bool) throws -> UInt64? {
        var offset: UInt64 = 12
        try handle.seek(toOffset: offset)
        while let header = try handle.read(upToCount: 8).map(Array.init), header.count == 8 {
            let sizeBytes = littleEndian ? header[4..<8].reversed() : Array(header[4..<8])
            let size = UInt64(sizeBytes.bigEndianValue)
            if String(decoding: header[0..<4], as: UTF8.self).lowercased() == "id3 " {
                return offset + 8
            }
            // Chunks are padded to an even length.
            offset += 8 + size + size % 2
            try handle.seek(toOffset: offset)
        }
        return nil
    }

    public init(majorVersion: Int, frames: [Frame]) {
        self.majorVersion = majorVersion
        self.frames = frames
    }

    /// Parses a tag from its bytes, starting with the "ID3" header. Returns `nil` if they aren't an
    /// ID3v2 tag. Stops at the first malformed frame, keeping the frames before it.
    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, bytes.starts(with: "ID3".utf8), (2...4).contains(bytes[3]) else { return nil }
        let version = Int(bytes[3])
        let flags = bytes[5]
        let tagUnsynchronised = flags & 0x80 != 0
        var body = Array(bytes[10..<min(bytes.count, 10 + Self.syncsafe(bytes[6..<10]))])

        // ID3v2.2's compression flag never had a scheme defined, so its frames can't be read.
        if version == 2 && flags & 0x40 != 0 {
            self.init(majorVersion: version, frames: [])
            return
        }
        // Before v2.4, unsynchronisation applies to the whole tag; in v2.4 it's applied per frame.
        if tagUnsynchronised && version < 4 {
            body = Self.resynchronise(body[...])
        }

        var offset = 0
        if version >= 3 && flags & 0x40 != 0 && body.count >= 4 {
            // The extended header's size excludes itself in v2.3, and includes itself in v2.4.
            offset = version == 3 ? 4 + body[0..<4].bigEndianValue : Self.syncsafe(body[0..<4])
        }

        let idLength = version == 2 ? 3 : 4
        let headerLength = version == 2 ? 6 : 10
        var frames: [Frame] = []
        while offset + headerLength <= body.count, Self.isFrameID(body[offset..<offset + idLength]) {
            let id = String(decoding: body[offset..<offset + idLength], as: UTF8.self)
            let sizeBytes = body[offset + idLength..<offset + idLength + (version == 2 ? 3 : 4)]
            let start = offset + headerLength
            let size = version == 4 ? Self.v24FrameSize(sizeBytes, frameStart: start, in: body) : sizeBytes.bigEndianValue
            guard start + size <= body.count else { break }
            offset = start + size

            var content = body[start..<start + size]
            var isReadable = true
            if version == 3 {
                let format = body[start - 1]
                // Compressed or encrypted frames are kept as they are.
                isReadable = format & 0xC0 == 0
                if format & 0x20 != 0 { content = content.dropFirst() } // Group ID
            } else if version == 4 {
                let format = body[start - 1]
                isReadable = format & 0x0C == 0
                if format & 0x40 != 0 { content = content.dropFirst() } // Group ID
                if format & 0x04 != 0 { content = content.dropFirst() } // Encryption method
                if format & 0x01 != 0 { content = content.dropFirst(4) } // Data length indicator
                if tagUnsynchronised || format & 0x02 != 0 {
                    content = Self.resynchronise(content)[...]
                }
            }

            let frame = isReadable
                ? Self.frame(id: id, content: content, version: version)
                : Frame(id: id, value: .binary(Data(content)))
            frames.append(frame)
        }
        self.init(majorVersion: version, frames: frames)
    }

    // MARK: Frames

    private static func frame(id: String, content: ArraySlice<UInt8>, version: Int) -> Frame {
        let canonicalID = v22FrameIDs[id] ?? id
        var reader = Reader(bytes: content)

        switch canonicalID {
        case "TXXX":
            let encoding = reader.byte()
            let description = reader.string(encoding)
            return Frame(id: id, description: description, value: .text(reader.strings(encoding)))
        case _ where canonicalID.hasPrefix("T"):
            let encoding = reader.byte()
            return Frame(id: id, value: .text(reader.strings(encoding)))
        case "WXXX":
            let encoding = reader.byte()
            let description = reader.string(encoding)
            return Frame(id: id, description: description, value: .text([reader.string(0)]))
        case _ where canonicalID.hasPrefix("W"):
            return Frame(id: id, value: .text([reader.string(0)]))
        case "COMM", "USLT":
            let encoding = reader.byte()
            _ = reader.bytes(3) // Language
            let description = reader.string(encoding)
            return Frame(id: id, description: description, value: .text([reader.string(encoding)]))
        case "APIC":
            let encoding = reader.byte()
            // ID3v2.2's PIC has a three-letter image format; later versions have a MIME type.
            if version == 2 {
                _ = reader.bytes(3)
            } else {
                _ = reader.string(0)
            }
            _ = reader.byte() // Picture type
            let description = reader.string(encoding)
            return Frame(id: id, description: description, value: .picture(Data(reader.rest())))
        case "GEOB":
            let encoding = reader.byte()
            _ = reader.string(0) // MIME type
            _ = reader.string(encoding) // Filename
            let description = reader.string(encoding)
            return Frame(id: id, description: description, value: .binary(Data(reader.rest())))
        case "PRIV":
            let owner = reader.string(0)
            return Frame(id: id, description: owner, value: .binary(Data(reader.rest())))
        case "UFID":
            let owner = reader.string(0)
            let identifier = reader.rest()
            let isText = identifier.allSatisfy { (0x20...0x7E).contains($0) }
            return Frame(id: id, description: owner, value: isText ? .text([String(decoding: identifier, as: UTF8.self)]) : .binary(Data(identifier)))
        case "POPM":
            let email = reader.string(0)
            return Frame(id: id, description: email, value: .text([String(reader.byte())]))
        case "PCNT":
            return Frame(id: id, value: .text([String(content.bigEndianValue)]))
        default:
            return Frame(id: id, value: .binary(Data(content)))
        }
    }

    /// Reads a frame's fields in order.
    private struct Reader {
        var bytes: ArraySlice<UInt8>

        mutating func byte() -> UInt8 {
            bytes.popFirst() ?? 0
        }

        mutating func bytes(_ count: Int) -> ArraySlice<UInt8> {
            let result = bytes.prefix(count)
            bytes = bytes.dropFirst(count)
            return result
        }

        mutating func rest() -> ArraySlice<UInt8> {
            bytes(bytes.count)
        }

        /// Reads one string up to its null terminator (two bytes in UTF-16), or the end of the frame.
        mutating func string(_ encoding: UInt8) -> String {
            let isUTF16 = encoding == 1 || encoding == 2
            var end = bytes.startIndex
            while end < bytes.endIndex {
                if isUTF16 {
                    if end + 1 < bytes.endIndex, bytes[end] == 0, bytes[end + 1] == 0 { break }
                    end += 2
                } else {
                    if bytes[end] == 0 { break }
                    end += 1
                }
            }
            end = min(end, bytes.endIndex)
            let text = bytes[bytes.startIndex..<end]
            bytes = bytes[min(bytes.endIndex, end + (isUTF16 ? 2 : 1))...]
            return ID3Tag.decode(text, encoding: encoding)
        }

        /// Reads null-separated strings to the end of the frame, ignoring a trailing terminator.
        mutating func strings(_ encoding: UInt8) -> [String] {
            var result: [String] = []
            while !bytes.isEmpty {
                result.append(string(encoding))
            }
            return result
        }
    }

    private static func decode(_ bytes: ArraySlice<UInt8>, encoding: UInt8) -> String {
        let stringEncoding: String.Encoding = switch encoding {
        case 0: .isoLatin1
        case 1: .utf16 // With a byte order mark
        case 2: .utf16BigEndian
        default: .utf8
        }
        return String(data: Data(bytes), encoding: stringEncoding) ?? String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Sizes

    /// A frame's size in ID3v2.4, which should be syncsafe. Some taggers (notably old iTunes) wrote
    /// plain big-endian sizes instead, so use that if the syncsafe size doesn't land on another frame.
    private static func v24FrameSize(_ bytes: ArraySlice<UInt8>, frameStart: Int, in body: [UInt8]) -> Int {
        let plain = bytes.bigEndianValue
        guard !bytes.contains(where: { $0 & 0x80 != 0 }) else { return plain }
        let syncsafeSize = syncsafe(bytes)
        guard syncsafeSize != plain, !isFrameBoundary(frameStart + syncsafeSize, in: body) else { return syncsafeSize }
        return isFrameBoundary(frameStart + plain, in: body) ? plain : syncsafeSize
    }

    /// Whether a frame could end at `offset`: the end of the tag, padding, or the next frame's ID.
    private static func isFrameBoundary(_ offset: Int, in body: [UInt8]) -> Bool {
        if offset == body.count { return true }
        guard offset + 4 <= body.count else { return false }
        return body[offset] == 0 || isFrameID(body[offset..<offset + 4])
    }

    private static func isFrameID(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
    }

    /// Syncsafe integers use 7 bits per byte, so they never contain a byte that looks like an MP3 frame sync.
    private static func syncsafe(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    /// Undoes unsynchronisation, which inserts a zero after every 0xFF.
    private static func resynchronise(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var previous: UInt8 = 0
        for byte in bytes {
            if !(previous == 0xFF && byte == 0) {
                result.append(byte)
            }
            previous = byte
        }
        return result
    }

    // MARK: Genres

    /// The genres in a `TCON` frame value, naming any ID3v1 genre numbers.
    ///
    /// ID3v2.4 can give a bare number, such as "13". Earlier versions give numbers in brackets,
    /// optionally followed by a refinement: "(13)(17)", or "(4)Eurodisco". "(RX)" and "(CR)" mean
    /// remix and cover, and "((" starts a refinement that begins with a bracket.
    public static func genres(fromTCON value: String) -> [String] {
        if let number = Int(value) {
            return [genreName(number) ?? value]
        }
        var genres: [String] = []
        var rest = Substring(value)
        while rest.hasPrefix("("), !rest.hasPrefix("(("), let close = rest.firstIndex(of: ")") {
            let reference = rest[rest.index(after: rest.startIndex)..<close]
            switch reference {
            case "RX": genres.append("Remix")
            case "CR": genres.append("Cover")
            default: genres.append(Int(reference).flatMap(genreName) ?? "(\(reference))")
            }
            rest = rest[rest.index(after: close)...]
        }
        if rest.hasPrefix("((") {
            rest = rest.dropFirst()
        }
        if !rest.isEmpty {
            genres.append(String(rest))
        }
        return genres
    }

    /// The name of an ID3v1 genre number.
    public static func genreName(_ number: Int) -> String? {
        id3v1Genres.indices.contains(number) ? id3v1Genres[number] : nil
    }

    // MARK: ID3v2.2

    /// ID3v2.2's three-letter frame IDs and their ID3v2.3/2.4 equivalents.
    static let v22FrameIDs: [String: String] = [
        "CNT": "PCNT", "COM": "COMM", "GEO": "GEOB", "PIC": "APIC", "POP": "POPM", "UFI": "UFID", "ULT": "USLT",
        "TAL": "TALB", "TBP": "TBPM", "TCM": "TCOM", "TCO": "TCON", "TCP": "TCMP", "TCR": "TCOP", "TDA": "TDAT",
        "TEN": "TENC", "TKE": "TKEY", "TLA": "TLAN", "TLE": "TLEN", "TMT": "TMED", "TOA": "TOPE", "TOR": "TORY",
        "TOT": "TOAL", "TP1": "TPE1", "TP2": "TPE2", "TP3": "TPE3", "TP4": "TPE4", "TPA": "TPOS", "TPB": "TPUB",
        "TRC": "TSRC", "TRK": "TRCK", "TSS": "TSSE", "TT1": "TIT1", "TT2": "TIT2", "TT3": "TIT3", "TXT": "TEXT",
        "TXX": "TXXX", "TYE": "TYER", "WAR": "WOAR", "WCM": "WCOM", "WPB": "WPUB", "WXX": "WXXX",
    ]
}
