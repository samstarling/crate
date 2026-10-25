import Foundation
@testable import RekordboxKit
import Testing

@MainActor
@Suite("Library sessions: staging, applying, undo and redo")
struct LibrarySessionTests {
    let fixture: LibraryFixture
    let rhythmic = TrackColor(id: 1, name: "Rhythmic")
    let melodic = TrackColor(id: 5, name: "Melodic")

    init() throws {
        fixture = try LibraryFixture()
    }

    /// Files for tests: backups go in the fixture's folder, and "the Trash" is a folder there too.
    private func files(
        backUp: (@Sendable (URL) throws -> Void)? = nil,
        moveToTrash: (@Sendable ([URL]) -> (trashed: [TrashedFile], failures: [String]))? = nil
    ) -> FileOperations {
        let backups = fixture.folder.appending(path: "Backups")
        let trash = fixture.folder.appending(path: "Trash")
        return FileOperations(
            backUp: backUp ?? { try FileOperations.backUp($0, into: backups, keeping: 10) },
            moveToTrash: moveToTrash ?? { paths in
                FileOperations.moveFiles(paths) { file in
                    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                    let destination = trash.appending(path: file.lastPathComponent)
                    try FileManager.default.moveItem(at: file, to: destination)
                    return destination
                }
            },
            restoreFromTrash: { FileOperations.restore($0) }
        )
    }

    private func session(
        backUp: (@Sendable (URL) throws -> Void)? = nil,
        moveToTrash: (@Sendable ([URL]) -> (trashed: [TrashedFile], failures: [String]))? = nil
    ) throws -> LibrarySession {
        LibrarySession(library: try fixture.loadLibrary(), files: files(backUp: backUp, moveToTrash: moveToTrash))
    }

    private func savedColor(of id: Track.ID) throws -> TrackColor? {
        try fixture.loadLibrary().tracksByID[id]?.color
    }

    /// Waits (briefly) for `condition`, for state that changes once a task has started running.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: Staging

    @Test func stagingShowsAChangeWithoutWritingIt() throws {
        let session = try session()
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        #expect(session.library.tracksByID[LibraryFixture.copperSun]?.color == rhythmic)
        #expect(session.pendingChanges.map(\.summary) == ["Set \u{201C}Copper Sun\u{201D} to Rhythmic"])
        #expect(try savedColor(of: LibraryFixture.copperSun) == nil)
    }

    @Test func undoUnstagesAndRedoStagesAgain() async throws {
        let session = try session()
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        #expect(session.undoActionName == "Set Colour")

        try await session.undo()
        #expect(session.pendingChanges.isEmpty)
        #expect(session.library.tracksByID[LibraryFixture.copperSun]?.color == nil)
        #expect(session.redoActionName == "Set Colour")

        try await session.redo()
        #expect(session.pendingChanges.count == 1)
        #expect(session.library.tracksByID[LibraryFixture.copperSun]?.color == rhythmic)
        #expect(!session.canRedo)
    }

    @Test func undoingADiscardPutsChangesBackWhereTheyWere() async throws {
        let session = try session()
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        session.setColor(melodic, forTrackIDs: [LibraryFixture.nightDrive])
        session.removeTracks(withIDs: [LibraryFixture.softMachines], movingFilesToTrash: false)
        let original = session.pendingChanges

        session.discard([original[0], original[2]])
        #expect(session.pendingChanges == [original[1]])
        #expect(session.library.tracksByID[LibraryFixture.softMachines] != nil)
        #expect(session.undoActionName == "Discard Changes")

        try await session.undo()
        #expect(session.pendingChanges == original)
        #expect(session.library.tracksByID[LibraryFixture.softMachines] == nil)

        try await session.redo()
        #expect(session.pendingChanges == [original[1]])
    }

    @Test func aNewChangeClearsRedo() async throws {
        let session = try session()
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        try await session.undo()
        #expect(session.canRedo)
        session.setColor(melodic, forTrackIDs: [LibraryFixture.nightDrive])
        #expect(!session.canRedo)
    }

    // MARK: Applying, undoing and redoing

    @Test func applyingWritesAndMovesChangesToApplied() async throws {
        let session = try session()
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        session.removeTracks(withIDs: [LibraryFixture.softMachines], movingFilesToTrash: false)
        try await session.applyPendingChanges()

        #expect(session.pendingChanges.isEmpty)
        #expect(session.appliedChanges.map(\.summary) == ["2 changes"])
        #expect(try savedColor(of: LibraryFixture.copperSun) == rhythmic)
        #expect(try fixture.loadLibrary().tracksByID[LibraryFixture.softMachines] == nil)
        #expect(session.savedLibrary.updateCount == (try fixture.loadLibrary().updateCount))
        // Staging the changes is folded into applying them.
        #expect(session.undoActionName == "Apply Changes")
        #expect(session.undoSteps.count == 1)
    }

    @Test func undoingAnApplyRevertsItAndRedoAppliesItAgain() async throws {
        let session = try session()
        let original = try fixture.contents()
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        session.removeTracks(withIDs: [LibraryFixture.nightDrive], movingFilesToTrash: false)
        try await session.applyPendingChanges()

        try await session.undo()
        #expect(try fixture.contents() == original)
        #expect(session.appliedChanges.first?.isReverted == true)
        #expect(session.library.tracksByID[LibraryFixture.nightDrive] != nil)
        #expect(session.redoActionName == "Apply Changes")

        try await session.redo()
        #expect(try savedColor(of: LibraryFixture.copperSun) == rhythmic)
        #expect(try fixture.loadLibrary().tracksByID[LibraryFixture.nightDrive] == nil)
        #expect(session.appliedChanges.first?.isReverted == false)

        // And back again, so the re-applied changes can be reverted too.
        try await session.undo()
        #expect(try fixture.contents() == original)
    }

    @Test func revertAndApplyAgainAreStepsLikeAnyOther() async throws {
        let session = try session()
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        try await session.applyPendingChanges()
        let applied = try #require(session.appliedChanges.first)

        try await session.revert(applied.id)
        #expect(try savedColor(of: LibraryFixture.copperSun) == nil)
        #expect(session.undoActionName == "Revert")

        try await session.undo()
        #expect(try savedColor(of: LibraryFixture.copperSun) == rhythmic)

        try await session.redo()
        #expect(try savedColor(of: LibraryFixture.copperSun) == nil)

        try await session.applyAgain(applied.id)
        #expect(try savedColor(of: LibraryFixture.copperSun) == rhythmic)
        #expect(session.undoActionName == "Apply Changes")
    }

    @Test func applyingTwiceAndUndoingBothRestoresTheLibrary() async throws {
        let session = try session()
        let original = try fixture.contents()
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.nightDrive])
        try await session.applyPendingChanges()
        session.setColor(melodic, forTrackIDs: [LibraryFixture.nightDrive])
        session.removeTracks(withIDs: [LibraryFixture.copperSun], movingFilesToTrash: false)
        try await session.applyPendingChanges()

        try await session.undo()
        try await session.undo()
        #expect(try fixture.contents() == original)
        #expect(!session.canUndo)
    }

    // MARK: Conflicts and failures

    @Test func aConflictKeepsChangesPendingAndTheHistoryIntact() async throws {
        let session = try session()
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        // Rekordbox edits the library meanwhile.
        try fixture.database.execute("UPDATE agentRegistry SET int_1 = 500 WHERE registry_id = 'localUpdateCount'")

        await #expect(throws: RekordboxLibrary.LibraryChanged.self) { try await session.applyPendingChanges() }
        #expect(session.pendingChanges.count == 1)
        #expect(session.appliedChanges.isEmpty)
        #expect(session.undoActionName == "Set Colour")
        #expect(try savedColor(of: LibraryFixture.copperSun) == nil)
        // The session reloaded, so applying again works.
        #expect(session.savedLibrary.updateCount == 500)
        try await session.applyPendingChanges()
        #expect(try savedColor(of: LibraryFixture.copperSun) == rhythmic)
    }

    @Test func aFailedUndoStaysToBeUndone() async throws {
        let session = try session()
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        try await session.applyPendingChanges()
        // Rekordbox changes the same track.
        try fixture.database.execute("UPDATE djmdContent SET Rating = 2 WHERE ID = '\(LibraryFixture.copperSun)'")

        await #expect(throws: RekordboxLibrary.CannotRevert.self) { try await session.undo() }
        #expect(session.undoActionName == "Apply Changes")
        #expect(!session.canRedo)
        #expect(try savedColor(of: LibraryFixture.copperSun) == rhythmic)
    }

    @Test func reloadingDropsTracksThatHaveGoneFromChangesAndHistory() async throws {
        let session = try session()
        session.removeTracks(withIDs: [LibraryFixture.nightDrive, LibraryFixture.copperSun], movingFilesToTrash: false)
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        try await session.undo()

        // Copper Sun is removed in Rekordbox, then Crate reloads.
        try RekordboxLibrary.removeTracks(
            withIDs: [LibraryFixture.copperSun], in: fixture.folder, expectedUpdateCount: LibraryFixture.initialUpdateCount
        )
        try await session.reload()

        #expect(session.pendingChanges.map(\.summary) == ["Remove \u{201C}Night Drive\u{201D}"])
        // The colour change only affected Copper Sun, so there's nothing left to redo.
        #expect(!session.canRedo)
        try await session.undo()
        try await session.redo()
        #expect(session.pendingChanges.map(\.summary) == ["Remove \u{201C}Night Drive\u{201D}"])
    }

    // MARK: Busy

    @Test func whileApplyingNothingCanBeUndoneOrDiscardedButChangesCanBeStaged() async throws {
        let gate = DispatchSemaphore(value: 0)
        // Holds the apply open until the test lets it go.
        let session = try session(backUp: { _ in gate.wait() })
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])

        let applying = Task { try await session.applyPendingChanges() }
        await eventually { session.isWriting }
        #expect(session.isWriting)
        #expect(!session.canUndo)
        session.discard(session.pendingChanges)
        #expect(session.pendingChanges.count == 1, "Discarding should be refused while applying")
        session.setColor(melodic, forTrackIDs: [LibraryFixture.nightDrive])
        #expect(session.pendingChanges.count == 2)

        gate.signal()
        try await applying.value
        #expect(!session.isWriting)
        // Only the change being applied was applied; the one staged meanwhile is still pending.
        #expect(try savedColor(of: LibraryFixture.copperSun) == rhythmic)
        #expect(try savedColor(of: LibraryFixture.nightDrive) == TrackColor(id: 8, name: "Wonky"))
        #expect(session.pendingChanges.map(\.summary) == ["Set \u{201C}Night Drive\u{201D} to Melodic"])
        // Undo takes back the later change first, then the apply.
        #expect(session.undoActionName == "Set Colour")
        try await session.undo()
        #expect(session.undoActionName == "Apply Changes")
    }

    @Test func whileApplyingReloadWaitsAndOnlyTheChangesBeingWrittenAreLocked() async throws {
        let gate = DispatchSemaphore(value: 0)
        let session = try session(backUp: { _ in gate.wait() })
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        let beingWritten = try #require(session.pendingChanges.first)

        let applying = Task { try await session.applyPendingChanges() }
        await eventually { session.isWriting }
        #expect(session.isBeingWritten(beingWritten))

        // Reloading mid-write could read a half-written library; it's refused until the write is done.
        try await session.reload()
        #expect(session.pendingChanges.count == 1)

        // A change staged while writing isn't part of the write, so it can be discarded.
        session.setColor(melodic, forTrackIDs: [LibraryFixture.nightDrive])
        let stagedMeanwhile = try #require(session.pendingChanges.last)
        #expect(!session.isBeingWritten(stagedMeanwhile))
        session.discard([beingWritten, stagedMeanwhile])
        #expect(session.pendingChanges == [beingWritten])

        gate.signal()
        try await applying.value
        #expect(session.pendingChanges.isEmpty)
        // Undo takes back the discard (taken while writing) first, then the apply.
        #expect(session.undoActionName == "Discard Change")
        try await session.undo()
        #expect(session.pendingChanges == [stagedMeanwhile])
        #expect(session.undoActionName == "Set Colour")
        try await session.undo()
        #expect(session.undoActionName == "Apply Changes")
    }

    @Test func aReloadFailingAfterAWriteIsReportedNotThrown() async throws {
        let library = fixture.folder.appending(path: "master.db")
        // Moving files happens after writing and before reloading, so this makes the reload fail.
        let session = try session(moveToTrash: { _ in
            try? FileManager.default.moveItem(at: library, to: library.appendingPathExtension("moved"))
            return ([], [])
        })
        session.removeTracks(withIDs: [LibraryFixture.copperSun], movingFilesToTrash: true)

        let report = try await session.applyPendingChanges()
        #expect(report.notReloaded != nil)
        // The write happened, and the session knows it.
        #expect(session.appliedChanges.count == 1)
        #expect(session.pendingChanges.isEmpty)
        #expect(session.undoActionName == "Apply Changes")
    }

    @Test func waitingForWritesReturnsOnceAWriteHasFinished() async throws {
        let gate = DispatchSemaphore(value: 0)
        let session = try session(backUp: { _ in gate.wait() })
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        let applying = Task { try await session.applyPendingChanges() }
        await eventually { session.isWriting }

        let waiting = Task { await session.waitForWrites() }
        gate.signal()
        await waiting.value
        #expect(!session.isWriting)
        #expect(session.pendingChanges.isEmpty)
        _ = try await applying.value
    }

    // MARK: Files

    @Test func removedTracksFilesGoToTheTrashAndComeBack() async throws {
        // Give Night Drive a real file.
        let music = fixture.folder.appending(path: "Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let file = music.appending(path: "Night Drive.mp3")
        try Data("audio".utf8).write(to: file)
        try fixture.database.execute("UPDATE djmdContent SET FolderPath = ? WHERE ID = ?", [.text(file.path), .text(LibraryFixture.nightDrive)])

        let session = try session()
        session.removeTracks(withIDs: [LibraryFixture.nightDrive], movingFilesToTrash: true)
        try await session.applyPendingChanges()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(session.appliedChanges.first?.trashedFiles.map(\.original) == [file])

        try await session.undo()
        #expect(FileManager.default.fileExists(atPath: file.path))

        try await session.redo()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func theLibraryIsBackedUpBeforeTheFirstWriteOnly() async throws {
        let session = try session()
        session.setColor(rhythmic, forTrackIDs: [LibraryFixture.copperSun])
        try await session.applyPendingChanges()
        session.setColor(melodic, forTrackIDs: [LibraryFixture.copperSun])
        try await session.applyPendingChanges()

        let backups = try FileManager.default.contentsOfDirectory(at: fixture.folder.appending(path: "Backups"), includingPropertiesForKeys: nil)
        let snapshots = try FileManager.default.contentsOfDirectory(at: try #require(backups.first), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(snapshots.count == 1)
    }

    @Test func theRealFileOperationsBackUpALibraryOncePerRun() async throws {
        let backups = fixture.folder.appending(path: "Backups")
        let files = FileOperations.live(backupsDirectory: backups)
        for color in [rhythmic, melodic] {
            // A new session each time, as when the same library is opened again.
            let session = LibrarySession(library: try fixture.loadLibrary(), files: files)
            session.setColor(color, forTrackIDs: [LibraryFixture.copperSun])
            try await session.applyPendingChanges()
        }
        let library = try #require(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first)
        #expect(try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil).count == 1)
    }

    @Test func backupsKeepTheFirstAndTheMostRecent() throws {
        let backups = fixture.folder.appending(path: "Backups")
        for _ in 0..<5 {
            try FileOperations.backUp(fixture.folder, into: backups, keeping: 2)
        }
        let library = try #require(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first)
        let snapshots = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
        // The first, plus the two most recent; all with the database in them.
        #expect(snapshots.count == 3)
        for snapshot in snapshots {
            #expect(FileManager.default.fileExists(atPath: library.appending(path: snapshot).appending(path: "master.db").path))
        }
    }
}
