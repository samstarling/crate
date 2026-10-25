import Foundation
@testable import RekordboxKit
import Testing

@Suite("ID3v1 tags")
struct ID3v1TagTests {
    /// A Latin-1 field padded with zeroes to its fixed length.
    private func field(_ text: String, length: Int) -> [UInt8] {
        let bytes = [UInt8](text.data(using: .isoLatin1)!)
        return bytes + [UInt8](repeating: 0, count: length - bytes.count)
    }

    private func tag(comment: [UInt8], genre: UInt8) -> [UInt8] {
        Array("TAG".utf8) + field("Song 2", length: 30) + field("Blur", length: 30) + field("Blur", length: 30)
            + field("1997", length: 4) + comment + [genre]
    }

    @Test func readsID3v1() throws {
        let tag = try #require(ID3v1Tag(bytes: tag(comment: field("Woo hoo  ", length: 30), genre: 17)))
        #expect(tag == ID3v1Tag(title: "Song 2", artist: "Blur", album: "Blur", year: "1997", comment: "Woo hoo", track: nil, genre: 17))
    }

    @Test func readsTheTrackNumberFromID3v1Point1() throws {
        let tag = try #require(ID3v1Tag(bytes: tag(comment: field("Café", length: 28) + [0, 2], genre: 255)))
        #expect(tag.comment == "Café")
        #expect(tag.track == 2)
        #expect(tag.genre == nil)
    }

    @Test func readsFromTheEndOfAFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp3")
        try Data([UInt8](repeating: 0xAA, count: 500) + tag(comment: field("", length: 30), genre: 0)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ID3v1Tag.read(from: url)?.title == "Song 2")
    }

    @Test func otherBytesAreNil() throws {
        #expect(ID3v1Tag(bytes: [UInt8](repeating: 0, count: 128)) == nil)
        #expect(ID3v1Tag(bytes: Array("TAG".utf8)) == nil)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp3")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ID3v1Tag.read(from: url) == nil)
    }
}
