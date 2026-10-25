import CryptoKit
import Foundation
import Synchronization

/// What a `LibrarySession` does to files besides `master.db`: backing the library up before
/// changing it, and moving audio files to the Trash and back.
///
/// Passed in so tests and previews can use a temporary folder, or do nothing, instead of the real
/// backups folder and the user's Trash.
public struct FileOperations: Sendable {
    /// Backs up the library in a folder, before the first change to it.
    public var backUp: @Sendable (_ library: URL) throws -> Void
    /// Moves files to the Trash, returning where each went and the names of any that couldn't be moved.
    public var moveToTrash: @Sendable (_ files: [URL]) -> (trashed: [TrashedFile], failures: [String])
    /// Moves files back from the Trash, returning the names of any that couldn't be.
    public var restoreFromTrash: @Sendable (_ files: [TrashedFile]) -> [String]

    public init(
        backUp: @escaping @Sendable (URL) throws -> Void,
        moveToTrash: @escaping @Sendable ([URL]) -> (trashed: [TrashedFile], failures: [String]),
        restoreFromTrash: @escaping @Sendable ([TrashedFile]) -> [String]
    ) {
        self.backUp = backUp
        self.moveToTrash = moveToTrash
        self.restoreFromTrash = restoreFromTrash
    }

    /// `~/Library/Application Support/Crate/Backups`.
    public static let defaultBackupsDirectory = URL.applicationSupportDirectory.appending(path: "Crate/Backups", directoryHint: .isDirectory)

    /// Backs up into `backupsDirectory` and uses the user's Trash.
    ///
    /// Each library is backed up once, however many times it's opened: every session using these
    /// operations shares the record of what's been backed up.
    public static func live(backupsDirectory: URL = defaultBackupsDirectory, backupsToKeep: Int = 10) -> FileOperations {
        let backedUp = Mutex(Set<String>())
        return FileOperations(
            backUp: { library in
                let path = library.standardizedFileURL.path
                guard backedUp.withLock({ $0.insert(path).inserted }) else { return }
                do {
                    try backUp(library, into: backupsDirectory, keeping: backupsToKeep)
                } catch {
                    backedUp.withLock { _ = $0.remove(path) }
                    throw error
                }
            },
            moveToTrash: { files in
                moveFiles(files) { file in
                    var inTrash: NSURL?
                    try FileManager.default.trashItem(at: file, resultingItemURL: &inTrash)
                    return inTrash as URL?
                }
            },
            restoreFromTrash: { restore($0) }
        )
    }

    /// Does nothing, for previews.
    public static let none = FileOperations(backUp: { _ in }, moveToTrash: { _ in ([], []) }, restoreFromTrash: { _ in [] })

    /// Copies `master.db` (and any WAL files) to `<backups>/<library>/<time>/`, keeping each library's
    /// first backup (from before Crate changed anything) and its `count` most recent ones.
    static func backUp(_ library: URL, into backups: URL, keeping count: Int) throws {
        let fileManager = FileManager.default
        let digest = SHA256.hash(data: Data(library.standardizedFileURL.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let folder = backups.appending(path: digest, directoryHint: .isDirectory)
        let timestamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeSeparator(.omitted))
        var destination = folder.appending(path: timestamp, directoryHint: .isDirectory)
        var attempt = 1
        while fileManager.fileExists(atPath: destination.path) {
            attempt += 1
            destination = folder.appending(path: "\(timestamp)-\(attempt)", directoryHint: .isDirectory)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["master.db", "master.db-wal", "master.db-shm"] {
            let file = library.appending(path: name)
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.copyItem(at: file, to: destination.appending(path: name))
            }
        }

        // Backup folders are named by time, so they sort oldest first.
        let existing = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let sorted = existing.filter(\.hasDirectoryPath).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in sorted.dropFirst().dropLast(count) {
            try? fileManager.removeItem(at: old)
        }
    }

    /// Moves each file that exists with `move`, which returns where it went.
    static func moveFiles(_ files: [URL], with move: (URL) throws -> URL?) -> (trashed: [TrashedFile], failures: [String]) {
        var trashed: [TrashedFile] = []
        var failures: [String] = []
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            do {
                if let inTrash = try move(file) {
                    trashed.append(TrashedFile(original: file, inTrash: inTrash))
                }
            } catch {
                failures.append(file.lastPathComponent)
            }
        }
        return (trashed, failures)
    }

    /// Moves files back to where they were, unless something is there already.
    static func restore(_ files: [TrashedFile]) -> [String] {
        files.compactMap { file in
            let fileManager = FileManager.default
            guard !fileManager.fileExists(atPath: file.original.path) else { return nil }
            do {
                try fileManager.createDirectory(at: file.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: file.inTrash, to: file.original)
                return nil
            } catch {
                return file.original.lastPathComponent
            }
        }
    }
}
