import Foundation

public struct Playlist: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable {
        case playlist, folder, smart
    }

    public let id: String
    public let name: String
    public let kind: Kind
    /// `nil` for anything that isn't a folder, so `List(children:)` doesn't draw a disclosure triangle.
    public var children: [Playlist]?
    public var trackIDs: [String]
    /// The rules for a smart playlist; `nil` otherwise, or if they couldn't be read.
    public var smartRule: SmartRule?

    public init(id: String, name: String, kind: Kind, children: [Playlist]? = nil, trackIDs: [String] = [], smartRule: SmartRule? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.children = children
        self.trackIDs = trackIDs
        self.smartRule = smartRule
    }
}
