import Foundation
@testable import RekordboxKit
import Testing

@Suite("Loading a library")
struct LoadingTests {
    let fixture: LibraryFixture
    let library: RekordboxLibrary

    init() throws {
        fixture = try LibraryFixture()
        library = try fixture.loadLibrary()
    }

    @Test func loadsTracksWithJoinedNames() throws {
        let track = try #require(library.tracksByID[LibraryFixture.nightDrive])
        #expect(track.title == "Night Drive")
        #expect(track.artist == "Halcyon Static")
        #expect(track.album == "Afterhours")
        #expect(track.genre == "House")
        #expect(track.key == "Am")
        #expect(track.bpm == 122)
        #expect(track.rating == 4)
        #expect(track.playCount == 5)
        #expect(track.color?.name == "Wonky")
    }

    @Test func missingJoinsAreEmpty() throws {
        let track = try #require(library.tracksByID[LibraryFixture.copperSun])
        #expect(track.genre == "")
        #expect(track.color == nil)
    }

    @Test func dateAddedComesFromStockDate() throws {
        #expect(library.tracksByID[LibraryFixture.nightDrive]?.dateAdded == "2026-10-20")
    }

    @Test func memoryCuesAreSortedSecondsWithoutHotCues() throws {
        #expect(library.tracksByID[LibraryFixture.nightDrive]?.memoryCues == [1, 30])
    }

    @Test func analysisURLPointsAtTheEXTFile() throws {
        let url = try #require(library.tracksByID[LibraryFixture.nightDrive]?.analysisURL)
        #expect(url.path.hasSuffix("share/PIONEER/USBANLZ/101/ANLZ0000.EXT"))
    }

    @Test func myTags() throws {
        #expect(library.myTags == [LibraryFixture.regridTag: "Regrid"])
        #expect(library.tracksByID[LibraryFixture.softMachines]?.myTagIDs == [LibraryFixture.regridTag])
    }

    @Test func coloursAreInRekordboxOrder() {
        #expect(library.colors.map(\.id) == Array(1...8))
    }

    @Test func playlistTreeFollowsSeq() throws {
        #expect(library.playlists.map(\.name) == ["Sets", "Peak", "Unrated"])
        let sets = library.playlists[0]
        #expect(sets.kind == .folder)
        #expect(sets.children?.map(\.name) == ["Warm-up"])
        // Leaves have no children array, so List doesn't draw a disclosure triangle.
        #expect(library.playlists[1].children == nil)
    }

    @Test func playlistTracksAreInTrackNoOrder() throws {
        let warmUp = try #require(library.playlist(withID: "p2"))
        #expect(library.tracks(in: warmUp).map(\.id) == [LibraryFixture.copperSun, LibraryFixture.nightDrive, LibraryFixture.softMachines])
    }

    @Test func smartPlaylistsHaveRules() throws {
        let unrated = try #require(library.playlist(withID: "p4"))
        #expect(unrated.kind == .smart)
        #expect(try library.smartTracks(in: unrated).map(\.id) == [LibraryFixture.copperSun])
    }

    @Test func playlistCountIgnoresFoldersAndSmartPlaylists() {
        #expect(library.playlistCount(containing: [LibraryFixture.nightDrive]) == 2)
        #expect(library.playlistCount(containing: [LibraryFixture.copperSun]) == 1)
    }

    @Test func missingDatabaseThrows() {
        #expect(throws: (any Error).self) {
            try RekordboxLibrary.load(from: fixture.folder.appending(path: "nowhere"))
        }
    }
}
