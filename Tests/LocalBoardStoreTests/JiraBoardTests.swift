import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

/// A clock the test moves by hand, so a card can spend a week in a column
/// without the test spending a week running.
final class StoppedClock: ClockProvider, @unchecked Sendable {
    var now: Date
    init(_ start: Date) { self.now = start }
    func advance(days: Int) { now = now.addingTimeInterval(Double(days) * 86_400) }
}

@Suite("Columns that gather several statuses")
struct ColumnMappingTests {

    @Test("A column shows the cards of every status mapped to it")
    func gathersMappedStatuses() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let repository = BoardRepository(database: database)
        let tasks = TaskRepository(database: database)

        let doing = try repository.snapshot(boardID: ids.board).columns[1]
        try repository.mapStatus(ids.done, toColumn: doing.id)

        try tasks.create(inProject: ids.project, statusID: ids.inProgress, title: "Being written")
        try tasks.create(inProject: ids.project, statusID: ids.done, title: "Being reviewed")

        let snapshot = try repository.snapshot(boardID: ids.board)
        let merged = snapshot.columns[1]

        #expect(merged.statuses.count == 2)
        #expect(merged.tasks.count == 2)
        // The drop target leads, whichever order the mapping happens to be in.
        #expect(merged.status.id == ids.inProgress)
        // Merging two columns leaves one column, not one full and one empty.
        #expect(snapshot.columns.count == 2)
    }

    @Test("A status cannot be shown twice on one board")
    func noDoubleMapping() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let repository = BoardRepository(database: database)
        let columns = try repository.snapshot(boardID: ids.board).columns

        try repository.mapStatus(ids.done, toColumn: columns[1].id)

        // Mapping it again elsewhere would put its cards in two places at once.
        #expect(throws: LocalBoardError.self) {
            try repository.mapStatus(ids.done, toColumn: columns[0].id)
        }
    }

    @Test("A column's own status cannot be unmapped out from under it")
    func dropTargetStays() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let repository = BoardRepository(database: database)
        let column = try repository.snapshot(boardID: ids.board).columns[0]

        #expect(throws: LocalBoardError.self) {
            try repository.unmapStatus(ids.toDo, fromColumn: column.id)
        }
    }

    @Test("Unmapping returns the cards to their own column")
    func unmapRestores() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let repository = BoardRepository(database: database)
        let tasks = TaskRepository(database: database)
        let doing = try repository.snapshot(boardID: ids.board).columns[1]

        try repository.mapStatus(ids.done, toColumn: doing.id)
        try tasks.create(inProject: ids.project, statusID: ids.done, title: "Finished")
        #expect(try repository.snapshot(boardID: ids.board).columns[1].tasks.count == 1)

        try repository.unmapStatus(ids.done, fromColumn: doing.id)

        let snapshot = try repository.snapshot(boardID: ids.board)
        #expect(snapshot.columns[1].tasks.isEmpty)
        #expect(snapshot.columns[2].tasks.count == 1)
    }
}

@Suite("Work-in-progress limits")
struct WIPLimitTests {

    @Test("A limit is approached before it is breached")
    func states() {
        let column = BoardColumn(id: "c", boardID: "b", statusID: "s", name: "Doing",
                                 wipLimit: 3, sortOrder: 0)
        #expect(column.state(for: 2) == .fine)
        #expect(column.state(for: 3) == .approaching)
        #expect(column.state(for: 4) == .breached)
    }

    @Test("A minimum reports a starved column")
    func minimum() {
        let column = BoardColumn(id: "c", boardID: "b", statusID: "s", name: "Doing",
                                 wipLimit: 5, wipMinimum: 2, sortOrder: 0)
        #expect(column.state(for: 1) == .belowMinimum)
        #expect(column.state(for: 2) == .fine)
    }

    @Test("Counting points adds up estimates rather than cards")
    func measuredInPoints() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let repository = BoardRepository(database: database)
        let tasks = TaskRepository(database: database)

        let column = try repository.snapshot(boardID: ids.board).columns[0]
        try repository.setWIPMeasure(.estimate, for: column.id)
        try repository.setWIPLimit(5, for: column.id)

        let big = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Big")
        let small = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Small")
        try tasks.setEstimate(5, for: big.id)
        try tasks.setEstimate(3, for: small.id)
        // Unestimated: contributes nothing, and the column says how many.
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Unsized")

        let loaded = try repository.snapshot(boardID: ids.board).columns[0]
        #expect(loaded.tasks.count == 3)
        #expect(loaded.wipAmount == 8)
        #expect(loaded.wipState == .breached)
        #expect(loaded.unestimatedCount == 1)
    }

    /// The promise the board makes: it reports, it does not refuse.
    @Test("Going over a limit never blocks the move")
    func limitsWarnButDoNotBlock() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let repository = BoardRepository(database: database)
        let tasks = TaskRepository(database: database)

        let column = try repository.snapshot(boardID: ids.board).columns[1]
        try repository.setWIPLimit(1, for: column.id)

        let first = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "One")
        let second = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Two")
        try tasks.move(first.id, toStatus: ids.inProgress)
        try tasks.move(second.id, toStatus: ids.inProgress)

        let loaded = try repository.snapshot(boardID: ids.board).columns[1]
        #expect(loaded.tasks.count == 2)
        #expect(loaded.isOverWIPLimit)
    }
}

@Suite("The backlog")
struct BacklogTests {

    @Test("A backlog column leaves the board and appears on its own")
    func backlogIsSeparate() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let repository = BoardRepository(database: database)
        let tasks = TaskRepository(database: database)

        let first = try repository.snapshot(boardID: ids.board).columns[0]
        try repository.setBacklog(true, for: first.id)
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Waiting")

        let snapshot = try repository.snapshot(boardID: ids.board)
        #expect(snapshot.columns.count == 2)
        #expect(snapshot.backlog?.tasks.count == 1)
        #expect(snapshot.board.backlogEnabled)
    }

    @Test("Only one column can be the backlog")
    func oneBacklog() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let repository = BoardRepository(database: database)
        let columns = try repository.snapshot(boardID: ids.board).columns

        try repository.setBacklog(true, for: columns[0].id)
        try repository.setBacklog(true, for: columns[1].id)

        let snapshot = try repository.snapshot(boardID: ids.board)
        #expect(snapshot.backlog?.id == columns[1].id)
        #expect(snapshot.columns.count == 2)
    }
}

@Suite("Flags, history and the column clock")
struct CardHistoryTests {

    @Test("Creating a card opens its history")
    func creationRecorded() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "New")
        let history = try tasks.history(ofTask: task.id)

        #expect(history.count == 1)
        #expect(history[0].fromStatusID == nil)
        #expect(history[0].toStatusID == ids.toDo)
        #expect(task.statusChangedAt != nil)
    }

    @Test("Crossing to another column records a move and restarts the clock")
    func movesRecorded() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Travelling")
        clock.advance(days: 4)
        try tasks.move(task.id, toStatus: ids.inProgress)

        let history = try tasks.history(ofTask: task.id)
        #expect(history.count == 2)
        #expect(history[1].fromStatusID == ids.toDo)
        #expect(history[1].toStatusID == ids.inProgress)

        // The clock restarted: it has been in its new column no time at all.
        let moved = try tasks.task(id: task.id)
        #expect(moved.daysInColumn(now: clock.now) == 0)
        clock.advance(days: 2)
        #expect(moved.daysInColumn(now: clock.now) == 2)
    }

    /// The bug this guards against: dragging a card up its own column to tidy
    /// it would otherwise reset how long it has been stuck there, hiding
    /// exactly the thing the dots exist to show.
    @Test("Reordering inside a column is not a status change")
    func reorderIsNotAMove() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)

        let first = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "First")
        let second = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Second")

        clock.advance(days: 6)
        try tasks.move(second.id, toStatus: ids.toDo, after: nil, before: first.id)

        #expect(try tasks.history(ofTask: second.id).count == 1)
        #expect(try tasks.task(id: second.id).daysInColumn(now: clock.now) == 6)
    }

    @Test("Unflagging clears the reason it no longer has")
    func flagging() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Stuck")
        try tasks.setFlag(true, reason: "Waiting on legal", for: task.id)

        var loaded = try tasks.task(id: task.id)
        #expect(loaded.flagged)
        #expect(loaded.flagReason == "Waiting on legal")

        try tasks.setFlag(false, for: task.id)
        loaded = try tasks.task(id: task.id)
        #expect(!loaded.flagged)
        #expect(loaded.flagReason.isEmpty)
    }
}

@Suite("Releases")
struct VersionTests {

    @Test("Progress counts cards and points separately")
    func progress() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let versions = VersionRepository(database: database)

        let release = try versions.create(inProject: ids.project, name: "1.0")
        let done = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Done bit")
        let todo = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Todo bit")
        try tasks.setEstimate(2, for: done.id)
        try tasks.setEstimate(6, for: todo.id)
        try tasks.setVersion(release.id, for: done.id)
        try tasks.setVersion(release.id, for: todo.id)
        try tasks.move(done.id, toStatus: ids.done)

        let progress = try versions.progress(ofVersion: release.id)
        #expect(progress.total == 2)
        #expect(progress.done == 1)
        #expect(progress.fraction == 0.5)
        // Half the cards, a quarter of the work — which is the point of
        // reporting both rather than picking one.
        #expect(progress.points == 8)
        #expect(progress.donePoints == 2)
        #expect(progress.pointsFraction == 0.25)
    }

    @Test("Deleting a release leaves its cards alone")
    func deleteKeepsTasks() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let versions = VersionRepository(database: database)

        let release = try versions.create(inProject: ids.project, name: "1.0")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Shipping")
        try tasks.setVersion(release.id, for: task.id)

        try versions.delete(release.id)

        let loaded = try tasks.task(id: task.id)
        #expect(loaded.versionID == nil)
        #expect(loaded.title == "Shipping")
    }

    @Test("Shipping a version does not finish its unfinished work")
    func releaseKeepsOpenWork() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let versions = VersionRepository(database: database)

        let release = try versions.create(inProject: ids.project, name: "1.0")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Not done")
        try tasks.setVersion(release.id, for: task.id)

        try versions.setReleased(true, for: release.id)

        #expect(try versions.progress(ofVersion: release.id).done == 0)
        #expect(try tasks.task(id: task.id).completedAt == nil)
    }
}

@Suite("Bulk edits")
struct BulkEditTests {

    @Test("Undo puts back exactly what was there")
    func undoRestores() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        let first = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "A")
        let second = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "B")
        try tasks.setPriority(.low, for: first.id)
        try tasks.setPriority(.highest, for: second.id)

        let undo = try tasks.setPriorityAll(.normal, for: [first.id, second.id])
        #expect(try tasks.task(id: first.id).priority == .normal)

        try tasks.restore(undo)

        // Not "the previous value" as one setting, but each card's own.
        #expect(try tasks.task(id: first.id).priority == .low)
        #expect(try tasks.task(id: second.id).priority == .highest)
    }

    @Test("Undoing a bulk move puts the cards back in their own columns")
    func undoMove() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        let fromToDo = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "A")
        let fromDoing = try tasks.create(inProject: ids.project, statusID: ids.inProgress, title: "B")

        let undo = try tasks.moveAll([fromToDo.id, fromDoing.id], toStatus: ids.done)
        #expect(try tasks.task(id: fromToDo.id).statusID == ids.done)

        try tasks.restore(undo)

        #expect(try tasks.task(id: fromToDo.id).statusID == ids.toDo)
        #expect(try tasks.task(id: fromDoing.id).statusID == ids.inProgress)
    }

    @Test("A card deleted between selecting and acting does not fail the edit")
    func missingCardSkipped() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        let real = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Here")
        let undo = try tasks.setFlagAll(true, reason: "Blocked", for: [real.id, "gone"])

        #expect(try tasks.task(id: real.id).flagged)
        #expect(undo.tasks.count == 1)
    }
}
