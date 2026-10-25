import Foundation
@testable import RekordboxKit
import Testing

@Suite("Editing master.db")
struct EditingTests {
    let fixture: LibraryFixture

    init() throws {
        fixture = try LibraryFixture()
    }

    private var updateCount: Int {
        get throws { try fixture.count("SELECT int_1 FROM agentRegistry WHERE registry_id = 'localUpdateCount'") }
    }

    // MARK: Colours

    @Test func savingAColourWritesItAndTracksTheChange() throws {
        let wonky = TrackColor(id: 8, name: "Wonky")
        try RekordboxLibrary.saveColor(wonky, forTrackIDs: [LibraryFixture.copperSun, LibraryFixture.softMachines], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)

        let library = try fixture.loadLibrary()
        #expect(library.tracksByID[LibraryFixture.copperSun]?.color == wonky)
        #expect(library.tracksByID[LibraryFixture.softMachines]?.color == wonky)

        // One fresh update number per row, and the counter ends on the last one.
        let initial = LibraryFixture.initialUpdateCount
        #expect(try updateCount == initial + 2)
        #expect(try fixture.count("SELECT rb_local_usn FROM djmdContent WHERE ID = '\(LibraryFixture.copperSun)'") == initial + 1)
        #expect(try fixture.count("SELECT rb_local_usn FROM djmdContent WHERE ID = '\(LibraryFixture.softMachines)'") == initial + 2)
        #expect(try fixture.count("SELECT rb_local_usn FROM djmdContent WHERE ID = '\(LibraryFixture.nightDrive)'") == 1)
    }

    @Test func clearingAColourWritesZero() throws {
        try RekordboxLibrary.saveColor(nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)
        #expect(try fixture.loadLibrary().tracksByID[LibraryFixture.nightDrive]?.color == nil)
        #expect(try fixture.count("SELECT ColorID FROM djmdContent WHERE ID = '\(LibraryFixture.nightDrive)'") == 0)
    }

    @Test func editsUseRekordboxsTimestampFormat() throws {
        try RekordboxLibrary.saveColor(nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)
        var timestamp = ""
        try fixture.database.query("SELECT updated_at FROM djmdContent WHERE ID = '\(LibraryFixture.nightDrive)'") {
            timestamp = $0.string(0) ?? ""
        }
        // e.g. 2026-07-11 23:11:07.856 +00:00
        #expect(timestamp.wholeMatch(of: #/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \+00:00/#) != nil)
    }

    @Test func editingALibraryWithoutAnUpdateCounterFails() throws {
        try fixture.database.execute("DELETE FROM agentRegistry")
        #expect(throws: SQLiteDatabase.Error.self) {
            try RekordboxLibrary.saveColor(nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)
        }
        // Nothing was written.
        #expect(try fixture.count("SELECT ColorID FROM djmdContent WHERE ID = '\(LibraryFixture.nightDrive)'") == 8)
    }

    // MARK: Conflicts

    @Test func loadingRecordsTheUpdateCount() throws {
        #expect(try fixture.loadLibrary().updateCount == LibraryFixture.initialUpdateCount)
    }

    @Test func editsReturnTheNewUpdateCount() throws {
        let afterColour = try RekordboxLibrary.saveColor(
            nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount
        ).updateCount
        #expect(afterColour == LibraryFixture.initialUpdateCount + 1)
        // Crate's own edit doesn't count as a conflict for the next one.
        let afterRemoval = try RekordboxLibrary.removeTracks(
            withIDs: [LibraryFixture.copperSun], in: fixture.folder, expectedUpdateCount: afterColour
        ).updateCount
        #expect(try afterRemoval == updateCount)
    }

    /// Simulates Rekordbox editing the library after Crate loaded it.
    private func editElsewhere() throws {
        try fixture.database.execute("UPDATE djmdContent SET Rating = 5, rb_local_usn = 101 WHERE ID = '\(LibraryFixture.copperSun)'")
        try fixture.database.execute("UPDATE agentRegistry SET int_1 = 101 WHERE registry_id = 'localUpdateCount'")
    }

    @Test func savingAColourIsRefusedIfTheLibraryChanged() throws {
        let stale = try fixture.loadLibrary()
        try editElsewhere()

        #expect(throws: RekordboxLibrary.LibraryChanged.self) {
            try RekordboxLibrary.saveColor(nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: stale.updateCount)
        }
        // Nothing was written.
        #expect(try fixture.count("SELECT ColorID FROM djmdContent WHERE ID = '\(LibraryFixture.nightDrive)'") == 8)
        #expect(try updateCount == 101)
    }

    @Test func removingIsRefusedIfTheLibraryChanged() throws {
        let stale = try fixture.loadLibrary()
        try editElsewhere()

        #expect(throws: RekordboxLibrary.LibraryChanged.self) {
            try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: stale.updateCount)
        }
        #expect(try fixture.count("SELECT count(*) FROM djmdContent") == 3)
        #expect(try fixture.entries("djmdSongPlaylist", list: "PlaylistID", id: "p2").count == 3)
        #expect(try updateCount == 101)
    }

    @Test func reloadingAfterAConflictLetsTheEditThrough() throws {
        try editElsewhere()
        let fresh = try fixture.loadLibrary()
        try RekordboxLibrary.saveColor(nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: fresh.updateCount)
        let library = try fixture.loadLibrary()
        #expect(library.tracksByID[LibraryFixture.nightDrive]?.color == nil)
        // The other edit survived.
        #expect(library.tracksByID[LibraryFixture.copperSun]?.rating == 5)
    }

    @Test func aRefusalReportsBothCounts() throws {
        try editElsewhere()
        let error = try #require(throws: RekordboxLibrary.LibraryChanged.self) {
            try RekordboxLibrary.saveColor(nil, forTrackIDs: [], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)
        }
        #expect(error.expectedUpdateCount == LibraryFixture.initialUpdateCount)
        #expect(error.actualUpdateCount == 101)
    }

    // MARK: Removing tracks

    @Test func removingATrackDeletesEverythingThatRefersToIt() throws {
        let id = LibraryFixture.nightDrive
        try RekordboxLibrary.removeTracks(withIDs: [id], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)

        for (table, column) in [
            ("djmdContent", "ID"), ("djmdSongPlaylist", "ContentID"), ("djmdSongHistory", "ContentID"),
            ("djmdCue", "ContentID"), ("djmdSongMyTag", "ContentID"), ("contentFile", "ContentID"), ("djmdMixerParam", "ContentID"),
        ] {
            #expect(try fixture.count("SELECT count(*) FROM \(table) WHERE \(column) = '\(id)'") == 0, "\(table) still refers to the track")
        }
        let library = try fixture.loadLibrary()
        #expect(library.tracks.map(\.id) == [LibraryFixture.copperSun, LibraryFixture.softMachines])
    }

    @Test func removingATrackRenumbersTheListsItWasIn() throws {
        try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)

        #expect(try fixture.entries("djmdSongPlaylist", list: "PlaylistID", id: "p2")
            == ["1:\(LibraryFixture.copperSun)", "2:\(LibraryFixture.softMachines)"])
        #expect(try fixture.entries("djmdSongPlaylist", list: "PlaylistID", id: "p3") == [])
        // Night Drive was in this history twice, either side of Soft Machines.
        #expect(try fixture.entries("djmdSongHistory", list: "HistoryID", id: "saturday") == ["1:\(LibraryFixture.softMachines)"])
        // My Tag entries aren't numbered, so there's nothing to renumber; the other entry is untouched.
        #expect(try fixture.count("SELECT count(*) FROM djmdSongMyTag WHERE ContentID = '\(LibraryFixture.softMachines)' AND TrackNo IS NULL AND rb_local_usn IS NULL") == 1)
    }

    @Test func renumberedRowsGetFreshUpdateNumbers() throws {
        try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)
        // One update number per gap that moved anything: Warm-up (Soft Machines moves up) and the
        // history (Soft Machines moves up past the first Night Drive). Night Drive was last in Peak
        // and last in the history, so nothing follows those gaps, and My Tags aren't numbered.
        #expect(try updateCount == LibraryFixture.initialUpdateCount + 2)
        #expect(try fixture.count("SELECT rb_local_usn FROM djmdSongPlaylist WHERE ID = 'sp2'") > LibraryFixture.initialUpdateCount)
        // Rows before the removed track weren't touched.
        #expect(try fixture.count("SELECT count(*) FROM djmdSongPlaylist WHERE ID = 'sp0' AND rb_local_usn IS NULL") == 1)
    }

    private func exists(_ table: String, _ id: String) throws -> Bool {
        try fixture.count("SELECT count(*) FROM \(table) WHERE ID = '\(id)'") == 1
    }

    @Test func removingATrackDeletesArtistsAlbumsAndGenresOnlyItUsed() throws {
        try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.copperSun], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)
        #expect(try !exists("djmdArtist", "2"), "the track's artist")
        #expect(try !exists("djmdArtist", "4"), "the track's remixer")
        #expect(try !exists("djmdAlbum", "2"), "the track's album")
        #expect(try !exists("djmdArtist", "3"), "the album's artist, only used by that album")
        // Night Drive and Soft Machines still use these.
        #expect(try exists("djmdArtist", "1"))
        #expect(try exists("djmdAlbum", "1"))
        #expect(try exists("djmdGenre", "1"))
    }

    @Test func sharedArtistsAlbumsAndGenresAreKept() throws {
        try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)
        // Soft Machines has the same artist, album and genre.
        #expect(try exists("djmdArtist", "1"))
        #expect(try exists("djmdAlbum", "1"))
        #expect(try exists("djmdGenre", "1"))
    }

    @Test func removingEveryTrackThatUsesThemDeletesThem() throws {
        try RekordboxLibrary.removeTracks(
            withIDs: [LibraryFixture.nightDrive, LibraryFixture.softMachines], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount
        )
        #expect(try !exists("djmdArtist", "1"))
        #expect(try !exists("djmdAlbum", "1"))
        #expect(try !exists("djmdGenre", "1"))
    }

    @Test func otherUnusedRowsAreLeftAlone() throws {
        try RekordboxLibrary.removeTracks(
            withIDs: [LibraryFixture.nightDrive, LibraryFixture.copperSun, LibraryFixture.softMachines],
            in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount
        )
        #expect(try exists("djmdArtist", "99"))
        #expect(try exists("djmdAlbum", "99"))
        #expect(try exists("djmdGenre", "99"))
    }

    @Test func artistsUsedOnlyAsAnAlbumArtistAreKept() throws {
        // Various Artists is only an album artist; give its album to Soft Machines so it stays in use.
        try fixture.database.execute("UPDATE djmdContent SET AlbumID = '2' WHERE ID = '\(LibraryFixture.softMachines)'")
        try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.copperSun], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)
        #expect(try exists("djmdAlbum", "2"))
        #expect(try exists("djmdArtist", "3"))
    }

    @Test func removingSeveralTracks() throws {
        try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.nightDrive, LibraryFixture.copperSun], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)
        #expect(try fixture.entries("djmdSongPlaylist", list: "PlaylistID", id: "p2") == ["1:\(LibraryFixture.softMachines)"])
        #expect(try fixture.loadLibrary().tracks.map(\.id) == [LibraryFixture.softMachines])
    }
}
