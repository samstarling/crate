import Foundation
@testable import RekordboxKit
import Testing

/// A library made in Rekordbox 7 (`Fixtures/Library`), so the tests see what Rekordbox really
/// writes rather than what we think it writes. Its credentials and device name were cleared.
///
/// Contents:
/// - Tracks, all in `/Users/Shared/Crate Fixture Tracks` (the audio isn't in the repo):
///   - "Fixture One (120 BPM)": Test Artist A, Test Album, House, 4 stars, a memory cue at 0.49s,
///     hot cue A, My Tags "Acid House", "Synth" and "Main Floor".
///   - "Fixture Two (124 BPM)": Test Artist A, Test Album, Techno, played once.
///   - "Fixture Three (128 BPM)": Test Artist B, no album, House, Red.
///   - "Fixture Four (100 BPM)": Test Artist C, no album, no genre, Pink. Rekordbox stores the
///     missing album as `AlbumID = ''`, not `NULL`.
///   - Eight GROOVE CIRCUIT samples Rekordbox added itself (artist "rekordbox", genre "Loop
///     Samples"), which are also in a sampler list.
/// - Playlists: folder "Test Folder" containing "Test Playlist" (One, Two, Three); "Second
///   Playlist" (Two, Four); smart playlist "Rating is 0"; Rekordbox's own "CUE Analysis Playlist".
/// - History: Fixture Two.
/// - Every track has analysis files with a colour waveform.
enum RekordboxMadeLibrary {
    static let one = "74626202"
    static let two = "95851548"
    static let three = "29922978"
    static let four = "28997904"
    static let samples = ["145943515", "31397823", "65852557", "215610990", "83622986", "257167889", "17806698", "63508914"]
    static let allTracks = [one, two, three, four] + samples

    static let testFolder = "3794728580"
    static let testPlaylist = "4182854841"
    static let secondPlaylist = "1057186289"
    static let ratingIsZero = "1837585237"
    static let history = "1418214891"
    static let sampler = "2097641665"

    static let artistA = "2684656002"
    static let artistB = "3316474607"
    static let artistC = "475122109"
    static let testAlbum = "3368532989"
    static let house = "1022590762"
    static let techno = "2928184487"

    static let updateCount = 1178
}

@Suite("A library Rekordbox made")
struct RekordboxMadeLibraryTests {
    typealias Made = RekordboxMadeLibrary
    let fixture: LibraryFixture

    init() throws {
        fixture = try LibraryFixture.rekordboxMade()
    }

    private func exists(_ table: String, _ id: String) throws -> Bool {
        try fixture.count("SELECT COUNT(*) FROM \(table) WHERE ID = '\(id)'") == 1
    }

    @discardableResult
    private func remove(_ ids: [Track.ID]) throws -> ChangeSet {
        try RekordboxLibrary.removeTracks(withIDs: ids, in: fixture.folder, expectedUpdateCount: Made.updateCount)
    }

    private func integrityCheck() throws -> String {
        var result = ""
        try fixture.database.query("PRAGMA integrity_check") { result = $0.string(0) ?? "" }
        return result
    }

    // MARK: Loading

    @Test func loadsTracksAsRekordboxWroteThem() throws {
        let library = try fixture.loadLibrary()
        #expect(library.tracks.count == 12)
        #expect(library.updateCount == Made.updateCount)

        let one = try #require(library.tracksByID[Made.one])
        #expect(one.title == "Fixture One (120 BPM)")
        #expect(one.artist == "Test Artist A")
        #expect(one.album == "Test Album")
        #expect(one.genre == "House")
        #expect(one.bpm == 120)
        #expect(one.rating == 4)
        #expect(one.fileURL.path == "/Users/Shared/Crate Fixture Tracks/Fixture One (120 BPM).wav")
        // Hot cue A isn't a memory cue.
        #expect(one.memoryCues == [0.49])
        #expect(Set(one.myTagIDs.compactMap { library.myTags[$0] }) == ["Acid House", "Synth", "Main Floor"])

        #expect(library.tracksByID[Made.two]?.playCount == 1)
        #expect(library.tracksByID[Made.three]?.color?.name == "Red")
    }

    @Test func aTrackWithoutAnAlbumHasAnEmptyAlbum() throws {
        let four = try #require(try fixture.loadLibrary().tracksByID[Made.four])
        #expect(try fixture.count("SELECT COUNT(*) FROM djmdContent WHERE ID = '\(Made.four)' AND AlbumID = ''") == 1)
        #expect(four.album == "")
        #expect(four.genre == "")
        #expect(four.artist == "Test Artist C")
        #expect(four.color?.name == "Pink")
    }

    @Test func loadsPlaylistsFoldersAndSmartPlaylists() throws {
        let library = try fixture.loadLibrary()
        let folder = try #require(library.playlist(withID: Made.testFolder))
        #expect(folder.kind == .folder)
        #expect(folder.children?.map(\.id) == [Made.testPlaylist])
        #expect(library.playlist(withID: Made.testPlaylist)?.trackIDs == [Made.one, Made.two, Made.three])
        #expect(library.playlist(withID: Made.secondPlaylist)?.trackIDs == [Made.two, Made.four])

        let smart = try #require(library.playlist(withID: Made.ratingIsZero))
        #expect(smart.kind == .smart)
        #expect(Set(try library.smartTracks(in: smart).map(\.id)) == Set(Made.allTracks).subtracting([Made.one]))
    }

    @Test func readsEveryTracksWaveform() throws {
        for track in try fixture.loadLibrary().tracks {
            let url = try #require(track.analysisURL)
            let waveform = try #require(try Waveform.load(from: url), "\(track.title)")
            #expect(!waveform.entries.isEmpty)
        }
    }

    @Test(arguments: [Made.one, Made.two, Made.three, Made.four])
    func waveformsHave150EntriesASecond(id: Track.ID) throws {
        let track = try #require(try fixture.loadLibrary().tracksByID[id])
        let url = try #require(track.analysisURL)
        let waveform = try #require(try Waveform.load(from: url))
        // Length is in whole seconds.
        #expect(abs(Double(waveform.entries.count) / 150 - Double(track.duration)) <= 1.5)
    }

    // MARK: Editing

    @Test func editsAreStampedLikeRekordboxStampsThem() throws {
        var rekordboxStamp = ""
        try fixture.database.query("SELECT updated_at FROM djmdContent WHERE ID = ?", [.text(Made.one)]) { rekordboxStamp = $0.string(0) ?? "" }

        try RekordboxLibrary.saveColor(TrackColor(id: 5, name: "Green"), forTrackIDs: [Made.one], in: fixture.folder, expectedUpdateCount: Made.updateCount)

        var usn = 0
        var stamp = ""
        try fixture.database.query("SELECT rb_local_usn, updated_at FROM djmdContent WHERE ID = ?", [.text(Made.one)]) { row in
            usn = row.int(0)
            stamp = row.string(1) ?? ""
        }
        #expect(try fixture.loadLibrary().updateCount == Made.updateCount + 1)
        #expect(usn == Made.updateCount + 1)
        let format = #/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \+00:00/#
        #expect(rekordboxStamp.wholeMatch(of: format) != nil)
        #expect(stamp.wholeMatch(of: format) != nil)
        #expect(stamp > rekordboxStamp)
    }

    @Test func removingATrackTakesItOutOfPlaylistsHistoryAndUnusedGenres() throws {
        try remove([Made.two])
        #expect(try fixture.entries("djmdSongPlaylist", list: "PlaylistID", id: Made.testPlaylist) == ["1:\(Made.one)", "2:\(Made.three)"])
        #expect(try fixture.entries("djmdSongPlaylist", list: "PlaylistID", id: Made.secondPlaylist) == ["1:\(Made.four)"])
        #expect(try fixture.entries("djmdSongHistory", list: "HistoryID", id: Made.history) == [])
        #expect(try fixture.count("SELECT COUNT(*) FROM contentFile WHERE ContentID = '\(Made.two)'") == 0)
        #expect(try fixture.count("SELECT COUNT(*) FROM djmdMixerParam WHERE ContentID = '\(Made.two)'") == 0)
        // Techno was Fixture Two's alone; Fixture One still uses the artist and album.
        #expect(try !exists("djmdGenre", Made.techno))
        #expect(try exists("djmdArtist", Made.artistA))
        #expect(try exists("djmdAlbum", Made.testAlbum))
        #expect(try integrityCheck() == "ok")
    }

    @Test func removingATrackWithoutAnAlbumLeavesAlbumsAlone() throws {
        let albums = try fixture.count("SELECT COUNT(*) FROM djmdAlbum")
        try remove([Made.four])
        #expect(try !exists("djmdArtist", Made.artistC))
        #expect(try fixture.count("SELECT COUNT(*) FROM djmdAlbum") == albums)
    }

    @Test func removingTheLastTracksUsingAnArtistAndAlbumDeletesThem() throws {
        try remove([Made.one, Made.two])
        #expect(try !exists("djmdArtist", Made.artistA))
        #expect(try !exists("djmdAlbum", Made.testAlbum))
        #expect(try exists("djmdGenre", Made.house))
        #expect(try fixture.count("SELECT COUNT(*) FROM djmdCue") == 0)
        #expect(try fixture.count("SELECT COUNT(*) FROM djmdSongMyTag") == 0)
    }

    @Test func removingASampleRenumbersTheSamplerList() throws {
        try remove([Made.samples[0]])
        let entries = try fixture.entries("djmdSongSampler", list: "SamplerID", id: Made.sampler)
        #expect(entries == Made.samples.dropFirst().enumerated().map { "\($0.offset + 1):\($0.element)" })
    }

    @Test(arguments: RekordboxMadeLibrary.allTracks)
    func removingATrackAndRevertingRestoresTheLibraryExactly(id: Track.ID) throws {
        let original = try fixture.contents()
        let changes = try remove([id])
        #expect(try fixture.contents() != original)
        try RekordboxLibrary.revert(changes, in: fixture.folder)
        #expect(try fixture.contents() == original)
        #expect(try integrityCheck() == "ok")
    }

    @Test func removingEverythingAndRevertingRestoresTheLibraryExactly() throws {
        let original = try fixture.contents()
        let changes = try remove(Made.allTracks)
        #expect(try fixture.loadLibrary().tracks.isEmpty)
        #expect(try fixture.count("SELECT COUNT(*) FROM djmdArtist") == 0)
        try RekordboxLibrary.revert(changes, in: fixture.folder)
        #expect(try fixture.contents() == original)
    }

    @Test func aChangeSinceLoadingIsRefused() throws {
        try fixture.database.execute("UPDATE agentRegistry SET int_1 = int_1 + 1 WHERE registry_id = 'localUpdateCount'")
        let original = try fixture.contents()
        #expect(throws: RekordboxLibrary.LibraryChanged.self) { try remove([Made.one]) }
        #expect(try fixture.contents() == original)
    }

    @MainActor
    @Test func applyingAndUndoingInASessionRestoresTheLibraryExactly() async throws {
        let session = LibrarySession(library: try fixture.loadLibrary(), files: .none)
        let original = try fixture.contents()
        session.setColor(TrackColor(id: 7, name: "Blue"), forTrackIDs: [Made.one, Made.four])
        session.removeTracks(withIDs: [Made.two, Made.samples[3]], movingFilesToTrash: false)
        try await session.applyPendingChanges()

        let applied = try fixture.loadLibrary()
        #expect(applied.tracksByID[Made.one]?.color?.name == "Blue")
        #expect(applied.tracksByID[Made.two] == nil)
        #expect(applied.playlist(withID: Made.secondPlaylist)?.trackIDs == [Made.four])

        try await session.undo()
        #expect(try fixture.contents() == original)
        try await session.redo()
        #expect(try fixture.loadLibrary().tracksByID[Made.two] == nil)
    }
}
