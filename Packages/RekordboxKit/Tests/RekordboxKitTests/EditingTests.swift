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
        )
        #expect(afterColour == LibraryFixture.initialUpdateCount + 1)
        // Crate's own edit doesn't count as a conflict for the next one.
        let afterRemoval = try RekordboxLibrary.removeTracks(
            withIDs: [LibraryFixture.copperSun], in: fixture.folder, expectedUpdateCount: afterColour
        )
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
        #expect(try fixture.entries("djmdSongMyTag", list: "MyTagID", id: LibraryFixture.regridTag) == ["1:\(LibraryFixture.softMachines)"])
    }

    @Test func renumberedRowsGetFreshUpdateNumbers() throws {
        try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)
        // Gaps closed: Warm-up (1), Peak (1, nothing after it), history (2), My Tag (1).
        #expect(try updateCount == LibraryFixture.initialUpdateCount + 5)
        #expect(try fixture.count("SELECT rb_local_usn FROM djmdSongPlaylist WHERE ID = 'sp2'") > LibraryFixture.initialUpdateCount)
        // Rows before the removed track weren't touched.
        #expect(try fixture.count("SELECT count(*) FROM djmdSongPlaylist WHERE ID = 'sp0' AND rb_local_usn IS NULL") == 1)
    }

    @Test func removingSeveralTracks() throws {
        try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.nightDrive, LibraryFixture.copperSun], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)
        #expect(try fixture.entries("djmdSongPlaylist", list: "PlaylistID", id: "p2") == ["1:\(LibraryFixture.softMachines)"])
        #expect(try fixture.loadLibrary().tracks.map(\.id) == [LibraryFixture.softMachines])
    }
}
