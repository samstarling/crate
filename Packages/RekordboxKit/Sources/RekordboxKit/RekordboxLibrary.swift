import Foundation

/// A snapshot of a Rekordbox 6/7 library, read from its `master.db`.
public struct RekordboxLibrary: Sendable {
    public let location: URL
    public private(set) var tracks: [Track]
    public private(set) var tracksByID: [String: Track]
    public let playlists: [Playlist]
    /// The eight track colours, in Rekordbox's order.
    public let colors: [TrackColor]
    /// My Tag names by ID (not including the folders that group them).
    public let myTags: [String: String]
    /// Rekordbox's `localUpdateCount` when this snapshot was taken. Rekordbox increments it with
    /// every local edit, so if it has changed, someone else has edited the library since.
    public private(set) var updateCount: Int?
    /// For each sortable key path, every track's rank (indexed by `Track.libraryIndex`) in ascending
    /// order. Equal values share a rank. Computed once at load so sorting is just integer comparisons.
    /// (Key path literals capture nothing, so sharing them across threads is safe.)
    nonisolated(unsafe) private(set) var sortRanks: [PartialKeyPath<Track>: [Int]]

    public init(
        location: URL,
        tracks: [Track],
        playlists: [Playlist],
        colors: [TrackColor],
        myTags: [String: String] = [:],
        updateCount: Int? = nil
    ) {
        self.location = location
        self.tracks = tracks
        self.tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.playlists = playlists
        self.colors = colors
        self.myTags = myTags
        self.updateCount = updateCount
        self.sortRanks = Self.sortRanks(for: tracks)
    }

    public static let defaultLocation = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Pioneer/rekordbox", directoryHint: .isDirectory)

    /// Rekordbox encrypts `master.db` with SQLCipher 4 using this fixed key, which is the same for
    /// every install (see https://github.com/dylanljones/pyrekordbox).
    static let databaseKey = "402fd482c38817c35ffa8ffb8c7d93143b749e7d315df7a81732a1ff43608497"

    /// Loads the library in `folder` (the directory containing `master.db`).
    ///
    /// The database is copied to a temporary directory first so we never contend with a running
    /// copy of Rekordbox, and can't possibly modify the original.
    public static func load(from folder: URL) throws -> RekordboxLibrary {
        let fileManager = FileManager.default
        let source = folder.appending(path: "master.db")
        guard fileManager.fileExists(atPath: source.path) else {
            throw SQLiteDatabase.Error(message: "No master.db found in \(folder.path).")
        }

        let scratch = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        for suffix in ["", "-wal", "-shm"] {
            let file = folder.appending(path: "master.db\(suffix)")
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.copyItem(at: file, to: scratch.appending(path: file.lastPathComponent))
            }
        }

        let database = try SQLiteDatabase(url: scratch.appending(path: "master.db"), key: databaseKey)
        let colors = try loadColors(from: database)
        let memoryCues = try loadMemoryCues(from: database)
        let trackTags = try loadTrackTags(from: database)
        let tracks = try loadTracks(
            from: database, colors: colors, memoryCues: memoryCues, trackTags: trackTags, shareRoot: folder.appending(path: "share")
        )
        let playlists = try loadPlaylists(from: database)

        return RekordboxLibrary(
            location: folder,
            tracks: tracks,
            playlists: playlists,
            colors: colors.values.sorted { $0.id < $1.id },
            myTags: try loadMyTags(from: database),
            updateCount: try readUpdateCount(from: database)
        )
    }

    private static func ranks<Value>(
        _ tracks: [Track], _ keyPath: KeyPath<Track, Value>, by areInIncreasingOrder: (Value, Value) -> Bool
    ) -> [Int] {
        let values = tracks.map { $0[keyPath: keyPath] }
        let order = values.indices.sorted { areInIncreasingOrder(values[$0], values[$1]) }
        var ranks = [Int](repeating: 0, count: values.count)
        var rank = 0
        for (position, index) in order.enumerated() {
            if position > 0, areInIncreasingOrder(values[order[position - 1]], values[index]) {
                rank = position
            }
            ranks[index] = rank
        }
        return ranks
    }

    private static func sortRanks(for tracks: [Track]) -> [PartialKeyPath<Track>: [Int]] {
        func text(_ keyPath: KeyPath<Track, String>) -> (PartialKeyPath<Track>, [Int]) {
            (keyPath, ranks(tracks, keyPath) { $0.localizedStandardCompare($1) == .orderedAscending })
        }

        func number<Value: Comparable>(_ keyPath: KeyPath<Track, Value>) -> (PartialKeyPath<Track>, [Int]) {
            (keyPath, ranks(tracks, keyPath, by: <))
        }

        return Dictionary(uniqueKeysWithValues: [
            text(\.title), text(\.artist), text(\.album), text(\.genre), text(\.label), text(\.key), text(\.location),
            number(\.dateAdded), number(\.bpm), number(\.duration), number(\.rating), number(\.year),
            number(\.playCount), number(\.colorSortKey), number(\.memoryCueCount),
        ])
    }

    private static func loadColors(from database: SQLiteDatabase) throws -> [Int: TrackColor] {
        var colors: [Int: TrackColor] = [:]
        try database.query("SELECT ID, Commnt FROM djmdColor") { row in
            let id = Int(row.string(0) ?? "") ?? 0
            colors[id] = TrackColor(id: id, name: row.string(1) ?? "")
        }
        return colors
    }

    private static func loadMemoryCues(from database: SQLiteDatabase) throws -> [Track.ID: [Double]] {
        var cues: [Track.ID: [Double]] = [:]
        // Kind 0 is a memory cue; 1–8 are hot cues A–H.
        try database.query("""
            SELECT ContentID, InMsec FROM djmdCue
            WHERE rb_local_deleted = 0 AND Kind = 0
            ORDER BY ContentID, InMsec
            """) { row in
            guard let id = row.string(0) else { return }
            cues[id, default: []].append(Double(row.int(1)) / 1000)
        }
        return cues
    }

    private static func loadMyTags(from database: SQLiteDatabase) throws -> [String: String] {
        var tags: [String: String] = [:]
        // Attribute 1 rows are the folders tags are grouped into.
        try database.query("SELECT ID, Name FROM djmdMyTag WHERE rb_local_deleted = 0 AND Attribute = 0") { row in
            guard let id = row.string(0) else { return }
            tags[id] = row.string(1) ?? ""
        }
        return tags
    }

    private static func loadTrackTags(from database: SQLiteDatabase) throws -> [Track.ID: [String]] {
        var tags: [Track.ID: [String]] = [:]
        try database.query("SELECT ContentID, MyTagID FROM djmdSongMyTag WHERE rb_local_deleted = 0") { row in
            guard let trackID = row.string(0), let tagID = row.string(1) else { return }
            tags[trackID, default: []].append(tagID)
        }
        return tags
    }

    private static func loadTracks(
        from database: SQLiteDatabase,
        colors: [Int: TrackColor],
        memoryCues: [Track.ID: [Double]],
        trackTags: [Track.ID: [String]],
        shareRoot: URL
    ) throws -> [Track] {
        var tracks: [Track] = []
        try database.query("""
            SELECT c.ID, c.Title, a.Name, al.Name, g.Name, l.Name, k.ScaleName, c.BPM, c.Length,
                   c.Rating, c.ReleaseYear, c.StockDate, c.DJPlayCount, c.ColorID, c.Commnt,
                   c.FolderPath, c.ImagePath, c.AnalysisDataPath
            FROM djmdContent c
            LEFT JOIN djmdArtist a ON a.ID = c.ArtistID
            LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID
            LEFT JOIN djmdGenre g ON g.ID = c.GenreID
            LEFT JOIN djmdLabel l ON l.ID = c.LabelID
            LEFT JOIN djmdKey k ON k.ID = c.KeyID
            WHERE c.rb_local_deleted = 0
            """) { row in
            let id = row.string(0) ?? ""
            let imagePath = row.string(16) ?? ""
            // The colour waveform lives alongside the .DAT file Rekordbox points at, in the .EXT file.
            let analysisPath = row.string(17) ?? ""
            tracks.append(Track(
                id: id,
                libraryIndex: tracks.count,
                title: row.string(1) ?? "",
                artist: row.string(2) ?? "",
                album: row.string(3) ?? "",
                genre: row.string(4) ?? "",
                label: row.string(5) ?? "",
                key: row.string(6) ?? "",
                bpm: Double(row.int(7)) / 100,
                duration: row.int(8),
                rating: row.int(9),
                year: row.int(10),
                dateAdded: row.string(11) ?? "",
                playCount: row.int(12),
                color: colors[Int(row.string(13) ?? "") ?? 0],
                comment: row.string(14) ?? "",
                fileURL: URL(filePath: row.string(15) ?? ""),
                artworkURL: imagePath.isEmpty ? nil : shareRoot.appending(path: imagePath),
                analysisURL: analysisPath.isEmpty ? nil : shareRoot.appending(path: analysisPath).deletingPathExtension().appendingPathExtension("EXT"),
                memoryCues: memoryCues[id] ?? [],
                myTagIDs: trackTags[id] ?? []
            ))
        }
        return tracks
    }

    private static func loadPlaylists(from database: SQLiteDatabase) throws -> [Playlist] {
        var trackIDs: [String: [String]] = [:]
        try database.query("""
            SELECT PlaylistID, ContentID FROM djmdSongPlaylist
            WHERE rb_local_deleted = 0
            ORDER BY PlaylistID, TrackNo
            """) { row in
            guard let playlistID = row.string(0), let contentID = row.string(1) else { return }
            trackIDs[playlistID, default: []].append(contentID)
        }

        var childrenByParent: [String: [(seq: Int, playlist: Playlist)]] = [:]
        try database.query("""
            SELECT ID, Name, Attribute, ParentID, Seq, SmartList FROM djmdPlaylist
            WHERE rb_local_deleted = 0
            """) { row in
            let id = row.string(0) ?? ""
            let kind: Playlist.Kind = switch row.int(2) {
            case 1: .folder
            case 4: .smart
            default: .playlist
            }
            let playlist = Playlist(
                id: id,
                name: row.string(1) ?? "",
                kind: kind,
                children: nil,
                trackIDs: trackIDs[id] ?? [],
                smartRule: kind == .smart ? row.string(5).flatMap(SmartRule.init(xml:)) : nil
            )
            childrenByParent[row.string(3) ?? "root", default: []].append((row.int(4), playlist))
        }

        func children(of parentID: String) -> [Playlist] {
            (childrenByParent[parentID] ?? [])
                .sorted { $0.seq < $1.seq }
                .map { entry in
                    var playlist = entry.playlist
                    if playlist.kind == .folder {
                        playlist.children = children(of: playlist.id)
                    }
                    return playlist
                }
        }
        return children(of: "root")
    }

    /// The tracks a smart playlist's rules match, in collection order. Throws `SmartRule.Unsupported`
    /// if the rules use something Crate can't evaluate yet.
    public func smartTracks(in playlist: Playlist, now: Date = .now) throws -> [Track] {
        guard let rule = playlist.smartRule else {
            throw SmartRule.Unsupported(reason: "Crate couldn\u{2019}t read this smart playlist\u{2019}s rules.")
        }
        return tracks.filter(try rule.predicate(myTags: myTags, now: now))
    }

    public func tracks(in playlist: Playlist) -> [Track] {
        // A playlist can contain the same track twice, but Table needs unique row IDs.
        var seen = Set<String>()
        return playlist.trackIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return tracksByID[id]
        }
    }

    /// Updates this in-memory snapshot after a successful `saveColor`, which returned `updateCount`.
    public mutating func applyColor(_ color: TrackColor?, toTrackIDs ids: [Track.ID], updateCount: Int) {
        self.updateCount = updateCount
        for id in ids {
            guard var track = tracksByID[id] else { continue }
            track.color = color
            tracks[track.libraryIndex] = track
            tracksByID[id] = track
        }
        sortRanks[\Track.colorSortKey] = Self.ranks(tracks, \.colorSortKey, by: <)
    }

    /// Sorts `tracks` using the precomputed ranks. Ties keep their existing (e.g. playlist) order.
    public func sorted(_ tracks: [Track], by comparator: KeyPathComparator<Track>) -> [Track] {
        guard let ranks = sortRanks[comparator.keyPath] else {
            return tracks.sorted(using: comparator)
        }
        let keys = tracks.map { ranks[$0.libraryIndex] }
        let ascending = comparator.order == .forward
        let order = keys.indices.sorted { a, b in
            if keys[a] != keys[b] { return ascending ? keys[a] < keys[b] : keys[a] > keys[b] }
            return a < b
        }
        return order.map { tracks[$0] }
    }

    /// How many playlists (not counting smart playlists) contain any of these tracks.
    public func playlistCount(containing ids: Set<Track.ID>) -> Int {
        func count(_ playlists: [Playlist]) -> Int {
            playlists.reduce(0) { total, playlist in
                let contains = playlist.kind == .playlist && playlist.trackIDs.contains(where: ids.contains)
                return total + (contains ? 1 : 0) + count(playlist.children ?? [])
            }
        }
        return count(playlists)
    }

    public func playlist(withID id: String) -> Playlist? {
        func search(_ playlists: [Playlist]) -> Playlist? {
            for playlist in playlists {
                if playlist.id == id { return playlist }
                if let match = search(playlist.children ?? []) { return match }
            }
            return nil
        }
        return search(playlists)
    }
}
