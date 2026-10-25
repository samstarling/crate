import RekordboxKit
import SwiftUI

// Sample data for SwiftUI previews, so they never touch a real Rekordbox library.
// (Not wrapped in #if DEBUG: #Preview blocks are compiled in release builds too.)

extension TrackColor {
    static let previews: [TrackColor] = [
        "Rhythmic", "Intense", "Moody", "Yellow", "Melodic", "Chuggy", "Breaksy", "Wonky",
    ].enumerated().map { TrackColor(id: $0 + 1, name: $1) }
}

extension Track {
    static let previews: [Track] = [
        ("Night Drive", "Halcyon Static", "Afterhours", "House", "Lowlight", "Am", 122.0, 384, 4, 2024, 5, [0.0, 31.5, 94.4, 157.4]),
        ("Copper Sun", "Mara Vey", "Copper Sun EP", "Deep House", "Fieldwork", "F#m", 120, 412, 5, 2023, 1, [0, 64, 192]),
        ("Pressure Drop", "Kites & Wires", "Pressure", "Breaks", "Rough Edges", "Dm", 132.5, 298, 3, 2022, 7, [0, 29, 87]),
        ("Glasshouse", "Ottoline", "Glasshouse", "Techno", "Monochrome", "Gm", 128, 455, 0, 2025, nil, []),
        ("Soft Machines", "Halcyon Static", "Afterhours", "House", "Lowlight", "C", 124, 361, 2, 2024, 3, [0]),
        ("Unmastered Demo", "Unknown Artist", "", "", "", "", 0, 187, 0, 0, nil, []),
    ].enumerated().map { index, track in
        let (title, artist, album, genre, label, key, bpm, duration, rating, year, colorID, cues) = track
        return Track(
            id: "preview-\(index)",
            libraryIndex: index,
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            label: label,
            key: key,
            bpm: bpm,
            duration: duration,
            rating: rating,
            year: year,
            dateAdded: "2026-0\(index + 1)-1\(index)",
            playCount: index * 3,
            color: colorID.map { TrackColor.previews[$0 - 1] },
            comment: "",
            fileURL: URL(filePath: "/Music/\(artist)/\(title).mp3"),
            artworkURL: nil,
            analysisURL: nil,
            memoryCues: cues,
            myTagIDs: []
        )
    }
}

extension RekordboxLibrary {
    static let preview: RekordboxLibrary = {
        let ids = Track.previews.map(\.id)
        let playlists = [
            Playlist(id: "digging", name: "Crate Digging", kind: .playlist, children: nil, trackIDs: ids),
            Playlist(id: "sets", name: "Sets", kind: .folder, children: [
                Playlist(id: "warm-up", name: "Warm-up", kind: .playlist, children: nil, trackIDs: [ids[1], ids[4], ids[0]]),
                Playlist(id: "peak", name: "Peak Time", kind: .playlist, children: nil, trackIDs: [ids[3], ids[2]]),
            ], trackIDs: []),
            Playlist(id: "smart", name: "Smart", kind: .folder, children: [
                Playlist(
                    id: "unrated", name: "Unrated", kind: .smart, children: nil, trackIDs: [],
                    smartRule: SmartRule(xml: #"<NODE LogicalOperator="1"><CONDITION PropertyName="rating" Operator="1" ValueUnit="" ValueLeft="0" ValueRight=""/></NODE>"#)
                ),
                Playlist(
                    id: "old-tag", name: "Old Tag", kind: .smart, children: nil, trackIDs: [],
                    smartRule: SmartRule(xml: #"<NODE LogicalOperator="1"><CONDITION PropertyName="myTag" Operator="8" ValueUnit="" ValueLeft="28" ValueRight=""/></NODE>"#)
                ),
            ], trackIDs: []),
        ]
        return RekordboxLibrary(
            location: URL(filePath: "/Preview/rekordbox", directoryHint: .isDirectory),
            tracks: Track.previews,
            playlists: playlists,
            colors: TrackColor.previews
        )
    }()
}

extension Waveform {
    /// A made-up waveform with an intro, two drops, a breakdown and an outro.
    static func preview(duration: Int, bpm: Double) -> Waveform {
        let count = duration * entriesPerSecond
        let entriesPerBeat = Double(entriesPerSecond) * 60 / bpm
        let entries = (0..<count).map { index -> UInt16 in
            let progress = Double(index) / Double(count)
            let energy: Double = switch progress {
            case ..<0.08: 0.3
            case ..<0.4: 0.95
            case ..<0.55: 0.45
            case ..<0.9: 1
            default: 0.35
            }
            let beatPhase = Double(index).truncatingRemainder(dividingBy: entriesPerBeat) / entriesPerBeat
            let kick = beatPhase < 0.2
            let height = UInt16(min(31, (kick ? 31 : 18) * energy))
            // Kicks read red (bass), the rest blue (highs).
            let (red, green, blue): (UInt16, UInt16, UInt16) = kick ? (7, 2, 3) : (2, 4, 7)
            return red << 13 | green << 10 | blue << 7 | height << 2
        }
        return Waveform(entries: entries)
    }
}

/// Supplies a sample library and a paused player: `#Preview(traits: .sampleData)`.
struct SampleData: PreviewModifier {
    static func makeSharedContext() async throws -> (LibraryModel, PlayerModel) {
        let track = Track.previews[0]
        let player = PlayerModel.preview(track, waveform: .preview(duration: track.duration, bpm: track.bpm), at: 74)
        return (LibraryModel(library: .preview), player)
    }

    func body(content: Content, context: (LibraryModel, PlayerModel)) -> some View {
        content
            .environment(context.0)
            .environment(context.1)
    }
}

extension PreviewTrait where T == Preview.ViewTraits {
    @MainActor static var sampleData: Self = .modifier(SampleData())
}
