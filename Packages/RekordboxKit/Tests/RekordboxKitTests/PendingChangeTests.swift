import Foundation
@testable import RekordboxKit
import Testing

@Suite("Pending changes")
struct PendingChangeTests {
    let fixture: LibraryFixture
    let library: RekordboxLibrary

    init() throws {
        fixture = try LibraryFixture()
        library = try fixture.loadLibrary()
    }

    // MARK: In memory

    @Test func aColourChangeShowsInMemory() throws {
        let changed = library.applying([.setColor(colorID: 1, trackIDs: [LibraryFixture.copperSun])])
        #expect(changed.tracksByID[LibraryFixture.copperSun]?.color?.name == "Rhythmic")
        #expect(changed.tracks.first { $0.id == LibraryFixture.copperSun }?.color?.name == "Rhythmic")
        // The original is untouched, and nothing was written.
        #expect(library.tracksByID[LibraryFixture.copperSun]?.color == nil)
        #expect(try fixture.loadLibrary().tracksByID[LibraryFixture.copperSun]?.color == nil)
    }

    @Test func aRemovalTakesTracksOutOfTheCollectionAndPlaylists() throws {
        let changed = library.applying([.remove(trackIDs: [LibraryFixture.nightDrive], movingFilesToTrash: false)])
        #expect(changed.tracks.map(\.id) == [LibraryFixture.copperSun, LibraryFixture.softMachines])
        #expect(changed.tracksByID[LibraryFixture.nightDrive] == nil)
        let warmUp = try #require(changed.playlist(withID: "p2"))
        #expect(changed.tracks(in: warmUp).map(\.id) == [LibraryFixture.copperSun, LibraryFixture.softMachines])
        #expect(try #require(changed.playlist(withID: "p3")).trackIDs.isEmpty)
        #expect(changed.playlistCount(containing: [LibraryFixture.nightDrive]) == 0)
    }

    @Test func tracksAreRenumberedSoSortingStillWorks() {
        let changed = library.applying([.remove(trackIDs: [LibraryFixture.copperSun], movingFilesToTrash: false)])
        #expect(changed.tracks.map(\.libraryIndex) == [0, 1])
        #expect(changed.sorted(changed.tracks, by: KeyPathComparator(\.title, comparator: .localizedStandard)).map(\.title)
            == ["Night Drive", "Soft Machines "])
    }

    @Test func smartPlaylistsSeePendingChanges() throws {
        let unrated = try #require(library.playlist(withID: "p4"))
        let changed = library.applying([.remove(trackIDs: [LibraryFixture.copperSun], movingFilesToTrash: false)])
        #expect(try changed.smartTracks(in: unrated).isEmpty)
    }

    @Test func changesApplyInOrder() {
        let changed = library.applying([
            .setColor(colorID: 1, trackIDs: [LibraryFixture.copperSun]),
            .setColor(colorID: 2, trackIDs: [LibraryFixture.copperSun]),
        ])
        #expect(changed.tracksByID[LibraryFixture.copperSun]?.color?.name == "Intense")
    }

    // MARK: Writing

    @Test func applyingWritesEveryChangeInOneTransaction() throws {
        let changes = try RekordboxLibrary.apply(
            [
                .setColor(colorID: 1, trackIDs: [LibraryFixture.copperSun]),
                .remove(trackIDs: [LibraryFixture.nightDrive], movingFilesToTrash: true),
            ],
            in: fixture.folder, expectedUpdateCount: library.updateCount
        )
        let saved = try fixture.loadLibrary()
        #expect(saved.tracksByID[LibraryFixture.copperSun]?.color?.name == "Rhythmic")
        #expect(saved.tracksByID[LibraryFixture.nightDrive] == nil)
        #expect(saved.updateCount == changes.updateCount)
        // What's written matches what was shown in memory.
        let shown = library.applying([
            .setColor(colorID: 1, trackIDs: [LibraryFixture.copperSun]),
            .remove(trackIDs: [LibraryFixture.nightDrive], movingFilesToTrash: true),
        ])
        #expect(saved.tracks.map(\.id) == shown.tracks.map(\.id))
        #expect(saved.tracks.map(\.color) == shown.tracks.map(\.color))
    }

    @Test func aConflictRefusesTheWholeBatch() throws {
        try fixture.database.execute("UPDATE agentRegistry SET int_1 = 999 WHERE registry_id = 'localUpdateCount'")
        let before = try fixture.contents()
        #expect(throws: RekordboxLibrary.LibraryChanged.self) {
            try RekordboxLibrary.apply(
                [.setColor(colorID: 1, trackIDs: [LibraryFixture.copperSun]), .remove(trackIDs: [LibraryFixture.nightDrive], movingFilesToTrash: false)],
                in: fixture.folder, expectedUpdateCount: library.updateCount
            )
        }
        #expect(try fixture.contents() == before)
    }

    @Test func aBatchRevertsExactly() throws {
        let original = try fixture.contents()
        let changes = try RekordboxLibrary.apply(
            [
                .setColor(colorID: 3, trackIDs: [LibraryFixture.nightDrive, LibraryFixture.softMachines]),
                .remove(trackIDs: [LibraryFixture.nightDrive], movingFilesToTrash: false),
                .remove(trackIDs: [LibraryFixture.copperSun], movingFilesToTrash: false),
            ],
            in: fixture.folder, expectedUpdateCount: library.updateCount
        )
        try RekordboxLibrary.revert(changes, in: fixture.folder)
        #expect(try fixture.contents() == original)
    }

    // MARK: Revalidating and describing

    @Test func revalidatingDropsTracksThatHaveGone() {
        let change = PendingChange.setColor(colorID: 1, trackIDs: [LibraryFixture.copperSun, "gone"])
        #expect(change.revalidated(against: library) == .setColor(colorID: 1, trackIDs: [LibraryFixture.copperSun]))
        #expect(PendingChange.remove(trackIDs: ["gone"], movingFilesToTrash: true).revalidated(against: library) == nil)
    }

    @Test func revalidatedStagedChangesAreDescribedAgain() throws {
        let staged = StagedChange(.remove(trackIDs: [LibraryFixture.copperSun, "gone"], movingFilesToTrash: false), summary: "Remove 2 tracks")
        let revalidated = try #require(staged.revalidated(against: library))
        #expect(revalidated.summary == "Remove \u{201C}Copper Sun\u{201D}")
        #expect(revalidated.id == staged.id)
    }

    @Test(arguments: [
        (PendingChange.setColor(colorID: 8, trackIDs: [LibraryFixture.nightDrive]), "Set \u{201C}Night Drive\u{201D} to Wonky"),
        (.setColor(colorID: nil, trackIDs: [LibraryFixture.nightDrive, LibraryFixture.copperSun]), "Clear the colour of 2 tracks"),
        (.remove(trackIDs: [LibraryFixture.copperSun], movingFilesToTrash: false), "Remove \u{201C}Copper Sun\u{201D}"),
        (.remove(trackIDs: [LibraryFixture.copperSun, LibraryFixture.nightDrive], movingFilesToTrash: true), "Remove 2 tracks and move their files to the Trash"),
    ])
    func summaries(change: PendingChange, summary: String) {
        #expect(change.summary(in: library) == summary)
    }

    // MARK: Saving

    @Test func pendingChangesAreSavedPerLibrary() throws {
        let store = PendingChangeStore(directory: fixture.folder.appending(path: "Pending"))
        let a = URL(filePath: "/Libraries/A", directoryHint: .isDirectory)
        let b = URL(filePath: "/Libraries/B", directoryHint: .isDirectory)
        let changes = [StagedChange(.setColor(colorID: 1, trackIDs: ["1"]), summary: "Set a track to Rhythmic")]
        try store.save(changes, forLibraryAt: a)

        #expect(store.load(forLibraryAt: a) == changes)
        #expect(store.load(forLibraryAt: b).isEmpty)

        try store.save([], forLibraryAt: a)
        #expect(store.load(forLibraryAt: a).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }

    @Test func journalEntriesFromBeforeBatchingStillLoad() throws {
        let json = #"{"id":"6B1C1F43-8E9A-4E6E-9A5F-1D9E2C3B4A5D","date":"2026-10-25T10:00:00Z","summary":"Removing a track","libraryLocation":"file:///Libraries/A/","changes":{"rows":[],"lists":[],"updateCount":5},"trashedFiles":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(JournalEntry.self, from: Data(json.utf8))
        #expect(entry.summary == "Removing a track")
        #expect(entry.items.isEmpty)
    }
}
