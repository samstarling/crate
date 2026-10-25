import Foundation
@testable import RekordboxKit

/// A small, encrypted Rekordbox library in a temporary folder, built from Rekordbox's real table
/// definitions (`Fixtures/schema.sql`).
///
/// Contents:
/// - Tracks: "Night Drive" (Halcyon Static, album "Afterhours", House, Am, 122 BPM, 4 stars, Wonky,
///   2 memory cues and a hot cue, My Tag "Regrid"), "Copper Sun" (Mara Vey, remixed by Lowfield,
///   album "Copper Sun EP" by Various Artists, no genre, C, unrated, never played) and
///   "Soft Machines " (trailing space; Halcyon Static, album "Afterhours", House, unanalysed,
///   My Tag "Regrid").
/// - Unused rows no track refers to: artist "Nobody", album "Lost Album", genre "Unused".
/// - Playlists: folder "Sets" containing "Warm-up" (Copper Sun, Night Drive, Soft Machines);
///   "Peak" (Night Drive); smart playlist "Unrated" (rating is 0).
/// - History "Saturday": Night Drive, Soft Machines, Night Drive.
final class LibraryFixture {
    static let nightDrive = "101"
    static let copperSun = "102"
    static let softMachines = "103"
    static let regridTag = "9001"
    static let initialUpdateCount = 100

    let folder: URL
    let database: SQLiteDatabase

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "RekordboxKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        database = try SQLiteDatabase(url: folder.appending(path: "master.db"), key: RekordboxLibrary.databaseKey, access: .create)

        guard let schemaURL = Bundle.module.url(forResource: "schema", withExtension: "sql", subdirectory: "Fixtures") else {
            throw SQLiteDatabase.Error(message: "Fixtures/schema.sql is missing from the test bundle.")
        }
        try database.execute(String(contentsOf: schemaURL, encoding: .utf8))
        try populate()
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func loadLibrary() throws -> RekordboxLibrary {
        try RekordboxLibrary.load(from: folder)
    }

    /// Inserts a row, filling in the timestamps every Rekordbox table requires.
    func insert(_ table: String, _ values: [String: SQLiteDatabase.Value]) throws {
        var values = values
        values["created_at"] = values["created_at"] ?? .text("2026-01-01 00:00:00.000 +00:00")
        values["updated_at"] = values["updated_at"] ?? .text("2026-01-01 00:00:00.000 +00:00")
        let columns = values.keys.sorted()
        try database.execute(
            "INSERT INTO \(table) (\(columns.map { "`\($0)`" }.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))",
            columns.map { values[$0]! }
        )
    }

    /// Runs a query that returns a single integer.
    func count(_ sql: String) throws -> Int {
        var result = 0
        try database.query(sql) { result = $0.int(0) }
        return result
    }

    /// The content IDs in an ordered list, by `TrackNo`, with their positions.
    func entries(_ table: String, list column: String, id: String) throws -> [String] {
        var entries: [String] = []
        try database.query("SELECT TrackNo, ContentID FROM \(table) WHERE \(column) = ? ORDER BY TrackNo", [.text(id)]) { row in
            entries.append("\(row.int(0)):\(row.string(1) ?? "")")
        }
        return entries
    }

    private func populate() throws {
        try insert("agentRegistry", ["registry_id": .text("localUpdateCount"), "int_1": .int(Self.initialUpdateCount)])

        for (id, name) in ["Rhythmic", "Intense", "Moody", "Yellow", "Melodic", "Chuggy", "Breaksy", "Wonky"].enumerated() {
            try insert("djmdColor", ["ID": .text(String(id + 1)), "Commnt": .text(name), "SortKey": .int(id + 1)])
        }
        try insert("djmdArtist", ["ID": .text("1"), "Name": .text("Halcyon Static")])
        try insert("djmdArtist", ["ID": .text("2"), "Name": .text("Mara Vey")])
        try insert("djmdArtist", ["ID": .text("3"), "Name": .text("Various Artists")])
        try insert("djmdArtist", ["ID": .text("4"), "Name": .text("Lowfield")])
        try insert("djmdArtist", ["ID": .text("99"), "Name": .text("Nobody")])
        try insert("djmdAlbum", ["ID": .text("1"), "Name": .text("Afterhours"), "AlbumArtistID": .text("1")])
        try insert("djmdAlbum", ["ID": .text("2"), "Name": .text("Copper Sun EP"), "AlbumArtistID": .text("3")])
        try insert("djmdAlbum", ["ID": .text("99"), "Name": .text("Lost Album"), "AlbumArtistID": .text("99")])
        try insert("djmdGenre", ["ID": .text("1"), "Name": .text("House")])
        try insert("djmdGenre", ["ID": .text("99"), "Name": .text("Unused")])
        try insert("djmdKey", ["ID": .text("1"), "ScaleName": .text("Am")])
        try insert("djmdKey", ["ID": .text("2"), "ScaleName": .text("C")])

        try insertTrack(Self.nightDrive, title: "Night Drive", artist: "1", album: "1", genre: "1", key: "1", bpm: 12200,
                        rating: 4, stockDate: "2026-10-20", plays: 5, color: "8")
        try insertTrack(Self.copperSun, title: "Copper Sun", artist: "2", album: "2", genre: nil, key: "2", bpm: 12000,
                        rating: 0, stockDate: "2025-01-01", plays: 0, color: "0", remixer: "4")
        try insertTrack(Self.softMachines, title: "Soft Machines ", artist: "1", album: "1", genre: "1", key: nil, bpm: 0,
                        rating: 2, stockDate: "2026-10-01", plays: 2, color: "0")

        // Cues: Kind 0 is a memory cue, 1–8 are hot cues.
        try insert("djmdCue", ["ID": .text("c1"), "ContentID": .text(Self.nightDrive), "InMsec": .int(30_000), "Kind": .int(0)])
        try insert("djmdCue", ["ID": .text("c2"), "ContentID": .text(Self.nightDrive), "InMsec": .int(1_000), "Kind": .int(0)])
        try insert("djmdCue", ["ID": .text("c3"), "ContentID": .text(Self.nightDrive), "InMsec": .int(60_000), "Kind": .int(1)])

        try insert("djmdMyTag", ["ID": .text("1"), "Name": .text("Custom"), "Attribute": .int(1), "ParentID": .text("root"), "Seq": .int(1)])
        try insert("djmdMyTag", ["ID": .text(Self.regridTag), "Name": .text("Regrid"), "Attribute": .int(0), "ParentID": .text("1"), "Seq": .int(1)])
        // My Tag entries aren't numbered: TrackNo is NULL in real libraries.
        try insert("djmdSongMyTag", ["ID": .text("mt1"), "MyTagID": .text(Self.regridTag), "ContentID": .text(Self.nightDrive)])
        try insert("djmdSongMyTag", ["ID": .text("mt2"), "MyTagID": .text(Self.regridTag), "ContentID": .text(Self.softMachines)])

        try insert("djmdPlaylist", ["ID": .text("p1"), "Name": .text("Sets"), "Attribute": .int(1), "ParentID": .text("root"), "Seq": .int(1)])
        try insert("djmdPlaylist", ["ID": .text("p2"), "Name": .text("Warm-up"), "Attribute": .int(0), "ParentID": .text("p1"), "Seq": .int(1)])
        try insert("djmdPlaylist", ["ID": .text("p3"), "Name": .text("Peak"), "Attribute": .int(0), "ParentID": .text("root"), "Seq": .int(2)])
        try insert("djmdPlaylist", [
            "ID": .text("p4"), "Name": .text("Unrated"), "Attribute": .int(4), "ParentID": .text("root"), "Seq": .int(3),
            "SmartList": .text(#"<?xml version="1.0" encoding="UTF-8"?> <NODE Id="4" LogicalOperator="1" AutomaticUpdate="0"><CONDITION PropertyName="rating" Operator="1" ValueUnit="" ValueLeft="0" ValueRight="0"/></NODE>"#),
        ])
        for (number, track) in [Self.copperSun, Self.nightDrive, Self.softMachines].enumerated() {
            try insert("djmdSongPlaylist", ["ID": .text("sp\(number)"), "PlaylistID": .text("p2"), "ContentID": .text(track), "TrackNo": .int(number + 1)])
        }
        try insert("djmdSongPlaylist", ["ID": .text("sp9"), "PlaylistID": .text("p3"), "ContentID": .text(Self.nightDrive), "TrackNo": .int(1)])

        for (number, track) in [Self.nightDrive, Self.softMachines, Self.nightDrive].enumerated() {
            try insert("djmdSongHistory", ["ID": .text("h\(number)"), "HistoryID": .text("saturday"), "ContentID": .text(track), "TrackNo": .int(number + 1)])
        }

        try insert("contentFile", ["ID": .text("f1"), "ContentID": .text(Self.nightDrive), "Path": .text("/PIONEER/USBANLZ/101/ANLZ0000.DAT")])
        try insert("djmdMixerParam", ["ID": .text("mx1"), "ContentID": .text(Self.nightDrive), "GainHigh": .int(0)])
    }

    private func insertTrack(
        _ id: String, title: String, artist: String, album: String, genre: String?, key: String?, bpm: Int,
        rating: Int, stockDate: String, plays: Int, color: String, remixer: String? = nil
    ) throws {
        var values: [String: SQLiteDatabase.Value] = [
            "ID": .text(id), "Title": .text(title), "ArtistID": .text(artist), "AlbumID": .text(album),
            "BPM": .int(bpm), "Length": .int(300),
            "Rating": .int(rating), "StockDate": .text(stockDate), "DateCreated": .text(stockDate),
            "DJPlayCount": .int(plays), "ColorID": .text(color), "FolderPath": .text("/Music/\(title).mp3"),
            "AnalysisDataPath": .text("/PIONEER/USBANLZ/\(id)/ANLZ0000.DAT"), "rb_local_usn": .int(1),
        ]
        if let genre { values["GenreID"] = .text(genre) }
        if let key { values["KeyID"] = .text(key) }
        if let remixer { values["RemixerID"] = .text(remixer) }
        try insert("djmdContent", values)
    }
}
