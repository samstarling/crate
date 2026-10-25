import Foundation
@testable import RekordboxKit
import Testing

@Suite("ID3 tags")
struct ID3TagTests {
    private func syncsafe(_ value: Int) -> [UInt8] {
        [UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)]
    }

    private func bigEndian(_ value: Int, bytes: Int = 4) -> [UInt8] {
        (0..<bytes).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) }
    }

    /// A v2.3 or v2.4 frame: ID, size, two flag bytes, then the content.
    private func frame(_ id: String, _ content: [UInt8], version: Int = 4, formatFlags: UInt8 = 0) -> [UInt8] {
        Array(id.utf8) + (version == 4 ? syncsafe(content.count) : bigEndian(content.count)) + [0, formatFlags] + content
    }

    private func textFrame(_ id: String, _ text: String, version: Int = 4) -> [UInt8] {
        frame(id, [3] + Array(text.utf8), version: version)
    }

    /// A whole tag: header, frames, then some padding.
    private func tag(version: Int = 4, flags: UInt8 = 0, _ frames: [[UInt8]], padding: Int = 16) -> [UInt8] {
        let body = frames.flatMap { $0 } + [UInt8](repeating: 0, count: padding)
        return Array("ID3".utf8) + [UInt8(version), 0, flags] + syncsafe(body.count) + body
    }

    private func parse(_ bytes: [UInt8]) throws -> ID3Tag {
        try #require(ID3Tag(data: Data(bytes)))
    }

    @Test func readsV24TextFramesWithSeveralValues() throws {
        let tag = try parse(tag([
            textFrame("TIT2", "Telephone"),
            textFrame("TCOM", "Beyoncé\0LaShawn Daniels\0Lady Gaga"),
        ]))
        #expect(tag.majorVersion == 4)
        #expect(tag.frames == [
            .init(id: "TIT2", value: .text(["Telephone"])),
            .init(id: "TCOM", value: .text(["Beyoncé", "LaShawn Daniels", "Lady Gaga"])),
        ])
    }

    @Test func readsV23FramesWithBigEndianSizes() throws {
        // 200 bytes, which would be a different number if read as syncsafe.
        let title = String(repeating: "a", count: 199)
        let tag = try parse(tag(version: 3, [textFrame("TIT2", title, version: 3), textFrame("TPE1", "Wham!", version: 3)]))
        #expect(tag.frames.map(\.value) == [.text([title]), .text(["Wham!"])])
    }

    @Test func readsTextEncodings() throws {
        let latin1: [UInt8] = [0] + Array("Beyonc".utf8) + [0xE9]
        let utf16WithBOM: [UInt8] = [1, 0xFF, 0xFE, 0x48, 0, 0x69, 0]
        let utf16BigEndian: [UInt8] = [2, 0, 0x48, 0, 0x69]
        let tag = try parse(tag([frame("TPE1", latin1), frame("TIT2", utf16WithBOM), frame("TALB", utf16BigEndian)]))
        #expect(tag.frames.map(\.value) == [.text(["Beyoncé"]), .text(["Hi"]), .text(["Hi"])])
    }

    @Test func readsDescribedFrames() throws {
        let tag = try parse(tag([
            frame("TXXX", [3] + Array("EnergyLevel\08".utf8)),
            frame("WXXX", [0] + Array("DISCOGS\0https://www.discogs.com".utf8)),
            frame("COMM", [0] + Array("eng".utf8) + [0] + Array("Fm".utf8)),
            frame("APIC", [0] + Array("image/png\0".utf8) + [3] + Array("Cover\0".utf8) + [1, 2, 3]),
            frame("GEOB", [0] + Array("application/octet-stream\0\0Serato Markers_\0".utf8) + [9, 9]),
            frame("PRIV", Array("PeakValue\0".utf8) + [0xAB]),
        ]))
        #expect(tag.frames == [
            .init(id: "TXXX", description: "EnergyLevel", value: .text(["8"])),
            .init(id: "WXXX", description: "DISCOGS", value: .text(["https://www.discogs.com"])),
            .init(id: "COMM", value: .text(["Fm"])),
            .init(id: "APIC", description: "Cover", value: .picture(Data([1, 2, 3]))),
            .init(id: "GEOB", description: "Serato Markers_", value: .binary(Data([9, 9]))),
            .init(id: "PRIV", description: "PeakValue", value: .binary(Data([0xAB]))),
        ])
    }

    @Test func readsV22Frames() throws {
        let content: [UInt8] = [0] + Array("Song 2".utf8)
        let frame = Array("TT2".utf8) + bigEndian(content.count, bytes: 3) + content
        let tag = try parse(tag(version: 2, [frame]))
        #expect(tag.frames == [.init(id: "TT2", value: .text(["Song 2"]))])
        #expect(tag.frames[0].canonicalID == "TIT2")
    }

    @Test func undoesUnsynchronisation() throws {
        // v2.3 unsynchronises the whole tag, including frame headers; v2.4 marks it per frame.
        let unsynchronised = frame("PRIV", Array("x\0".utf8) + [0xFF, 0xE0], version: 3).flatMap { $0 == 0xFF ? [0xFF, 0] : [$0] }
        let v23 = try parse(tag(version: 3, flags: 0x80, [unsynchronised]))
        #expect(v23.frames[0].value == .binary(Data([0xFF, 0xE0])))

        let v24 = try parse(tag([frame("PRIV", Array("x\0".utf8) + [0xFF, 0x00, 0xE0], formatFlags: 0x02)]))
        #expect(v24.frames[0].value == .binary(Data([0xFF, 0xE0])))
    }

    @Test func readsV24FramesWithBigEndianSizes() throws {
        // Old iTunes wrote v2.4 frame sizes as plain big-endian numbers.
        let title = String(repeating: "a", count: 199)
        let content = [3] + Array(title.utf8)
        let frames = Array("TIT2".utf8) + bigEndian(content.count) + [0, 0] + content + textFrame("TPE1", "Blur")
        let tag = try parse(tag([frames]))
        #expect(tag.frames.map(\.value) == [.text([title]), .text(["Blur"])])
    }

    @Test func keepsCompressedFramesAsBinary() throws {
        let tag = try parse(tag([frame("TIT2", [1, 2, 3], formatFlags: 0x08)]))
        #expect(tag.frames == [.init(id: "TIT2", value: .binary(Data([1, 2, 3])))])
    }

    @Test func skipsTheExtendedHeader() throws {
        let extendedHeader = syncsafe(6) + [1, 0]
        let tag = try parse(tag(flags: 0x40, [extendedHeader, textFrame("TIT2", "Kids")]))
        #expect(tag.frames == [.init(id: "TIT2", value: .text(["Kids"]))])
    }

    @Test func stopsAtATruncatedFrame() throws {
        var bytes = tag([textFrame("TIT2", "Kids"), textFrame("TPE1", "MGMT")], padding: 0)
        bytes.removeLast(2)
        #expect(try parse(bytes).frames == [.init(id: "TIT2", value: .text(["Kids"]))])
    }

    @Test func readsTagsFromMP3AIFFAndWAVFiles() throws {
        let id3 = tag([textFrame("TIT2", "Kids")])
        let audio = [UInt8](repeating: 0xAA, count: 7)
        // AIFF chunks have big-endian sizes and WAV chunks little-endian ones; odd-sized chunks are padded.
        func chunk(_ id: String, _ content: [UInt8], littleEndian: Bool) -> [UInt8] {
            let size = bigEndian(content.count)
            let padding: [UInt8] = content.count.isMultiple(of: 2) ? [] : [0]
            return Array(id.utf8) + (littleEndian ? size.reversed() : size) + content + padding
        }
        let aiff = chunk("FORM", Array("AIFF".utf8) + chunk("SSND", audio, littleEndian: false) + chunk("ID3 ", id3, littleEndian: false), littleEndian: false)
        let wav = chunk("RIFF", Array("WAVE".utf8) + chunk("data", audio, littleEndian: true) + chunk("id3 ", id3, littleEndian: true), littleEndian: true)

        for (bytes, ext) in [(id3 + audio, "mp3"), (aiff, "aiff"), (wav, "wav")] {
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
            try Data(bytes).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try ID3Tag.read(from: url)?.frames == [.init(id: "TIT2", value: .text(["Kids"]))], "\(ext)")
        }
    }

    @Test func id3v1GenresAreNumberedFromZero() {
        #expect(id3v1Genres.count == 192)
        #expect(id3v1Genres[0] == "Blues")
        #expect(id3v1Genres[13] == "Pop")
        #expect(id3v1Genres[35] == "House")
        #expect(id3v1Genres[79] == "Hard Rock")
        #expect(id3v1Genres[127] == "Drum & Bass")
        #expect(id3v1Genres[191] == "Psybient")
    }

    @Test func namesGenresInTCONValues() {
        #expect(ID3Tag.genres(fromTCON: "13") == ["Pop"])
        #expect(ID3Tag.genres(fromTCON: "(127)") == ["Drum & Bass"])
        #expect(ID3Tag.genres(fromTCON: "(13)(17)") == ["Pop", "Rock"])
        #expect(ID3Tag.genres(fromTCON: "(4)Eurodisco") == ["Disco", "Eurodisco"])
        #expect(ID3Tag.genres(fromTCON: "(RX)(CR)") == ["Remix", "Cover"])
        #expect(ID3Tag.genres(fromTCON: "((Bracketed)") == ["(Bracketed)"])
        #expect(ID3Tag.genres(fromTCON: "(999)") == ["(999)"])
        #expect(ID3Tag.genres(fromTCON: "999") == ["999"])
        #expect(ID3Tag.genres(fromTCON: "Deep House") == ["Deep House"])
        #expect(ID3Tag.genres(fromTCON: "") == [])
    }

    @Test(arguments: [false, true])
    func readsATagAppendedToTheEnd(followedByID3v1: Bool) throws {
        // An appended tag has a footer: "3DI", then the same fields as the header.
        var appended = tag(flags: 0x10, [textFrame("TIT2", "Kids")], padding: 0)
        appended += Array("3DI".utf8) + appended[3..<10]
        let id3v1 = followedByID3v1 ? Array("TAG".utf8) + [UInt8](repeating: 0, count: 125) : []
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp3")
        try Data([UInt8](repeating: 0xAA, count: 200) + appended + id3v1).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ID3Tag.read(from: url)?.frames == [.init(id: "TIT2", value: .text(["Kids"]))])
    }

    @Test func filesWithoutATagAreNil() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp3")
        try Data([0xFF, 0xFB, 0x90, 0x64] + [UInt8](repeating: 0, count: 100)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ID3Tag.read(from: url) == nil)
    }
}
