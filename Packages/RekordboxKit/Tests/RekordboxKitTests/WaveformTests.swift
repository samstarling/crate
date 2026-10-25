import Foundation
@testable import RekordboxKit
import Testing

@Suite("Colour waveforms")
struct WaveformTests {
    /// Packs an entry the way PWV5 does: 3 bits each of red, green and blue, then a 5-bit height.
    private func entry(red: UInt16, green: UInt16, blue: UInt16, height: UInt16) -> UInt16 {
        red << 13 | green << 10 | blue << 7 | height << 2
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    /// A tagged section: fourcc, header length, total length, any extra header bytes, then the body.
    private func tag(_ fourcc: String, header: [UInt8] = [], body: [UInt8]) -> [UInt8] {
        let headerLength = 12 + header.count
        return Array(fourcc.utf8) + bigEndian(UInt32(headerLength)) + bigEndian(UInt32(headerLength + body.count)) + header + body
    }

    /// An analysis file containing the given tags.
    private func analysisFile(_ tags: [[UInt8]]) throws -> URL {
        let body = tags.flatMap { $0 }
        let header = Array("PMAI".utf8) + bigEndian(28) + bigEndian(UInt32(28 + body.count)) + [UInt8](repeating: 0, count: 16)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).EXT")
        try Data(header + body).write(to: url)
        return url
    }

    @Test func readsPWV5AfterOtherTags() throws {
        let entries = [entry(red: 7, green: 0, blue: 0, height: 31), entry(red: 0, green: 0, blue: 7, height: 10)]
        let pwv5 = tag("PWV5", header: bigEndian(2) + bigEndian(UInt32(entries.count)) + bigEndian(0),
                       body: entries.flatMap { withUnsafeBytes(of: $0.bigEndian, Array.init) })
        let url = try analysisFile([tag("PPTH", body: [0, 0, 0, 0]), pwv5])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try Waveform.load(from: url)?.entries == entries)
    }

    @Test func fileWithoutAColourWaveformIsNil() throws {
        let url = try analysisFile([tag("PPTH", body: [0, 0, 0, 0])])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Waveform.load(from: url) == nil)
    }

    @Test func otherFilesAreNil() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).EXT")
        try Data("not an analysis file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Waveform.load(from: url) == nil)
    }

    @Test func columnsAreScaledToTheLoudestColumn() {
        // One second of loud red, then one second of quieter blue.
        let loud = [UInt16](repeating: entry(red: 7, green: 0, blue: 0, height: 30), count: Waveform.entriesPerSecond)
        let quiet = [UInt16](repeating: entry(red: 0, green: 0, blue: 7, height: 10), count: Waveform.entriesPerSecond)
        let columns = Waveform(entries: loud + quiet).columns(2, minimumWindow: 0)

        #expect(columns.count == 2)
        #expect(columns[0].height == 1)
        #expect(abs(columns[1].height - 1.0 / 3) < 0.001)
        #expect(columns[0].red == 1 && columns[0].blue == 0)
        #expect(columns[1].blue == 1 && columns[1].red == 0)
    }

    @Test func emptyWaveformHasNoColumns() {
        #expect(Waveform(entries: []).columns(100).isEmpty)
        #expect(Waveform(entries: [1, 2, 3]).columns(0).isEmpty)
    }
}
