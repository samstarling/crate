import Foundation
@testable import RekordboxKit
import Testing

@Suite("Sorting with precomputed ranks")
struct SortingTests {
    let library: RekordboxLibrary

    init() throws {
        library = try LibraryFixture().loadLibrary()
    }

    private func titles(sortedBy comparator: KeyPathComparator<Track>, _ tracks: [Track]? = nil) -> [String] {
        library.sorted(tracks ?? library.tracks, by: comparator).map(\.title)
    }

    @Test func sortsTextLikeFinder() {
        #expect(titles(sortedBy: KeyPathComparator(\.title, comparator: .localizedStandard))
            == ["Copper Sun", "Night Drive", "Soft Machines "])
    }

    @Test func sortsDescending() {
        #expect(titles(sortedBy: KeyPathComparator(\.bpm, order: .reverse))
            == ["Night Drive", "Copper Sun", "Soft Machines "])
    }

    @Test func tiesKeepTheirExistingOrder() throws {
        // Night Drive and Soft Machines are both House; Copper Sun has no genre.
        let reversed = Array(library.tracks.reversed())
        #expect(titles(sortedBy: KeyPathComparator(\.genre, comparator: .localizedStandard), reversed)
            == ["Copper Sun", "Soft Machines ", "Night Drive"])
    }

    @Test func matchesSortingDirectly() {
        for comparator in [KeyPathComparator(\Track.rating), KeyPathComparator(\.playCount), KeyPathComparator(\.dateAdded)] {
            let expected = library.tracks.sorted(using: comparator).map { $0[keyPath: comparator.keyPath] as! AnyHashable }
            let actual = library.sorted(library.tracks, by: comparator).map { $0[keyPath: comparator.keyPath] as! AnyHashable }
            #expect(actual == expected)
        }
    }

    @Test func applyingAColourUpdatesItsRanks() {
        var library = library
        // Uncoloured tracks sort last; give Copper Sun the first colour.
        library.applyColor(library.colors[0], toTrackIDs: [LibraryFixture.copperSun], updateCount: 101)
        #expect(library.tracksByID[LibraryFixture.copperSun]?.color?.name == "Rhythmic")
        #expect(library.sorted(library.tracks, by: KeyPathComparator(\.colorSortKey)).map(\.id)
            == [LibraryFixture.copperSun, LibraryFixture.nightDrive, LibraryFixture.softMachines])
    }
}
