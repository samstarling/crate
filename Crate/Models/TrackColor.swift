import SwiftUI

/// Rekordbox's eight fixed track colours. Their display names can be customised, so we keep the label too.
nonisolated struct TrackColor: Hashable, Sendable {
    let id: Int
    let name: String

    var color: Color {
        switch id {
        case 1: .pink
        case 2: .red
        case 3: .orange
        case 4: .yellow
        case 5: .green
        case 6: .cyan
        case 7: .blue
        default: .purple
        }
    }
}
