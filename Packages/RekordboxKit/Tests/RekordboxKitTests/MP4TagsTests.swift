import Foundation
@testable import RekordboxKit
import Testing

@Suite("MP4 tags")
struct MP4TagsTests {
    private func bigEndian(_ value: Int, bytes: Int = 4) -> [UInt8] {
        (0..<bytes).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) }
    }

    private func atom(_ type: String, _ content: [UInt8]) -> [UInt8] {
        bigEndian(8 + content.count) + Array(type.data(using: .isoLatin1)!) + content
    }

    /// A `data` atom: version, type, locale, then the value.
    private func data(type: Int, _ payload: [UInt8]) -> [UInt8] {
        atom("data", bigEndian(type) + [0, 0, 0, 0] + payload)
    }

    private func text(_ string: String) -> [UInt8] {
        data(type: 1, Array(string.utf8))
    }

    /// A file with an `ftyp` atom, then the given items in `moov/udta/meta/ilst`, optionally after the audio.
    private func file(_ items: [[UInt8]], moovAfterAudio: Bool = false) -> [UInt8] {
        let handler = atom("hdlr", [UInt8](repeating: 0, count: 25))
        let meta = atom("meta", [0, 0, 0, 0] + handler + atom("ilst", items.flatMap { $0 }))
        let moov = atom("moov", atom("mvhd", [0, 0, 0, 0]) + atom("udta", meta))
        let ftyp = atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0])
        let mdat = atom("mdat", [UInt8](repeating: 0xAA, count: 100))
        return ftyp + (moovAfterAudio ? mdat + moov : moov + mdat)
    }

    private func read(_ bytes: [UInt8]) throws -> MP4Tags? {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try MP4Tags.read(from: url)
    }

    @Test(arguments: [false, true])
    func readsTags(moovAfterAudio: Bool) throws {
        let tags = try #require(try read(file([
            atom("©nam", text("Your Song")),
            atom("trkn", data(type: 0, [0, 0, 0, 1, 0, 10, 0, 0])),
            atom("disk", data(type: 0, [0, 0, 0, 1, 0, 0])),
            atom("gnre", data(type: 0, [0, 14])),
            atom("tmpo", data(type: 21, [0, 128])),
            atom("rtng", data(type: 21, [0xFF])),
            atom("covr", data(type: 14, [1, 2, 3]) + data(type: 13, [4, 5])),
            atom("----", atom("mean", [0, 0, 0, 0] + Array("com.apple.iTunes".utf8)) + atom("name", [0, 0, 0, 0] + Array("initialkey".utf8)) + text("Eb")),
            atom("----", atom("mean", [0, 0, 0, 0] + Array("org.example".utf8)) + atom("name", [0, 0, 0, 0] + Array("Mood".utf8)) + text("Happy")),
            atom("xid ", data(type: 0, [9, 9])),
        ], moovAfterAudio: moovAfterAudio)))

        #expect(tags.tags == [
            .init(key: "©nam", value: .text(["Your Song"])),
            .init(key: "trkn", value: .text(["1/10"])),
            .init(key: "disk", value: .text(["1"])),
            .init(key: "gnre", value: .text(["14"])),
            .init(key: "tmpo", value: .text(["128"])),
            .init(key: "rtng", value: .text(["-1"])),
            .init(key: "covr", value: .picture(Data([1, 2, 3]))),
            .init(key: "covr", value: .picture(Data([4, 5]))),
            .init(key: "----", description: "initialkey", value: .text(["Eb"])),
            .init(key: "----", description: "org.example:Mood", value: .text(["Happy"])),
            .init(key: "xid ", value: .binary(Data([9, 9]))),
        ])
    }

    @Test func readsMetaWithoutAVersion() throws {
        // QuickTime-style `meta` atoms start straight away with their `hdlr` child.
        let meta = atom("meta", atom("hdlr", [UInt8](repeating: 0, count: 25)) + atom("ilst", atom("©nam", text("Kids"))))
        let bytes = atom("ftyp", Array("M4A ".utf8)) + atom("moov", atom("udta", meta))
        #expect(try read(bytes)?.tags == [.init(key: "©nam", value: .text(["Kids"]))])
    }

    @Test func fileWithoutTagsIsEmpty() throws {
        let bytes = atom("ftyp", Array("M4A ".utf8)) + atom("moov", atom("mvhd", [0, 0, 0, 0]))
        #expect(try read(bytes)?.tags == [])
    }

    @Test func corruptAtomSizesDontCrash() throws {
        // A top-level atom with a 64-bit size too big for `Int`.
        let huge = bigEndian(1) + Array("free".utf8) + [UInt8](repeating: 0xFF, count: 8)
        #expect(try read(atom("ftyp", Array("M4A ".utf8)) + huge)?.tags == [])
    }

    @Test func otherFilesAreNil() throws {
        #expect(try read(Array("fLaC".utf8) + [UInt8](repeating: 0, count: 20)) == nil)
    }
}
