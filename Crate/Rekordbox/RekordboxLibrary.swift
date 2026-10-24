import Foundation

/// A snapshot of a Rekordbox 6/7 library, read from its `master.db`.
nonisolated struct RekordboxLibrary: Sendable {
    let location: URL
    let tracks: [Track]
    let tracksByID: [String: Track]
    let playlists: [Playlist]

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
        let tracks = try loadTracks(from: database, artworkRoot: folder.appending(path: "share"))
        let playlists = try loadPlaylists(from: database)

        return RekordboxLibrary(
            location: folder,
            tracks: tracks,
            tracksByID: Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            playlists: playlists
        )
    }

    private static func loadTracks(from database: SQLiteDatabase, artworkRoot: URL) throws -> [Track] {
        var colors: [Int: TrackColor] = [:]
        try database.query("SELECT ID, Commnt FROM djmdColor") { row in
            let id = Int(row.string(0) ?? "") ?? 0
            colors[id] = TrackColor(id: id, name: row.string(1) ?? "")
        }

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
