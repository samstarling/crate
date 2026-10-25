import Foundation

/// Changes applied to a library, with what's needed to revert them.
public struct AppliedChange: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    /// What was applied, for example "Remove “Night Drive”" or "3 changes".
    public let summary: String
    /// When several changes were applied together, a description of each.
    public let items: [String]
    /// The library folder the changes were applied to.
    public let libraryLocation: URL
    public let changes: ChangeSet
    /// Audio files moved to the Trash, so reverting can put them back.
    public let trashedFiles: [TrashedFile]
    /// When the changes were reverted, if they have been.
    public var revertedAt: Date?

    public var isReverted: Bool { revertedAt != nil }

    public init(
        summary: String,
        items: [String] = [],
        libraryLocation: URL,
        changes: ChangeSet,
        trashedFiles: [TrashedFile] = [],
        date: Date = .now,
        id: UUID = UUID()
    ) {
        self.id = id
        self.date = date
        self.summary = summary
        self.items = items
        self.libraryLocation = libraryLocation
        self.changes = changes
        self.trashedFiles = trashedFiles
    }
}

/// An audio file moved to the Trash, and where it went.
public struct TrashedFile: Hashable, Sendable {
    public let original: URL
    public let inTrash: URL

    public init(original: URL, inTrash: URL) {
        self.original = original
        self.inTrash = inTrash
    }
}
