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
        try RekordboxLibrary.saveColor(wonky, forTrackIDs: [LibraryFixture.copperSun, LibraryFixture.softMachines], in: fixture.folder)

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
        try RekordboxLibrary.saveColor(nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder)
        #expect(try fixture.loadLibrary().tracksByID[LibraryFixture.nightDrive]?.color == nil)
        #expect(try fixture.count("SELECT ColorID FROM djmdContent WHERE ID = '\(LibraryFixture.nightDrive)'") == 0)
    }

    @Test func editsUseRekordboxsTimestampFormat() throws {
        try RekordboxLibrary.saveColor(nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder)
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
            try RekordboxLibrary.saveColor(nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder)
        }
        // Nothing was written.
        #expect(try fixture.count("SELECT ColorID FROM djmdContent WHERE ID = '\(LibraryFixture.nightDrive)'") == 8)
    }

    // MARK: Removing tracks

    @Test func removingATrackDeletesEverythingThatRefersToIt() throws {
        let id = LibraryFixture.nightDrive
        try RekordboxLibrary.removeTracks(withIDs: [id], in: fixture.folder)

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
        try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.nightDrive], in: fixture.folder)

        #expect(try fixture.entries("djmdSongPlaylist", list: "PlaylistID", id: "p2")
            == ["1:\(LibraryFixture.copperSun)", "2:\(LibraryFixture.softMachines)"])
        #expect(try fixture.entries("djmdSongPlaylist", list: "PlaylistID", id: "p3") == [])
        // Night Drive was in this history twice, either side of Soft Machines.
        #expect(try fixture.entries("djmdSongHistory", list: "HistoryID", id: "saturday") == ["1:\(LibraryFixture.softMachines)"])
        #expect(try fixture.entries("djmdSongMyTag", list: "MyTagID", id: LibraryFixture.regridTag) == ["1:\(LibraryFixture.softMachines)"])
    }

    @Test func renumberedRowsGetFreshUpdateNumbers() throws {
        try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.nightDrive], in: fixture.folder)
        // Gaps closed: Warm-up (1), Peak (1, nothing after it), history (2), My Tag (1).
        #expect(try updateCount == LibraryFixture.initialUpdateCount + 5)
        #expect(try fixture.count("SELECT rb_local_usn FROM djmdSongPlaylist WHERE ID = 'sp2'") > LibraryFixture.initialUpdateCount)
        // Rows before the removed track weren't touched.
        #expect(try fixture.count("SELECT count(*) FROM djmdSongPlaylist WHERE ID = 'sp0' AND rb_local_usn IS NULL") == 1)
    }

    @Test func removingSeveralTracks() throws {
        try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.nightDrive, LibraryFixture.copperSun], in: fixture.folder)
        #expect(try fixture.entries("djmdSongPlaylist", list: "PlaylistID", id: "p2") == ["1:\(LibraryFixture.softMachines)"])
        #expect(try fixture.loadLibrary().tracks.map(\.id) == [LibraryFixture.softMachines])
    }
}
