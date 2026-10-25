import Foundation
@testable import RekordboxKit
import Testing

@Suite("Smart playlist rules")
struct SmartRuleTests {
    /// A rule with one condition, or several combined with `match`.
    private func rule(_ conditions: String..., match: Int = 1) throws -> SmartRule {
        try #require(SmartRule(xml: #"<?xml version="1.0" encoding="UTF-8"?> <NODE Id="1" LogicalOperator="\#(match)" AutomaticUpdate="0">\#(conditions.joined())</NODE>"#))
    }

    private func condition(_ property: String, _ op: Int, _ left: String = "", _ right: String = "", unit: String = "") -> String {
        #"<CONDITION PropertyName="\#(property)" Operator="\#(op)" ValueUnit="\#(unit)" ValueLeft="\#(left)" ValueRight="\#(right)"/>"#
    }

    private func track(
        title: String = "Title", artist: String = "Artist", genre: String = "", key: String = "",
        bpm: Double = 120, rating: Int = 0, playCount: Int = 0, dateAdded: String = "2026-01-01", myTagIDs: [String] = []
    ) -> Track {
        Track(
            id: UUID().uuidString, libraryIndex: 0, title: title, artist: artist, album: "", genre: genre, label: "",
            key: key, bpm: bpm, duration: 300, rating: rating, year: 0, dateAdded: dateAdded, playCount: playCount,
            color: nil, comment: "", fileURL: URL(filePath: "/x.mp3"), artworkURL: nil, analysisURL: nil,
            memoryCues: [], myTagIDs: myTagIDs
        )
    }

    private func matches(_ rule: SmartRule, _ track: Track, myTags: [String: String] = [:], now: Date = .now) throws -> Bool {
        try rule.predicate(myTags: myTags, now: now)(track)
    }

    @Test func parsesConditions() throws {
        let parsed = try rule(condition("stockDate", 6, "30", unit: "day"), match: 2)
        #expect(parsed.match == .any)
        #expect(parsed.conditions == [SmartRule.Condition(property: "stockDate", operatorCode: 6, unit: "day", left: "30", right: "")])
    }

    @Test func invalidXMLIsNil() {
        #expect(SmartRule(xml: "not xml") == nil)
        #expect(SmartRule(xml: "<OTHER/>") == nil)
    }

    @Test func emptyValueMatchesEmptyText() throws {
        let noGenre = try rule(condition("genre", 1))
        #expect(try matches(noGenre, track(genre: "")))
        #expect(try !matches(noGenre, track(genre: "House")))
    }

    @Test(arguments: [
        (8, "dri", true), (8, "xyz", false), (9, "dri", false), (10, "night", true), (10, "drive", false),
        (11, "Drive", true), (11, "Night", false), (1, "NIGHT DRIVE", true), (2, "Night Drive", false),
    ])
    func textOperatorsIgnoreCase(op: Int, value: String, expected: Bool) throws {
        #expect(try matches(rule(condition("name", op, value)), track(title: "Night Drive")) == expected)
    }

    @Test func endsWithASpaceFindsTrailingSpaces() throws {
        let tidy = try rule(condition("artist", 11, " "))
        #expect(try matches(tidy, track(artist: "Artful Dodger ")))
        #expect(try !matches(tidy, track(artist: "Artful Dodger")))
    }

    @Test(arguments: [(1, "3", "", false), (3, "3", "", true), (4, "3", "", false), (5, "3", "5", true), (5, "5", "3", true), (2, "4", "", false)])
    func numberOperators(op: Int, left: String, right: String, expected: Bool) throws {
        #expect(try matches(rule(condition("rating", op, left, right)), track(rating: 4)) == expected)
    }

    @Test func emptyNumberMeansZero() throws {
        let neverPlayed = try rule(condition("counter", 1))
        #expect(try matches(neverPlayed, track(playCount: 0)))
        #expect(try !matches(neverPlayed, track(playCount: 3)))
    }

    @Test func inTheLast() throws {
        let now = try Date("2026-10-25T12:00:00Z", strategy: .iso8601)
        let new = try rule(condition("stockDate", 6, "30", unit: "day"))
        #expect(try matches(new, track(dateAdded: "2026-10-01"), now: now))
        #expect(try !matches(new, track(dateAdded: "2026-09-01"), now: now))
        #expect(try !matches(new, track(dateAdded: ""), now: now))

        let old = try rule(condition("stockDate", 7, "2", unit: "month"))
        #expect(try matches(old, track(dateAdded: "2026-07-01"), now: now))
        #expect(try !matches(old, track(dateAdded: "2026-10-01"), now: now))
    }

    @Test func allAndAny() throws {
        let houseAndRated = [condition("genre", 1, "House"), condition("rating", 3, "3")]
        let all = try rule(houseAndRated[0], houseAndRated[1], match: 1)
        let any = try rule(houseAndRated[0], houseAndRated[1], match: 2)
        let houseUnrated = track(genre: "House", rating: 0)
        #expect(try !matches(all, houseUnrated))
        #expect(try matches(any, houseUnrated))
    }

    @Test func myTags() throws {
        let tags = ["9001": "Regrid"]
        #expect(try matches(rule(condition("myTag", 8, "9001")), track(myTagIDs: ["9001"]), myTags: tags))
        #expect(try matches(rule(condition("myTag", 9, "9001")), track(myTagIDs: []), myTags: tags))
    }

    @Test func unknownMyTagIsUnsupported() throws {
        // Rekordbox 5 libraries can keep old tag IDs in their rules.
        #expect(throws: SmartRule.Unsupported.self) {
            try rule(condition("myTag", 8, "28")).predicate(myTags: ["9001": "Regrid"])
        }
    }

    @Test func unknownPropertyIsUnsupported() throws {
        #expect(throws: SmartRule.Unsupported.self) {
            try rule(condition("producer", 1, "x")).predicate(myTags: [:])
        }
    }

    @Test func unknownOperatorIsUnsupported() throws {
        #expect(throws: SmartRule.Unsupported.self) {
            try rule(condition("name", 99, "x")).predicate(myTags: [:])
        }
    }

    @Test func nestedGroupsAreUnsupported() throws {
        let nested = try #require(SmartRule(xml: #"<NODE LogicalOperator="1"><NODE LogicalOperator="2"/></NODE>"#))
        #expect(throws: SmartRule.Unsupported.self) { try nested.predicate(myTags: [:]) }
    }
}
