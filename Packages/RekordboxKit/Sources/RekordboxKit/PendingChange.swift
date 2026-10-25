import Foundation

/// A change to a library that hasn't been written to `master.db` yet.
///
/// Changes are kept as intentions ("remove these tracks") rather than database rows, so they can be
/// shown in memory straight away, checked against a reloaded library, and written together when
/// the user applies them.
public enum PendingChange: Hashable, Sendable {
    /// Sets the colour of tracks, by colour ID (`nil` for none).
    case setColor(colorID: Int?, trackIDs: [Track.ID])
    /// Removes tracks from the collection, moving their audio files to the Trash when applied if asked.
    case remove(trackIDs: [Track.ID], movingFilesToTrash: Bool)

    public var trackIDs: [Track.ID] {
        switch self {
        case .setColor(_, let ids), .remove(let ids, _): ids
        }
    }

    /// The same change against a reloaded library: tracks that are no longer in it are dropped.
    /// `nil` if none are left.
    public func revalidated(against library: RekordboxLibrary) -> PendingChange? {
        let ids = trackIDs.filter { library.tracksByID[$0] != nil }
        guard !ids.isEmpty else { return nil }
        switch self {
        case .setColor(let colorID, _): return .setColor(colorID: colorID, trackIDs: ids)
        case .remove(_, let movingFilesToTrash): return .remove(trackIDs: ids, movingFilesToTrash: movingFilesToTrash)
        }
    }

    /// For example "Set “Night Drive” to Wonky" or "Remove 3 tracks".
    public func summary(in library: RekordboxLibrary) -> String {
        let tracks = trackIDs.count == 1
            ? library.tracksByID[trackIDs[0]].map { "\u{201C}\($0.title)\u{201D}" } ?? "a track"
            : "\(trackIDs.count) tracks"
        switch self {
        case .setColor(let colorID, _):
            guard let color = library.colors.first(where: { $0.id == colorID }) else { return "Clear the colour of \(tracks)" }
            return "Set \(tracks) to \(color.name)"
        case .remove(_, let movingFilesToTrash):
            return "Remove \(tracks)" + (movingFilesToTrash ? " and move \(trackIDs.count == 1 ? "its file" : "their files") to the Trash" : "")
        }
    }
}

/// A pending change as the user made it.
public struct StagedChange: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    public private(set) var change: PendingChange
    /// Written when the change was made, so it still reads sensibly if the tracks change later.
    public private(set) var summary: String

    public init(_ change: PendingChange, summary: String, date: Date = .now, id: UUID = UUID()) {
        self.id = id
        self.date = date
        self.change = change
        self.summary = summary
    }

    /// The same change against a reloaded library (see `PendingChange.revalidated(against:)`),
    /// described afresh if any of its tracks have gone.
    public func revalidated(against library: RekordboxLibrary) -> StagedChange? {
        guard let revalidated = change.revalidated(against: library) else { return nil }
        guard revalidated != change else { return self }
        var staged = self
        staged.change = revalidated
        staged.summary = revalidated.summary(in: library)
        return staged
    }
}

extension RekordboxLibrary {
    /// This library with `changes` made in memory, as it will be once they're applied.
    ///
    /// The whole batch is replayed in one pass: colours are set, removals are collected, and the
    /// library is rebuilt (renumbering tracks and re-sorting) at most once, however many changes
    /// there are.
    public func applying(_ changes: [PendingChange]) -> RekordboxLibrary {
        guard !changes.isEmpty else { return self }
        var library = self
        var recoloured = Set<Track.ID>()
        var removed = Set<Track.ID>()
        for change in changes {
            switch change {
            case .setColor(let colorID, let ids):
                let color = colors.first { $0.id == colorID }
                for id in ids {
                    guard let index = tracksByID[id]?.libraryIndex else { continue }
                    library.tracks[index].color = color
                    recoloured.insert(id)
                }
            case .remove(let ids, _):
                removed.formUnion(ids)
            }
        }

        guard !removed.isEmpty else {
            // Only colours changed, so only the colour ranks need recomputing.
            for id in recoloured {
                if let index = tracksByID[id]?.libraryIndex {
                    library.tracksByID[id] = library.tracks[index]
                }
            }
            library.sortRanks[\Track.colorSortKey] = Self.ranks(library.tracks, \.colorSortKey, by: <)
            return library
        }

        // Tracks are indexed by position, which changes for every track after a removed one.
        var remaining = library.tracks.filter { !removed.contains($0.id) }
        for index in remaining.indices {
            remaining[index].libraryIndex = index
        }
        return RekordboxLibrary(
            location: location,
            tracks: remaining,
            playlists: playlists.map { $0.removingTracks(removed) },
            colors: colors,
            myTags: myTags,
            updateCount: updateCount
        )
    }
}

extension Playlist {
    func removingTracks(_ ids: Set<Track.ID>) -> Playlist {
        var playlist = self
        playlist.trackIDs.removeAll(where: ids.contains)
        playlist.children = children?.map { $0.removingTracks(ids) }
        return playlist
    }
}
