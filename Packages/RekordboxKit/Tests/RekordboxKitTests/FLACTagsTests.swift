import Foundation
@testable import RekordboxKit
import Testing

@Suite("FLAC tags")
struct FLACTagsTests {
    private func bigEndian(_ value: Int, bytes: Int = 4) -> [UInt8] {
        (0..<bytes).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) }
    }

    private func littleEndian(_ value: Int) -> [UInt8] {
        bigEndian(value).reversed()
    }

    private func block(_ type: UInt8, _ content: [UInt8], isLast: Bool = false) -> [UInt8] {
        [type | (isLast ? 0x80 : 0)] + bigEndian(content.count, bytes: 3) + content
    }

    private func vorbisComments(vendor: String, _ comments: [String]) -> [UInt8] {
        let strings = comments.flatMap { littleEndian($0.utf8.count) + Array($0.utf8) }
        return littleEndian(vendor.utf8.count) + Array(vendor.utf8) + littleEndian(comments.count) + strings
    }

    private func picture(description: String, data: [UInt8]) -> [UInt8] {
        let mimeType = Array("image/png".utf8)
        let description = Array(description.utf8)
        let header = bigEndian(3) + bigEndian(mimeType.count) + mimeType + bigEndian(description.count) + description
        return header + [UInt8](repeating: 0, count: 16) + bigEndian(data.count) + data
    }

    private func read(_ bytes: [UInt8]) throws -> FLACTags? {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).flac")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try FLACTags.read(from: url)
    }

    @Test func readsCommentsAndPictures() throws {
        let streamInfo = block(0, [UInt8](repeating: 0, count: 34))
        let comments = block(4, vorbisComments(vendor: "reference libFLAC 1.4.3", ["title=Kids", "ARTIST=MGMT", "Artist=Someone Else", "EMPTY="]))
        let cover = block(6, picture(description: "Cover", data: [1, 2, 3]), isLast: true)
        let tags = try #require(try read(Array("fLaC".utf8) + streamInfo + comments + cover + [0xFF, 0xF8]))

        #expect(tags.vendor == "reference libFLAC 1.4.3")
        #expect(tags.tags == [
            .init(key: "TITLE", value: .text(["Kids"])),
            .init(key: "ARTIST", value: .text(["MGMT"])),
            .init(key: "ARTIST", value: .text(["Someone Else"])),
            .init(key: "EMPTY", value: .text([""])),
            .init(key: "PICTURE", description: "Cover", value: .picture(Data([1, 2, 3]))),
        ])
    }

    @Test func skipsAnID3TagBeforeTheFLACData() throws {
        let id3: [UInt8] = Array("ID3".utf8) + [4, 0, 0, 0, 0, 0, 4] + [0, 0, 0, 0]
        let comments = block(4, vorbisComments(vendor: "", ["TITLE=Kids"]), isLast: true)
        let tags = try #require(try read(id3 + Array("fLaC".utf8) + comments))
        #expect(tags.tags == [.init(key: "TITLE", value: .text(["Kids"]))])
    }

    @Test func stopsAtATruncatedBlock() throws {
        let comments = block(4, vorbisComments(vendor: "", ["TITLE=Kids"]))
        let tags = try #require(try read(Array("fLaC".utf8) + comments + block(6, [1, 2, 3]).dropLast()))
        #expect(tags.tags == [.init(key: "TITLE", value: .text(["Kids"]))])
    }

    @Test func otherFilesAreNil() throws {
        #expect(try read(Array("ID3".utf8) + [UInt8](repeating: 0, count: 20)) == nil)
        #expect(try read(Array("RIFF".utf8)) == nil)
    }
}
