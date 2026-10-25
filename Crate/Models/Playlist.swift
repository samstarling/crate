import Foundation

nonisolated struct Playlist: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case playlist, folder, smart
    }

    let id: String
    let name: String
    let kind: Kind
    /// `nil` for anything that isn't a folder, so `List(children:)` doesn't draw a disclosure triangle.
    var children: [Playlist]?
    var trackIDs: [String]
    /// The rules for a smart playlist; `nil` otherwise, or if they couldn't be read.
    var smartRule: SmartRule? = nil

    var systemImage: String {
        switch kind {
        case .playlist: "music.note.list"
        case .folder: "folder"
        case .smart: "gearshape"
        }
    }
}
