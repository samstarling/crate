import Foundation

/// A snapshot of a Rekordbox 6/7 library, read from its `master.db`.
nonisolated struct RekordboxLibrary: Sendable {
    let location: URL
    private(set) var tracks: [Track]
    private(set) var tracksByID: [String: Track]
    let playlists: [Playlist]
    /// The eight track colours, in Rekordbox's order.
    let colors: [TrackColor]
    /// For each sortable key path, every track's rank (indexed by `Track.libraryIndex`) in ascending
    /// order. Equal values share a rank. Computed once at load so sorting is just integer comparisons.
    /// (Key path literals capture nothing, so sharing them across threads is safe.)
    nonisolated(unsafe) private(set) var sortRanks: [PartialKeyPath<Track>: [Int]]

    static let defaultLocation = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Pioneer/rekordbox", directoryHint: .isDirectory)

    /// Rekordbox encrypts `master.db` with SQLCipher 4 using this fixed key, which is the same for
    /// every install (see https://github.com/dylanljones/pyrekordbox).
    private static let databaseKey = "402fd482c38817c35ffa8ffb8c7d93143b749e7d315df7a81732a1ff43608497"

    /// Loads the library in `folder` (the directory containing `master.db`).
    ///
    /// The database is copied to a temporary directory first so we never contend with a running
    /// copy of Rekordbox, and can't possibly modify the original.
    static func load(from folder: URL) throws -> RekordboxLibrary {
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
        let tracks = try loadTracks(from: database, colors: colors, artworkRoot: folder.appending(path: "share"))
        let playlists = try loadPlaylists(from: database)

        return RekordboxLibrary(
            location: folder,
            tracks: tracks,
            tracksByID: Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            playlists: playlists,
            colors: colors.values.sorted { $0.id < $1.id },
            sortRanks: sortRanks(for: tracks)
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
            text(\.title), text(\.artist), text(\.album), text(\.genre), text(\.label), text(\.key),
            number(\.dateAdded), number(\.bpm), number(\.duration), number(\.rating), number(\.year),
            number(\.playCount), number(\.colorSortKey),
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

    private static func loadTracks(from database: SQLiteDatabase, colors: [Int: TrackColor], artworkRoot: URL) throws -> [Track] {
        var tracks: [Track] = []
        try database.query("""
            SELECT c.ID, c.Title, a.Name, al.Name, g.Name, l.Name, k.ScaleName, c.BPM, c.Length,
                   c.Rating, c.ReleaseYear, c.DateCreated, c.DJPlayCount, c.ColorID, c.Commnt,
                   c.FolderPath, c.ImagePath
            FROM djmdContent c
            LEFT JOIN djmdArtist a ON a.ID = c.ArtistID
            LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID
            LEFT JOIN djmdGenre g ON g.ID = c.GenreID
            LEFT JOIN djmdLabel l ON l.ID = c.LabelID
            LEFT JOIN djmdKey k ON k.ID = c.KeyID
            WHERE c.rb_local_deleted = 0
            """) { row in
            let imagePath = row.string(16) ?? ""
            tracks.append(Track(
                id: row.string(0) ?? "",
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
                artworkURL: imagePath.isEmpty ? nil : artworkRoot.appending(path: imagePath)
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
            SELECT ID, Name, Attribute, ParentID, Seq FROM djmdPlaylist
            WHERE rb_local_deleted = 0
            """) { row in
            let id = row.string(0) ?? ""
            let kind: Playlist.Kind = switch row.int(2) {
            case 1: .folder
            case 4: .smart
            default: .playlist
            }
            let playlist = Playlist(id: id, name: row.string(1) ?? "", kind: kind, children: nil, trackIDs: trackIDs[id] ?? [])
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

    func tracks(in playlist: Playlist) -> [Track] {
        // A playlist can contain the same track twice, but Table needs unique row IDs.
        var seen = Set<String>()
        return playlist.trackIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return tracksByID[id]
        }
    }

    // MARK: Editing

    /// Writes a new colour (or none) for the given tracks to `master.db` in `folder`.
    ///
    /// Each edited row gets a fresh `rb_local_usn` from Rekordbox's `localUpdateCount` counter and a
    /// new `updated_at`, matching what Rekordbox itself does, so it sees the change as a local edit.
    /// Rekordbox must not be running, or it may overwrite the change.
    static func saveColor(_ color: TrackColor?, forTrackIDs ids: [Track.ID], in folder: URL) throws {
        let database = try SQLiteDatabase(url: folder.appending(path: "master.db"), key: databaseKey, readOnly: false)
        let now = timestampFormatter.string(from: .now)

        try database.transaction {
            var updateCount: Int?
            try database.query("SELECT int_1 FROM agentRegistry WHERE registry_id = 'localUpdateCount'") { row in
                updateCount = row.int(0)
            }
            guard var updateCount else {
                throw SQLiteDatabase.Error(message: "This library has no update counter, so Crate can't safely edit it.")
            }

            for id in ids {
                updateCount += 1
                try database.execute(
                    "UPDATE djmdContent SET ColorID = ?, rb_local_usn = ?, updated_at = ? WHERE ID = ?",
                    [.text(String(color?.id ?? 0)), .int(updateCount), .text(now), .text(id)]
                )
            }
            try database.execute(
                "UPDATE agentRegistry SET int_1 = ?, updated_at = ? WHERE registry_id = 'localUpdateCount'",
                [.int(updateCount), .text(now)]
            )
        }
    }

    /// Rekordbox's timestamp format, e.g. `2026-07-11 23:11:07.856 +00:00`.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
        return formatter
    }()

    /// Updates this in-memory snapshot after a successful `saveColor`.
    mutating func applyColor(_ color: TrackColor?, toTrackIDs ids: [Track.ID]) {
        for id in ids {
            guard var track = tracksByID[id] else { continue }
            track.color = color
            tracks[track.libraryIndex] = track
            tracksByID[id] = track
        }
        sortRanks[\Track.colorSortKey] = Self.ranks(tracks, \.colorSortKey, by: <)
    }

    /// Sorts `tracks` using the precomputed ranks. Ties keep their existing (e.g. playlist) order.
    func sorted(_ tracks: [Track], by comparator: KeyPathComparator<Track>) -> [Track] {
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

    func playlist(withID id: String) -> Playlist? {
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
