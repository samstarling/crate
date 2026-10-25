import Foundation

/// A track's colour waveform, as Rekordbox draws it: the `PWV5` tag of its `ANLZ0000.EXT` analysis
/// file, with ~150 entries per second.
///
/// Each entry is a big-endian `UInt16`: 3 bits each of red, green and blue, then a 5-bit height
/// (see https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html).
nonisolated struct Waveform: Sendable {
    struct Column {
        /// 0–1.
        var height: Double
        /// Each 0–1.
        var red: Double
        var green: Double
        var blue: Double
    }

    let entries: [UInt16]

    /// Reads the colour waveform from an analysis file, or returns `nil` if it doesn't have one.
    static func load(from url: URL) throws -> Waveform? {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        func uint32(at offset: Int) -> Int {
            bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }

        // The file is a "PMAI" header followed by tagged sections: fourcc, header length, total length.
        guard bytes.count >= 12, bytes.starts(with: Array("PMAI".utf8)) else { return nil }
        var position = uint32(at: 4)
        while position + 12 <= bytes.count {
            let headerLength = uint32(at: position + 4)
            let tagLength = uint32(at: position + 8)
            guard tagLength > 0, position + tagLength <= bytes.count, headerLength <= tagLength else { return nil }

            if bytes[position..<position + 4].elementsEqual("PWV5".utf8) {
                let body = bytes[(position + headerLength)..<(position + tagLength)]
                let entries = stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map {
                    UInt16(body[$0]) << 8 | UInt16(body[$0 + 1])
                }
                return Waveform(entries: entries)
            }
            position += tagLength
        }
        return nil
    }

    /// Entries per second of audio.
    static let entriesPerSecond = 150

    /// Downsamples to `count` columns for an overview.
    ///
    /// Each column averages the entries within at least `minimumWindow` seconds around it: height
    /// is the mean loudness (scaled so the loudest column is full height) and colour the
    /// loudness-weighted mean colour. Averaging over about a beat keeps the overview from striping
    /// when columns are narrower than a beat, which they usually are; otherwise columns alternate
    /// between landing on and between kick drums.
    func columns(_ count: Int, minimumWindow: Double = 0.67) -> [Column] {
        guard count > 0, !entries.isEmpty else { return [] }
        let perColumn = Double(entries.count) / Double(count)
        let padding = Int(max(0, (minimumWindow * Double(Self.entriesPerSecond) - perColumn) / 2))

        var columns = (0..<count).map { index in
            let start = Int(Double(index) * perColumn)
            let end = max(start + 1, Int(Double(index + 1) * perColumn))
            let window = entries[max(0, start - padding)..<min(entries.count, end + padding)]

            var total = 0, red = 0, green = 0, blue = 0
            for entry in window {
                let height = Int(entry >> 2 & 0x1F)
                total += height
                red += Int(entry >> 13 & 0x7) * height
                green += Int(entry >> 10 & 0x7) * height
                blue += Int(entry >> 7 & 0x7) * height
            }
            let colorScale = total > 0 ? 1 / (7 * Double(total)) : 0
            return Column(
                height: Double(total) / Double(max(window.count, 1)),
                red: Double(red) * colorScale,
                green: Double(green) * colorScale,
                blue: Double(blue) * colorScale
            )
        }

        let loudest = columns.map(\.height).max() ?? 0
        if loudest > 0 {
            for index in columns.indices {
                columns[index].height /= loudest
            }
        }
        return columns
    }
}
