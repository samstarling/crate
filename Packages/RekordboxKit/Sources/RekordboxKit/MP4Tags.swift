import Foundation

/// The iTunes-style tags in an MP4 audio file (M4A, AAC or ALAC).
///
/// MP4 files are nested atoms, each a big-endian size and a four-letter type. Tags live in
/// `moov/udta/meta/ilst`, one atom per tag (such as `©nam`), holding one or more `data` atoms.
public struct MP4Tags: Sendable, Equatable {
    public struct Tag: Sendable, Equatable {
        /// The atom type, such as `©nam` or `trkn`, or `----` for a custom tag.
        public let key: String
        /// A custom tag's name, such as "iTunNORM" (prefixed with its namespace if that isn't iTunes').
        public let description: String
        public let value: TagValue

        public init(key: String, description: String = "", value: TagValue) {
            self.key = key
            self.description = description
            self.value = value
        }
    }

    /// The tags, in the order they appear.
    public let tags: [Tag]

    public init(tags: [Tag]) {
        self.tags = tags
    }

    /// Reads the tags from an MP4 file, or returns `nil` if it isn't one. Only the `moov` atom is
    /// read, not the audio.
    public static func read(from url: URL) throws -> MP4Tags? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let start = try handle.read(upToCount: 8), start.count == 8, start.dropFirst(4).elementsEqual("ftyp".utf8) else { return nil }

        // Walk the top-level atoms to find `moov`, which can come before or after the audio.
        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16).map(Array.init), header.count >= 8 else { break }
            var size = UInt64(header[0..<4].bigEndianValue)
            var headerLength: UInt64 = 8
            if size == 1, header.count == 16 {
                // Corrupt sizes can overflow `Int`; they then fail the check below.
                size = UInt64(truncatingIfNeeded: header[8..<16].bigEndianValue)
                headerLength = 16
            } else if size == 0 {
                size = fileSize - offset
            }
            guard size >= headerLength, size <= fileSize - offset else { break }

            if header[4..<8].elementsEqual("moov".utf8) {
                try handle.seek(toOffset: offset + headerLength)
                let moov = [UInt8](try handle.read(upToCount: Int(size - headerLength)) ?? Data())
                return MP4Tags(moov: moov[...])
            }
            offset += size
        }
        return MP4Tags(tags: [])
    }

    /// Parses the tags from the contents of a `moov` atom.
    init(moov: ArraySlice<UInt8>) {
        // iTunes uses `moov/udta/meta`, but some encoders put `meta` straight in `moov`.
        let udta = Self.child("udta", of: moov)
        guard let meta = udta.flatMap({ Self.child("meta", of: $0) }) ?? Self.child("meta", of: moov) else {
            self.init(tags: [])
            return
        }
        // `meta` normally starts with a version and flags, but not in QuickTime-style files, where
        // its first child (`hdlr`) starts straight away.
        let metaChildren = meta.dropFirst(4).starts(with: "hdlr".utf8) ? meta : meta.dropFirst(4)
        guard let ilst = Self.child("ilst", of: metaChildren) else {
            self.init(tags: [])
            return
        }

        var tags: [Tag] = []
        for item in Self.atoms(in: ilst) {
            let children = Self.atoms(in: item.content)
            var description = ""
            if item.type == "----" {
                // Custom tags name themselves with `mean` (a namespace) and `name` atoms, each
                // starting with a version and flags.
                let text = { (type: String) in
                    children.first { $0.type == type }.map { String(decoding: $0.content.dropFirst(4), as: UTF8.self) } ?? ""
                }
                let mean = text("mean")
                description = mean == "com.apple.iTunes" || mean.isEmpty ? text("name") : "\(mean):\(text("name"))"
            }
            for data in children where data.type == "data" {
                tags.append(Tag(key: item.type, description: description, value: Self.value(of: data.content, key: item.type)))
            }
        }
        self.init(tags: tags)
    }

    /// A `data` atom's value. It starts with a version byte, a three-byte type and four bytes of
    /// locale (see https://developer.apple.com/documentation/quicktime-file-format/well-known_types).
    private static func value(of data: ArraySlice<UInt8>, key: String) -> TagValue {
        guard data.count >= 8 else { return .binary(Data(data)) }
        let type = data.prefix(4).dropFirst().bigEndianValue
        let payload = data.dropFirst(8)

        switch type {
        case 1:
            return .text([String(decoding: payload, as: UTF8.self)])
        case 2:
            return .text([String(data: Data(payload), encoding: .utf16BigEndian) ?? ""])
        case 13, 14, 27: // JPEG, PNG, BMP
            return .picture(Data(payload))
        case 21 where [1, 2, 3, 4, 8].contains(payload.count): // Signed integer
            let unsigned = payload.bigEndianValue
            let bits = payload.count * 8
            let signed = bits < 64 && unsigned >= 1 << (bits - 1) ? unsigned - 1 << bits : unsigned
            return .text([String(signed)])
        case 22 where [1, 2, 3, 4, 8].contains(payload.count): // Unsigned integer
            return .text([String(UInt64(truncatingIfNeeded: payload.bigEndianValue))])
        case 0 where (key == "trkn" || key == "disk") && payload.count >= 6:
            // Two bytes of padding, then the number and the total, which is 0 if unknown.
            let number = payload.dropFirst(2).prefix(2).bigEndianValue
            let total = payload.dropFirst(4).prefix(2).bigEndianValue
            return .text([total > 0 ? "\(number)/\(total)" : "\(number)"])
        case 0 where key == "gnre" && payload.count == 2:
            // An ID3v1 genre number, plus one.
            return .text([String(payload.bigEndianValue)])
        default:
            return .binary(Data(payload))
        }
    }

    private struct Atom {
        /// Four Latin-1 characters, so "©nam" reads as it should.
        let type: String
        let content: ArraySlice<UInt8>
    }

    private static func child(_ type: String, of bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        atoms(in: bytes).first { $0.type == type }?.content
    }

    /// The atoms directly inside `bytes`, stopping at the first malformed one.
    private static func atoms(in bytes: ArraySlice<UInt8>) -> [Atom] {
        var atoms: [Atom] = []
        var offset = bytes.startIndex
        while offset + 8 <= bytes.endIndex {
            var size = bytes[offset..<offset + 4].bigEndianValue
            var headerLength = 8
            if size == 1 {
                guard offset + 16 <= bytes.endIndex else { break }
                size = bytes[offset + 8..<offset + 16].bigEndianValue
                headerLength = 16
            } else if size == 0 {
                size = bytes.endIndex - offset
            }
            guard size >= headerLength, size <= bytes.endIndex - offset else { break }
            let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .isoLatin1) ?? ""
            atoms.append(Atom(type: type, content: bytes[offset + headerLength..<offset + size]))
            offset += size
        }
        return atoms
    }
}
