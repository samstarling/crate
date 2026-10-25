import RekordboxKit
import SwiftUI

extension TrackColor {
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

extension Playlist {
    var systemImage: String {
        switch kind {
        case .playlist: "music.note.list"
        case .folder: "folder"
        case .smart: "gearshape"
        }
    }
}
