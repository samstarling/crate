import Foundation

/// A saved edit to a library, so it can be reverted later, even after Crate has quit.
public struct JournalEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    /// What the edit did, for example "Remove “Night Drive”" or "3 changes".
    public let summary: String
    /// For an edit made of several changes, a description of each.
    public let items: [String]
    /// The library folder the edit was made to.
    public let libraryLocation: URL
    public let changes: ChangeSet
    /// Audio files the edit moved to the Trash, so reverting can put them back.
    public var trashedFiles: [TrashedFile]
    /// When the edit was reverted, if it has been.
    public var revertedAt: Date?

    public var isReverted: Bool { revertedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id, date, summary, items, libraryLocation, changes, trashedFiles, revertedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        summary = try container.decode(String.self, forKey: .summary)
        // Entries saved before edits could be batched have no items.
        items = try container.decodeIfPresent([String].self, forKey: .items) ?? []
        libraryLocation = try container.decode(URL.self, forKey: .libraryLocation)
        changes = try container.decode(ChangeSet.self, forKey: .changes)
        trashedFiles = try container.decode([TrashedFile].self, forKey: .trashedFiles)
        revertedAt = try container.decodeIfPresent(Date.self, forKey: .revertedAt)
    }

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
public struct TrashedFile: Codable, Hashable, Sendable {
    public let original: URL
    public let inTrash: URL

    public init(original: URL, inTrash: URL) {
        self.original = original
        self.inTrash = inTrash
    }
}

/// Saved edits, one JSON file each, in a directory.
public struct Journal: Sendable {
    public let directory: URL

    /// `~/Library/Application Support/Crate/Journal`.
    public static let defaultDirectory = URL.applicationSupportDirectory.appending(path: "Crate/Journal", directoryHint: .isDirectory)

    public init(directory: URL = Journal.defaultDirectory) {
        self.directory = directory
    }

    /// Saves an entry, replacing any earlier version of it.
    public func save(_ entry: JournalEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: directory.appending(path: "\(entry.id.uuidString).json"), options: .atomic)
    }

    /// The entries for the library at `location`, newest first. Files that can't be read are skipped.
    public func entries(forLibraryAt location: URL) -> [JournalEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(JournalEntry.self, from: Data(contentsOf: $0)) }
            .filter { $0.libraryLocation.standardizedFileURL.path == location.standardizedFileURL.path }
            .sorted { $0.date > $1.date }
    }
}
