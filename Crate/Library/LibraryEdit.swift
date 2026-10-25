import Foundation
import RekordboxKit

/// A change to the library, kept as an intention ("colour these tracks", "remove these tracks")
/// rather than as database rows, so that if the library changed before it could be saved, it can be
/// checked against the reloaded library and applied again.
enum LibraryEdit {
    case setColor(TrackColor?, trackIDs: [Track.ID])
    case remove([Track], movingFilesToTrash: Bool)

    /// The same edit against a reloaded library: tracks that are no longer in it are dropped, and
    /// everything else is looked up again. `nil` if nothing is left to change.
    func revalidated(against library: RekordboxLibrary) -> LibraryEdit? {
        switch self {
        case .setColor(let color, let ids):
            let ids = ids.filter { library.tracksByID[$0] != nil }
            guard !ids.isEmpty else { return nil }
            return .setColor(color.flatMap { color in library.colors.first { $0.id == color.id } }, trackIDs: ids)
        case .remove(let tracks, let movingFilesToTrash):
            let tracks = tracks.compactMap { library.tracksByID[$0.id] }
            guard !tracks.isEmpty else { return nil }
            return .remove(tracks, movingFilesToTrash: movingFilesToTrash)
        }
    }

    /// For example "Setting “Night Drive” to Wonky" or "Removing 3 tracks".
    var summary: String {
        switch self {
        case .setColor(let color, let ids):
            let tracks = ids.count == 1 ? "a track" : "\(ids.count) tracks"
            return color.map { "Setting \(tracks) to \($0.name)" } ?? "Clearing the colour of \(tracks)"
        case .remove(let tracks, _):
            return tracks.count == 1 ? "Removing \u{201C}\(tracks[0].title)\u{201D}" : "Removing \(tracks.count) tracks"
        }
    }
}
