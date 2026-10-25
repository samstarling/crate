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
    /// The changes as the user made them, so they can be applied again after being reverted.
    public let pendingChanges: [PendingChange]
    /// What applying them changed in the library, so it can be reverted.
    public var changes: ChangeSet
    /// Audio files moved to the Trash, so reverting can put them back.
    public var trashedFiles: [TrashedFile]
    /// When the changes were reverted, if they have been.
    public var revertedAt: Date?

    public var isReverted: Bool { revertedAt != nil }

    public init(
        summary: String,
        items: [String] = [],
        libraryLocation: URL,
        pendingChanges: [PendingChange],
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
        self.pendingChanges = pendingChanges
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
