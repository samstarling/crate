import Foundation

/// Rekordbox's eight fixed track colours. Their display names can be customised, so we keep the label too.
public struct TrackColor: Hashable, Sendable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}
