import Foundation

extension RekordboxLibrary {
    // MARK: Applying changes

    /// Writes pending changes to `master.db` in `folder`, in order, in one transaction: either all
    /// of them are saved or none are.
    /// - Returns: What changed, including the library's new update count.
    /// - Throws: `LibraryChanged` if the library's update count isn't `expectedUpdateCount`.
    @discardableResult
    public static func apply(_ changes: [PendingChange], in folder: URL, expectedUpdateCount: Int?) throws -> ChangeSet {
        try edit(in: folder, expectedUpdateCount: expectedUpdateCount) { editor in
            for change in changes {
                switch change {
                case .setColor(let colorID, let ids):
                    for id in ids {
                        try editor.update("djmdContent", set: "ColorID = ?", [.text(String(colorID ?? 0))], where: "ID = ?", [.text(id)])
                    }
                case .remove(let ids, _):
                    try removeTracks(withIDs: ids, with: editor)
                }
            }
        }
    }

    /// Writes a new colour (or none) for the given tracks to `master.db` in `folder`.
    @discardableResult
    public static func saveColor(
        _ color: TrackColor?, forTrackIDs ids: [Track.ID], in folder: URL, expectedUpdateCount: Int?
    ) throws -> ChangeSet {
        try apply([.setColor(colorID: color?.id, trackIDs: ids)], in: folder, expectedUpdateCount: expectedUpdateCount)
    }

    // MARK: Removing tracks

    /// Tables holding ordered lists of tracks, and the column naming which list (`nil` for a single
    /// list). When a track is removed, later tracks in the same list move up to close the gap.
    private static let orderedTrackTables: [(table: String, list: String?)] = [
        ("djmdSongPlaylist", "PlaylistID"),
        ("djmdSongHistory", "HistoryID"),
        ("djmdSongMyTag", "MyTagID"),
        ("djmdSongRelatedTracks", "RelatedTracksID"),
        ("djmdSongSampler", "SamplerID"),
        ("djmdSongHotCueBanklist", "HotCueBanklistID"),
        ("djmdCloudExportSongPlaylist", "CloudExportPlaylistID"),
        ("djmdSongTagList", nil),
    ]

    /// Other rows that belong to a track, by table and the column holding the track's ID.
    private static let trackDetailTables: [(table: String, column: String)] = [
        ("djmdCue", "ContentID"),
        ("contentCue", "ContentID"),
        ("contentFile", "ContentID"),
        ("djmdMixerParam", "ContentID"),
        ("djmdActiveCensor", "ContentID"),
        ("contentActiveCensor", "ContentID"),
        ("djmdRecommendLike", "ContentID1"),
        ("djmdRecommendLike", "ContentID2"),
    ]

    /// Columns of `djmdContent` that refer to an artist. Albums refer to one too, as their album
    /// artist. (Lyricist doesn't seem to hold artist IDs, but counting it can only keep an artist.)
    private static let trackArtistColumns = ["ArtistID", "RemixerID", "OrgArtistID", "ComposerID", "Lyricist"]

    /// Removes tracks from the collection in `master.db` in `folder`, along with every row that
    /// refers to them: playlist and history entries, cues, My Tags and so on.
    ///
    /// This mirrors what Rekordbox does: rows are deleted rather than marked deleted, and later
    /// tracks in each numbered list are renumbered. Artists, albums and genres that only the removed
    /// tracks used are deleted too. The audio files and Rekordbox's analysis files are left on disk.
    @discardableResult
    public static func removeTracks(withIDs ids: [Track.ID], in folder: URL, expectedUpdateCount: Int?) throws -> ChangeSet {
        try apply([.remove(trackIDs: ids, movingFilesToTrash: false)], in: folder, expectedUpdateCount: expectedUpdateCount)
    }

    private static func removeTracks(withIDs ids: [Track.ID], with editor: Editor) throws {
        var artists = Set<String>(), albums = Set<String>(), genres = Set<String>()
        for id in ids {
            try editor.query(
                "SELECT \(trackArtistColumns.joined(separator: ", ")), AlbumID, GenreID FROM djmdContent WHERE ID = ?", [.text(id)]
            ) { row in
                for column in trackArtistColumns.indices {
                    if let artist = row.string(Int32(column)), !artist.isEmpty { artists.insert(artist) }
                }
                if let album = row.string(Int32(trackArtistColumns.count)), !album.isEmpty { albums.insert(album) }
                if let genre = row.string(Int32(trackArtistColumns.count + 1)), !genre.isEmpty { genres.insert(genre) }
            }

            for (table, list) in orderedTrackTables {
                // Some lists (My Tags, for one) aren't numbered: TrackNo is NULL, so there's no gap to close.
                var positions: [(list: String, trackNo: Int)] = []
                try editor.query(
                    "SELECT \(list ?? "''"), TrackNo FROM \(table) WHERE ContentID = ? AND TrackNo IS NOT NULL", [.text(id)]
                ) { row in
                    positions.append((row.string(0) ?? "", row.int(1)))
                }
                try editor.delete(from: table, where: "ContentID = ?", [.text(id)])

                // Close gaps from the end, so a track listed twice in one list renumbers correctly.
                for position in positions.sorted(by: { $0.trackNo > $1.trackNo }) {
                    let sameList = list.map { "\($0) = ? AND " } ?? ""
                    let listValue: [SQLiteDatabase.Value] = list == nil ? [] : [.text(position.list)]
                    try editor.update(table, set: "TrackNo = TrackNo - 1", where: "\(sameList)TrackNo > ?", listValue + [.int(position.trackNo)])
                    editor.noteRenumbered(ChangeSet.ListReference(table: table, column: list, value: list == nil ? nil : position.list))
                }
            }
            for (table, column) in trackDetailTables {
                try editor.delete(from: table, where: "\(column) = ?", [.text(id)])
            }
            try editor.delete(from: "djmdContent", where: "ID = ?", [.text(id)])
        }
        try deleteUnused(albums: albums, artists: artists, genres: genres, with: editor)
    }

    /// Deletes those of the given albums, artists and genres that no track refers to any more, the
    /// way Rekordbox tidies up after removing tracks. Albums go first, so an album artist only used
    /// by a deleted album goes too. Unused rows the removed tracks didn't refer to are left alone.
    private static func deleteUnused(albums: Set<String>, artists: Set<String>, genres: Set<String>, with editor: Editor) throws {
        var artists = artists
        for album in albums {
            var stillUsed = false
            try editor.query("SELECT 1 FROM djmdContent WHERE AlbumID = ? LIMIT 1", [.text(album)]) { _ in stillUsed = true }
            guard !stillUsed else { continue }
            try editor.query("SELECT AlbumArtistID FROM djmdAlbum WHERE ID = ?", [.text(album)]) { row in
                if let artist = row.string(0), !artist.isEmpty { artists.insert(artist) }
            }
            try editor.delete(from: "djmdAlbum", where: "ID = ?", [.text(album)])
        }

        let artistReferences = trackArtistColumns.map { "SELECT 1 FROM djmdContent WHERE \($0) = ?1" }
            + ["SELECT 1 FROM djmdAlbum WHERE AlbumArtistID = ?1"]
        for artist in artists {
            var stillUsed = false
            try editor.query("SELECT EXISTS (\(artistReferences.joined(separator: " UNION ALL ")))", [.text(artist)]) { row in
                stillUsed = row.int(0) == 1
            }
            if !stillUsed {
                try editor.delete(from: "djmdArtist", where: "ID = ?", [.text(artist)])
            }
        }

        for genre in genres {
            var stillUsed = false
            try editor.query("SELECT 1 FROM djmdContent WHERE GenreID = ? LIMIT 1", [.text(genre)]) { _ in stillUsed = true }
            if !stillUsed {
                try editor.delete(from: "djmdGenre", where: "ID = ?", [.text(genre)])
            }
        }
    }

    // MARK: Reverting

    /// Thrown when a change can't be reverted, because something it changed has been changed again
    /// since and reverting would overwrite that.
    public struct CannotRevert: LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    /// Puts back every row `changes` changed, as it was before, in `master.db` in `folder`.
    ///
    /// Unlike other edits, this doesn't need the whole library to be unchanged since (Rekordbox
    /// changes it all the time, for example when you play a track). Instead, it checks that every
    /// row the change touched is still exactly as the change left it, and that no list it renumbered
    /// has changed, and throws `CannotRevert` if not. Restored rows get fresh update numbers, so
    /// Rekordbox sees them as local edits.
    /// - Returns: The library's new update count.
    @discardableResult
    public static func revert(_ changes: ChangeSet, in folder: URL) throws -> Int {
        try edit(in: folder, expectedUpdateCount: nil, checkingUpdateCount: false) { editor in
            for row in changes.rows {
                var current: [String: SQLiteDatabase.Value]?
                try editor.query("SELECT * FROM \(row.table) WHERE ID = ?", [.text(row.id)]) { current = $0.values() }
                if current != row.after {
                    throw CannotRevert(reason: row.after == nil
                        ? "\(description(of: row.table).capitalizedFirst) this change removed has been added back since, so it can\u{2019}t be reverted."
                        : "\(description(of: row.table).capitalizedFirst) this change affected has been changed since, so reverting would overwrite that.")
                }
            }
            for list in changes.lists {
                let sameList = list.column.map { "\($0) = ? AND " } ?? ""
                let listValue: [SQLiteDatabase.Value] = list.value.map { [.text($0)] } ?? []
                var changedSince = 0
                try editor.query(
                    "SELECT count(*) FROM \(list.table) WHERE \(sameList)rb_local_usn > ?", listValue + [.int(changes.updateCount)]
                ) { changedSince = $0.int(0) }
                if changedSince > 0 {
                    throw CannotRevert(reason: "\(description(of: list.table).capitalizedFirst) this change affected has been changed since, so reverting would overwrite that.")
                }
            }

            for row in changes.rows {
                guard let before = row.before else { continue }
                try editor.restore(row.table, before, replacing: row.after != nil)
            }
        }.updateCount
    }

    /// A description of what a row in `table` is, for messages.
    private static func description(of table: String) -> String {
        switch table {
        case "djmdContent": "a track"
        case "djmdSongPlaylist": "a playlist"
        case "djmdSongHistory": "a history list"
        case "djmdSongMyTag": "a My Tag"
        case "djmdCue", "contentCue": "a cue"
        case "djmdArtist": "an artist"
        case "djmdAlbum": "an album"
        case "djmdGenre": "a genre"
        default: "something"
        }
    }

    // MARK: Transactions

    /// Thrown when an edit is refused because the library has changed since the caller loaded it,
    /// for example in Rekordbox, so the edit may be based on out-of-date information.
    public struct LibraryChanged: LocalizedError {
        public let expectedUpdateCount: Int?
        public let actualUpdateCount: Int

        public var errorDescription: String? {
            "Your Rekordbox library has changed since Crate loaded it, so Crate didn\u{2019}t save, to avoid overwriting those changes."
        }
    }

    /// Runs `body` in a transaction on `master.db`, recording what it changes.
    ///
    /// The transaction holds SQLite's write lock from the start, so nothing can change the library
    /// between checking `expectedUpdateCount` and writing. Rekordbox must not be running, or it may
    /// overwrite the change.
    ///
    /// - Parameter checkingUpdateCount: Whether to refuse unless the library's update count is
    ///   `expectedUpdateCount`. Only reverting, which checks each row instead, turns this off.
    /// - Returns: What changed, including the new update count.
    private static func edit(
        in folder: URL,
        expectedUpdateCount: Int?,
        checkingUpdateCount: Bool = true,
        _ body: (Editor) throws -> Void
    ) throws -> ChangeSet {
        let database = try SQLiteDatabase(url: folder.appending(path: "master.db"), key: databaseKey, access: .readWrite)

        return try database.transaction {
            guard let updateCount = try readUpdateCount(from: database) else {
                throw SQLiteDatabase.Error(message: "This library has no update counter, so Crate can't safely edit it.")
            }
            if checkingUpdateCount, updateCount != expectedUpdateCount {
                throw LibraryChanged(expectedUpdateCount: expectedUpdateCount, actualUpdateCount: updateCount)
            }

            let editor = Editor(database: database, updateCount: updateCount, now: timestampFormatter.string(from: .now))
            try body(editor)
            try database.execute(
                "UPDATE agentRegistry SET int_1 = ?, updated_at = ? WHERE registry_id = 'localUpdateCount'",
                [.int(editor.updateCount), .text(editor.now)]
            )
            return editor.changes
        }
    }

    static func readUpdateCount(from database: SQLiteDatabase) throws -> Int? {
        var updateCount: Int?
        try database.query("SELECT int_1 FROM agentRegistry WHERE registry_id = 'localUpdateCount'") { row in
            updateCount = row.int(0)
        }
        return updateCount
    }

    /// Rekordbox's timestamp format, e.g. `2026-07-11 23:11:07.856 +00:00`.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
        return formatter
    }()
}

/// The rows an edit changed in `master.db`, as they were before and after, so it can be reverted.
public struct ChangeSet: Hashable, Sendable {
    struct RowChange: Hashable, Sendable {
        let table: String
        let id: String
        /// The row before the edit. (Crate's edits don't insert rows, so this is always set.)
        var before: [String: SQLiteDatabase.Value]?
        /// The row after the edit; `nil` if the edit deleted it.
        var after: [String: SQLiteDatabase.Value]?
    }

    /// A list of tracks, such as a playlist, that the edit renumbered.
    struct ListReference: Hashable, Sendable {
        let table: String
        /// The column naming the list, and the list's ID; `nil` for a table that is one list.
        let column: String?
        let value: String?
    }

    var rows: [RowChange]
    var lists: [ListReference]
    /// The library's update count after the edit.
    public let updateCount: Int

    /// How many rows the edit changed or deleted.
    public var rowCount: Int { rows.count }

    /// A change set with no changes, for example for previews.
    public static let none = ChangeSet(rows: [], lists: [], updateCount: 0)
}

/// Runs an edit's statements, recording every row they change so the edit can be reverted.
///
/// Updates also give the rows they change a fresh `rb_local_usn` from Rekordbox's
/// `localUpdateCount` counter and the edit's timestamp as `updated_at`, the way Rekordbox does, so
/// Rekordbox sees them as local edits.
final class Editor {
    private let database: SQLiteDatabase
    /// The edit's timestamp, in Rekordbox's format.
    let now: String
    private(set) var updateCount: Int
    private var rows: [ChangeSet.RowChange] = []
    private var rowIndices: [String: Int] = [:]
    private var lists: [ChangeSet.ListReference] = []

    init(database: SQLiteDatabase, updateCount: Int, now: String) {
        self.database = database
        self.updateCount = updateCount
        self.now = now
    }

    var changes: ChangeSet {
        ChangeSet(rows: rows, lists: lists, updateCount: updateCount)
    }

    func query(_ sql: String, _ values: [SQLiteDatabase.Value] = [], row: (SQLiteDatabase.Row) throws -> Void) throws {
        try database.query(sql, values, row: row)
    }

    /// Updates the rows matching `condition` with `assignments` (a SQL `SET` list).
    func update(
        _ table: String, set assignments: String, _ setValues: [SQLiteDatabase.Value] = [],
        where condition: String, _ whereValues: [SQLiteDatabase.Value]
    ) throws {
        let ids = try recordRows(in: table, where: condition, whereValues)
        guard !ids.isEmpty else { return }
        updateCount += 1
        try database.execute(
            "UPDATE \(table) SET \(assignments), rb_local_usn = ?, updated_at = ? WHERE \(condition)",
            setValues + [.int(updateCount), .text(now)] + whereValues
        )
        for id in ids {
            try database.query("SELECT * FROM \(table) WHERE ID = ?", [.text(id)]) { row in
                rows[rowIndices[key(table, id)]!].after = row.values()
            }
        }
    }

    /// Deletes the rows matching `condition`.
    func delete(from table: String, where condition: String, _ values: [SQLiteDatabase.Value]) throws {
        let ids = try recordRows(in: table, where: condition, values)
        guard !ids.isEmpty else { return }
        try database.execute("DELETE FROM \(table) WHERE \(condition)", values)
        for id in ids {
            rows[rowIndices[key(table, id)]!].after = nil
        }
    }

    /// Writes a recorded row back, as an update if it still exists or an insert if it was deleted,
    /// with a fresh update number and timestamp.
    func restore(_ table: String, _ row: [String: SQLiteDatabase.Value], replacing: Bool) throws {
        updateCount += 1
        var row = row
        if row["rb_local_usn"] != nil { row["rb_local_usn"] = .int(updateCount) }
        if row["updated_at"] != nil { row["updated_at"] = .text(now) }
        let columns = row.keys.sorted()
        if replacing {
            let assignments = columns.filter { $0 != "ID" }
            try database.execute(
                "UPDATE \(table) SET \(assignments.map { "`\($0)` = ?" }.joined(separator: ", ")) WHERE ID = ?",
                assignments.map { row[$0]! } + [row["ID"]!]
            )
        } else {
            try database.execute(
                "INSERT INTO \(table) (\(columns.map { "`\($0)`" }.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))",
                columns.map { row[$0]! }
            )
        }
    }

    /// Notes that a list of tracks was renumbered, so reverting can check it hasn't changed since.
    func noteRenumbered(_ list: ChangeSet.ListReference) {
        if !lists.contains(list) {
            lists.append(list)
        }
    }

    /// Records the rows matching `condition` as they are now, unless already recorded earlier in
    /// this edit, and returns their IDs.
    private func recordRows(in table: String, where condition: String, _ values: [SQLiteDatabase.Value]) throws -> [String] {
        var ids: [String] = []
        try database.query("SELECT * FROM \(table) WHERE \(condition)", values) { row in
            let values = row.values()
            let id: String
            switch values["ID"] {
            case .text(let text): id = text
            case .int(let int): id = String(int)
            default: throw SQLiteDatabase.Error(message: "Crate can't record a change to \(table), which has no ID column.")
            }
            if rowIndices[key(table, id)] == nil {
                rowIndices[key(table, id)] = rows.count
                rows.append(ChangeSet.RowChange(table: table, id: id, before: values, after: values))
            }
            ids.append(id)
        }
        return ids
    }

    private func key(_ table: String, _ id: String) -> String {
        "\(table)\u{0}\(id)"
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
