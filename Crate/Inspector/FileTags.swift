import Foundation
import ImageIO
import RekordboxKit

/// The tags embedded in an audio file, such as its ID3 frames, grouped by tag format.
struct FileTags: Sendable {
    struct Group: Identifiable, Sendable {
        /// The tag format, such as "ID3v2.4" or "Vorbis Comments".
        let name: String
        let tags: [Tag]

        var id: String { name }
    }

    struct Tag: Identifiable, Sendable {
        enum Value: Sendable {
            case text(String)
            /// A thumbnail, decoded once when the tags load.
            case image(CGImage)
            /// Binary data we can't show, such as a `PRIV` frame, described by its size.
            case data(byteCount: Int)
        }

        /// Position within its group, as files can repeat a tag (e.g. several `TXXX`s).
        let id: Int
        /// A readable name, such as "Title", or the tag's own name for custom tags, such as a `TXXX`
        /// frame's "EnergyLevel".
        let name: String
        /// Shown as a tooltip: the raw key, and what kind of tag it is if `name` doesn't say, as in
        /// "TXXX (User Text)". Empty if there's nothing to add.
        let detail: String
        let value: Value

        /// Names a tag of a given kind, such as "User Text", using its description if it has one.
        nonisolated init(id: Int, key: String, kind: String, description: String, value: Value) {
            self.id = id
            if description.isEmpty {
                name = kind
                detail = key == kind ? "" : key
            } else {
                name = description
                detail = "\(key) (\(kind))"
            }
            self.value = value
        }

        nonisolated init(id: Int, name: String, detail: String, value: Value) {
            self.id = id
            self.name = name
            self.detail = detail
            self.value = value
        }
    }

    let groups: [Group]

    var isEmpty: Bool { groups.isEmpty }

    /// Reads every tag in an MP3, AIFF, WAV, FLAC or MP4 file, in the order they appear, off the main
    /// actor. A file can have more than one kind, such as an MP3 with both ID3v2 and ID3v1 tags.
    @concurrent
    nonisolated static func load(from url: URL) async throws -> FileTags {
        var groups: [Group] = []
        if let id3 = try ID3Tag.read(from: url), !id3.frames.isEmpty {
            let tags = id3.frames.enumerated().map { id, frame in
                let name = id3FrameNames[frame.canonicalID] ?? frame.id
                var value = value(frame.value)
                if frame.canonicalID == "TCON", case .text(let values) = frame.value {
                    value = .text(values.flatMap(ID3Tag.genres).joined(separator: "\n"))
                }
                // These frames' descriptions name an owner (or an email address, for POPM), which
                // says nothing about the tag, so it goes in the tooltip.
                if ["UFID", "PRIV", "POPM"].contains(frame.canonicalID), !frame.description.isEmpty {
                    return Tag(id: id, name: name, detail: "\(frame.id) (\(frame.description))", value: value)
                }
                return Tag(id: id, key: frame.id, kind: name, description: frame.description, value: value)
            }
            groups.append(Group(name: "ID3v2.\(id3.majorVersion)", tags: tags))
        }
        try Task.checkCancellation()
        if let id3v1 = try ID3v1Tag.read(from: url) {
            let fields: [(String, String)] = [
                ("Title", id3v1.title),
                ("Artist", id3v1.artist),
                ("Album", id3v1.album),
                ("Year", id3v1.year),
                ("Comment", id3v1.comment),
                ("Track Number", id3v1.track.map(String.init) ?? ""),
                ("Genre", id3v1.genre.map { ID3Tag.genreName($0) ?? String($0) } ?? ""),
            ]
            let tags = fields.filter { !$0.1.isEmpty }.enumerated().map { id, field in
                Tag(id: id, name: field.0, detail: "", value: .text(field.1))
            }
            if !tags.isEmpty {
                groups.append(Group(name: "ID3v1", tags: tags))
            }
        }
        try Task.checkCancellation()
        if let flac = try FLACTags.read(from: url), !flac.tags.isEmpty {
            let tags = flac.tags.enumerated().map { id, tag in
                Tag(id: id, key: tag.key, kind: vorbisCommentNames[tag.key] ?? tag.key, description: tag.description, value: value(tag.value))
            }
            groups.append(Group(name: "Vorbis Comments", tags: tags))
        }
        try Task.checkCancellation()
        if let mp4 = try MP4Tags.read(from: url), !mp4.tags.isEmpty {
            let tags = mp4.tags.enumerated().map { id, tag in
                var value = value(tag.value)
                // `gnre` holds an ID3v1 genre number plus one.
                if tag.key == "gnre", case .text(let values) = tag.value, let genre = values.first.flatMap(Int.init).flatMap({ ID3Tag.genreName($0 - 1) }) {
                    value = .text(genre)
                }
                let kind = tag.key == "----" ? "Custom" : mp4AtomNames[tag.key] ?? tag.key
                return Tag(id: id, key: tag.key, kind: kind, description: tag.description, value: value)
            }
            groups.append(Group(name: "MP4", tags: tags))
        }
        return FileTags(groups: groups)
    }

    nonisolated private static func value(_ value: TagValue) -> Tag.Value {
        switch value {
        case .text(let values): .text(values.joined(separator: "\n"))
        case .picture(let data): thumbnail(of: data).map { .image($0) } ?? .data(byteCount: data.count)
        case .binary(let data): .data(byteCount: data.count)
        }
    }

    /// Decodes a picture at no more than 400 pixels across, which is 200 points on a Retina display.
    nonisolated private static func thumbnail(of data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Readable names for ID3v2.3 and v2.4 frames (ID3v2.2 frames are looked up by their equivalent).
    nonisolated private static let id3FrameNames: [String: String] = [
        "APIC": "Picture",
        "COMM": "Comment",
        "GEOB": "Object",
        "MCDI": "CD Identifier",
        "PCNT": "Play Count",
        "POPM": "Rating",
        "PRIV": "Private",
        "RVA2": "Relative Volume",
        "TALB": "Album",
        "TBPM": "BPM",
        "TCMP": "Compilation",
        "TCOM": "Composer",
        "TCON": "Genre",
        "TCOP": "Copyright",
        "TDAT": "Date",
        "TDEN": "Encoding Time",
        "TDOR": "Original Release Date",
        "TDRC": "Recording Date",
        "TDRL": "Release Date",
        "TDTG": "Tagging Time",
        "TENC": "Encoded By",
        "TEXT": "Lyricist",
        "TFLT": "File Type",
        "TIPL": "Involved People",
        "TIT1": "Grouping",
        "TIT2": "Title",
        "TIT3": "Subtitle",
        "TKEY": "Key",
        "TLAN": "Language",
        "TLEN": "Length",
        "TMCL": "Musicians",
        "TMED": "Media Type",
        "TMOO": "Mood",
        "TOAL": "Original Album",
        "TOPE": "Original Artist",
        "TORY": "Original Year",
        "TOWN": "File Owner",
        "TPE1": "Artist",
        "TPE2": "Album Artist",
        "TPE3": "Conductor",
        "TPE4": "Remixer",
        "TPOS": "Disc Number",
        "TPUB": "Publisher",
        "TRCK": "Track Number",
        "TRSN": "Radio Station",
        "TSO2": "Album Artist Sort Order",
        "TSOA": "Album Sort Order",
        "TSOC": "Composer Sort Order",
        "TSOP": "Artist Sort Order",
        "TSOT": "Title Sort Order",
        "TSRC": "ISRC",
        "TSSE": "Encoder Settings",
        "TXXX": "User Text",
        "TYER": "Year",
        "UFID": "Unique File Identifier",
        "USLT": "Lyrics",
        "WCOM": "Purchase URL",
        "WOAR": "Artist URL",
        "WOAS": "Source URL",
        "WPUB": "Publisher URL",
        "WXXX": "User URL",
    ]

    /// Readable names for common Vorbis comment fields. Any field name is allowed, so others are
    /// shown as they are.
    nonisolated private static let vorbisCommentNames: [String: String] = [
        "ALBUM": "Album",
        "ALBUMARTIST": "Album Artist",
        "ARTIST": "Artist",
        "BPM": "BPM",
        "COMMENT": "Comment",
        "COMPOSER": "Composer",
        "COPYRIGHT": "Copyright",
        "DATE": "Date",
        "DESCRIPTION": "Description",
        "DISCNUMBER": "Disc Number",
        "DISCTOTAL": "Disc Total",
        "ENCODER": "Encoder",
        "GENRE": "Genre",
        "GROUPING": "Grouping",
        "INITIALKEY": "Key",
        "ISRC": "ISRC",
        "KEY": "Key",
        "LABEL": "Label",
        "LYRICS": "Lyrics",
        "ORGANIZATION": "Label",
        "PICTURE": "Picture",
        "PUBLISHER": "Publisher",
        "TITLE": "Title",
        "TRACKNUMBER": "Track Number",
        "TRACKTOTAL": "Track Total",
        "TOTALTRACKS": "Track Total",
    ]

    /// Readable names for iTunes MP4 atoms.
    nonisolated private static let mp4AtomNames: [String: String] = [
        "©alb": "Album",
        "©ART": "Artist",
        "©cmt": "Comment",
        "©day": "Release Date",
        "©gen": "Genre",
        "©grp": "Grouping",
        "©lyr": "Lyrics",
        "©nam": "Title",
        "©too": "Encoder",
        "©wrt": "Composer",
        "aART": "Album Artist",
        "atID": "Artist ID",
        "cmID": "Composer ID",
        "cnID": "Catalogue ID",
        "covr": "Picture",
        "cpil": "Compilation",
        "cprt": "Copyright",
        "desc": "Description",
        "disk": "Disc Number",
        "geID": "Genre ID",
        "gnre": "Genre",
        "pgap": "Gapless Playback",
        "plID": "Album ID",
        "rtng": "Content Rating",
        "sfID": "Storefront ID",
        "soaa": "Album Artist Sort Order",
        "soal": "Album Sort Order",
        "soar": "Artist Sort Order",
        "soco": "Composer Sort Order",
        "sonm": "Title Sort Order",
        "stik": "Media Kind",
        "tmpo": "BPM",
        "trkn": "Track Number",
    ]
}
