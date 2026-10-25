import Foundation
@testable import RekordboxKit
import Testing

@Suite("Recording and reverting changes")
struct RevertTests {
    let fixture: LibraryFixture

    init() throws {
        fixture = try LibraryFixture()
    }

    private var updateCount: Int {
        get throws { try fixture.count("SELECT int_1 FROM agentRegistry WHERE registry_id = 'localUpdateCount'") }
    }

    private func removeNightDrive() throws -> ChangeSet {
        try RekordboxLibrary.removeTracks(withIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount)
    }

    // MARK: Recording

    @Test func aColourChangeRecordsTheRowBeforeAndAfter() throws {
        let changes = try RekordboxLibrary.saveColor(
            nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount
        )
        let row = try #require(changes.rows.first)
        #expect(changes.rows.count == 1)
        #expect(row.table == "djmdContent" && row.id == LibraryFixture.nightDrive)
        #expect(row.before?["ColorID"] == .text("8"))
        #expect(row.after?["ColorID"] == .text("0"))
        #expect(row.after?["rb_local_usn"] == .int(LibraryFixture.initialUpdateCount + 1))
    }

    @Test func aRemovalRecordsEveryDeletedAndRenumberedRow() throws {
        let changes = try removeNightDrive()
        let deleted = Set(changes.rows.filter { $0.after == nil }.map { "\($0.table) \($0.id)" })
        #expect(deleted.isSuperset(of: [
            "djmdContent \(LibraryFixture.nightDrive)", "djmdSongPlaylist sp1", "djmdSongPlaylist sp9",
            "djmdSongHistory h0", "djmdSongHistory h2", "djmdCue c1", "djmdCue c2", "djmdCue c3",
            "djmdSongMyTag mt1", "contentFile f1", "djmdMixerParam mx1",
        ]))
        // Soft Machines moved up in Warm-up and in the history.
        let renumbered = changes.rows.filter { $0.after != nil && $0.before?["TrackNo"] != $0.after?["TrackNo"] }
        #expect(Set(renumbered.map(\.id)) == ["sp2", "h1"])
        #expect(changes.lists.count == 3)
    }

    @Test func aRowChangedTwiceKeepsItsOriginalState() throws {
        // Soft Machines' history entry moves up twice (Night Drive was before and after it), from 2 to 1.
        let changes = try removeNightDrive()
        let entry = try #require(changes.rows.first { $0.id == "h1" })
        #expect(entry.before?["TrackNo"] == .int(2))
        #expect(entry.after?["TrackNo"] == .int(1))
    }

    @Test func changeSetsSurviveBeingSaved() throws {
        let changes = try removeNightDrive()
        let decoded = try JSONDecoder().decode(ChangeSet.self, from: JSONEncoder().encode(changes))
        #expect(decoded == changes)
    }

    // MARK: Reverting

    @Test func revertingARemovalRestoresTheLibraryExactly() throws {
        let original = try fixture.contents()
        let changes = try removeNightDrive()
        #expect(try fixture.contents() != original)

        try RekordboxLibrary.revert(changes, in: fixture.folder)
        #expect(try fixture.contents() == original)
        #expect(try fixture.loadLibrary().tracksByID[LibraryFixture.nightDrive]?.memoryCues == [1, 30])
    }

    @Test func revertingRemovalsThatDeletedArtistsAndAlbumsRestoresThem() throws {
        let original = try fixture.contents()
        let changes = try RekordboxLibrary.removeTracks(
            withIDs: [LibraryFixture.nightDrive, LibraryFixture.copperSun, LibraryFixture.softMachines],
            in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount
        )
        try RekordboxLibrary.revert(changes, in: fixture.folder)
        #expect(try fixture.contents() == original)
    }

    @Test func revertingAColourChangeRestoresTheColour() throws {
        let changes = try RekordboxLibrary.saveColor(
            nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount
        )
        try RekordboxLibrary.revert(changes, in: fixture.folder)
        #expect(try fixture.loadLibrary().tracksByID[LibraryFixture.nightDrive]?.color?.name == "Wonky")
    }

    @Test func restoredRowsGetFreshUpdateNumbers() throws {
        let changes = try removeNightDrive()
        let countAfterRemoval = try updateCount
        let countAfterRevert = try RekordboxLibrary.revert(changes, in: fixture.folder)
        #expect(countAfterRevert == countAfterRemoval + changes.rowCount)
        #expect(try updateCount == countAfterRevert)
        #expect(try fixture.count("SELECT rb_local_usn FROM djmdContent WHERE ID = '\(LibraryFixture.nightDrive)'") > countAfterRemoval)
    }

    @Test func unrelatedChangesSinceDontPreventReverting() throws {
        let changes = try removeNightDrive()
        // Rekordbox edits something the removal didn't touch.
        try fixture.database.execute("UPDATE djmdContent SET DJPlayCount = 9, rb_local_usn = 500 WHERE ID = '\(LibraryFixture.copperSun)'")
        try fixture.database.execute("UPDATE agentRegistry SET int_1 = 500 WHERE registry_id = 'localUpdateCount'")
        try RekordboxLibrary.revert(changes, in: fixture.folder)
        #expect(try fixture.loadLibrary().tracksByID[LibraryFixture.nightDrive] != nil)
    }

    @Test func aRowChangedSinceBlocksReverting() throws {
        let changes = try RekordboxLibrary.saveColor(
            nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount
        )
        try fixture.database.execute("UPDATE djmdContent SET Rating = 1 WHERE ID = '\(LibraryFixture.nightDrive)'")
        #expect(throws: RekordboxLibrary.CannotRevert.self) { try RekordboxLibrary.revert(changes, in: fixture.folder) }
        // Nothing was written.
        #expect(try fixture.loadLibrary().tracksByID[LibraryFixture.nightDrive]?.color == nil)
    }

    @Test func aListChangedSinceBlocksReverting() throws {
        let changes = try removeNightDrive()
        // Rekordbox adds a track to the end of Warm-up.
        try fixture.insert("djmdSongPlaylist", [
            "ID": .text("sp10"), "PlaylistID": .text("p2"), "ContentID": .text(LibraryFixture.copperSun),
            "TrackNo": .int(3), "rb_local_usn": .int(changes.updateCount + 1),
        ])
        let before = try fixture.contents()
        #expect(throws: RekordboxLibrary.CannotRevert.self) { try RekordboxLibrary.revert(changes, in: fixture.folder) }
        #expect(try fixture.contents() == before)
    }

    @Test func aDeletedRowAddedBackBlocksReverting() throws {
        let changes = try removeNightDrive()
        try fixture.insert("djmdCue", ["ID": .text("c1"), "ContentID": .text(LibraryFixture.nightDrive), "InMsec": .int(0), "Kind": .int(0)])
        #expect(throws: RekordboxLibrary.CannotRevert.self) { try RekordboxLibrary.revert(changes, in: fixture.folder) }
    }

    @Test func revertingTwiceIsRefused() throws {
        let changes = try removeNightDrive()
        try RekordboxLibrary.revert(changes, in: fixture.folder)
        #expect(throws: RekordboxLibrary.CannotRevert.self) { try RekordboxLibrary.revert(changes, in: fixture.folder) }
    }

    @Test func aLibraryEditedAfterARevertCanStillBeEdited() throws {
        let changes = try removeNightDrive()
        let count = try RekordboxLibrary.revert(changes, in: fixture.folder)
        try RekordboxLibrary.saveColor(nil, forTrackIDs: [LibraryFixture.nightDrive], in: fixture.folder, expectedUpdateCount: count)
    }
}

@Suite("Journal")
struct JournalTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "JournalTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func entry(_ summary: String, library: String = "/Libraries/A", date: Date) -> JournalEntry {
        JournalEntry(
            summary: summary,
            libraryLocation: URL(filePath: library, directoryHint: .isDirectory),
            changes: ChangeSet(rows: [], lists: [], updateCount: 1),
            date: date
        )
    }

    @Test func savesAndLoadsEntriesNewestFirst() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = Journal(directory: directory)
        try journal.save(entry("Older", date: Date(timeIntervalSince1970: 1)))
        try journal.save(entry("Newer", date: Date(timeIntervalSince1970: 2)))
        try journal.save(entry("Elsewhere", library: "/Libraries/B", date: Date(timeIntervalSince1970: 3)))

        let entries = journal.entries(forLibraryAt: URL(filePath: "/Libraries/A", directoryHint: .isDirectory))
        #expect(entries.map(\.summary) == ["Newer", "Older"])
    }

    @Test func savingAgainUpdatesTheEntry() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = Journal(directory: directory)
        var saved = entry("Removing a track", date: .now)
        try journal.save(saved)
        saved.revertedAt = .now
        saved.trashedFiles = [TrashedFile(original: URL(filePath: "/Music/a.mp3"), inTrash: URL(filePath: "/Trash/a.mp3"))]
        try journal.save(saved)

        let entries = journal.entries(forLibraryAt: saved.libraryLocation)
        #expect(entries.count == 1)
        #expect(entries.first?.isReverted == true)
        #expect(entries.first?.trashedFiles == saved.trashedFiles)
    }

    @Test func unreadableFilesAreSkipped() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = Journal(directory: directory)
        try journal.save(entry("Fine", date: .now))
        try Data("not json".utf8).write(to: directory.appending(path: "broken.json"))
        #expect(journal.entries(forLibraryAt: URL(filePath: "/Libraries/A", directoryHint: .isDirectory)).map(\.summary) == ["Fine"])
    }

    @Test func aMissingDirectoryHasNoEntries() {
        #expect(Journal(directory: directory).entries(forLibraryAt: URL(filePath: "/Libraries/A")).isEmpty)
    }
}
