import AppKit

/// A column of the track list: its header, size, how it draws a track and how it sorts.
struct TrackColumn {
    enum Content {
        case artwork, color, text, number
    }

    let id: String
    let title: String
    let width: CGFloat
    let minWidth: CGFloat
    let content: Content
    /// `nil` for columns that can't be sorted. Always ascending; the table flips it as needed.
    let comparator: KeyPathComparator<Track>?
    let configure: (NSTextField, Track) -> Void

    var alignment: NSTextAlignment { content == .number ? .right : .left }

    private init(
        _ id: String, _ title: String, width: CGFloat, minWidth: CGFloat, content: Content = .text,
        comparator: KeyPathComparator<Track>?, configure: @escaping (NSTextField, Track) -> Void = { _, _ in }
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.minWidth = minWidth
        self.content = content
        self.comparator = comparator
        self.configure = configure
    }

    /// A plain text column showing `keyPath`, sorted Finder-style.
    private static func text(_ id: String, _ title: String, _ keyPath: KeyPath<Track, String> & Sendable, width: CGFloat, minWidth: CGFloat) -> TrackColumn {
        TrackColumn(id, title, width: width, minWidth: minWidth, comparator: KeyPathComparator(keyPath, comparator: .localizedStandard)) { field, track in
            field.stringValue = track[keyPath: keyPath]
        }
    }

    /// A right-aligned numeric column; `format` returns "" for missing values.
    private static func number<Value: Comparable>(_ id: String, _ title: String, _ keyPath: KeyPath<Track, Value> & Sendable, width: CGFloat, minWidth: CGFloat, format: @escaping (Value) -> String) -> TrackColumn {
        TrackColumn(id, title, width: width, minWidth: minWidth, content: .number, comparator: KeyPathComparator(keyPath)) { field, track in
            field.stringValue = format(track[keyPath: keyPath])
        }
    }

    static let all: [TrackColumn] = [
        TrackColumn("artwork", "", width: 22, minWidth: 22, content: .artwork, comparator: nil),
        TrackColumn("colour", "Colour", width: 90, minWidth: 60, content: .color, comparator: KeyPathComparator(\.colorSortKey)),
        text("title", "Title", \.title, width: 260, minWidth: 120),
        text("artist", "Artist", \.artist, width: 180, minWidth: 80),
        text("album", "Album", \.album, width: 160, minWidth: 60),
        text("genre", "Genre", \.genre, width: 110, minWidth: 50),
        number("bpm", "BPM", \.bpm, width: 55, minWidth: 40) { $0 > 0 ? $0.formatted(.number.precision(.fractionLength(0...2))) : "" },
        text("key", "Key", \.key, width: 45, minWidth: 30),
        number("time", "Time", \.duration, width: 50, minWidth: 40) { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) },
        TrackColumn("rating", "Rating", width: 70, minWidth: 60, comparator: KeyPathComparator(\.rating)) { field, track in
            field.stringValue = String(repeating: "★", count: track.rating) + String(repeating: "☆", count: max(0, 5 - track.rating))
            field.textColor = track.rating > 0 ? .labelColor : .tertiaryLabelColor
        },
        number("year", "Year", \.year, width: 45, minWidth: 35) { $0 > 0 ? String($0) : "" },
        text("label", "Label", \.label, width: 120, minWidth: 60),
        text("dateAdded", "Date Added", \.dateAdded, width: 85, minWidth: 70),
        number("plays", "Plays", \.playCount, width: 45, minWidth: 35) { $0 > 0 ? String($0) : "" },
        number("cues", "Cues", \.memoryCueCount, width: 45, minWidth: 35) { $0 > 0 ? String($0) : "" },
    ]

    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func comparator(for descriptor: NSSortDescriptor) -> KeyPathComparator<Track>? {
        guard let key = descriptor.key, var comparator = byID[key]?.comparator else { return nil }
        comparator.order = descriptor.ascending ? .forward : .reverse
        return comparator
    }

    static func sortDescriptor(for comparator: KeyPathComparator<Track>) -> NSSortDescriptor? {
        guard let column = all.first(where: { $0.comparator?.keyPath == comparator.keyPath }) else { return nil }
        return NSSortDescriptor(key: column.id, ascending: comparator.order == .forward)
    }
}
