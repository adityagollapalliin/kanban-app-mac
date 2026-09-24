import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("Task repository")
struct TaskRepositoryTests {

    private func fixture() throws -> (
        database: Database,
        repository: TaskRepository,
        clock: FixedClock,
        ids: (workspace: String, project: String, board: String, toDo: String, inProgress: String, done: String)
    ) {
        let database = try Database.inMemoryMigrated()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        return (database, TaskRepository(database: database, clock: clock), clock, try database.seedBoardProject())
    }

    // MARK: - Creating

    @Test("Numbers are handed out in sequence, one per project")
    func numbering() throws {
        let (_, repository, _, ids) = try fixture()

        let first = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "First")
        let second = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Second")
        let third = try repository.create(inProject: ids.project, statusID: ids.inProgress, title: "Third")

        #expect(first.number == 1)
        #expect(second.number == 2)
        // The counter belongs to the project, not the column.
        #expect(third.number == 3)
    }

    @Test("New tasks land at the bottom of their column")
    func appendsToEnd() throws {
        let (_, repository, _, ids) = try fixture()

        let first = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "First")
        let second = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Second")

        #expect(second.sortOrder > first.sortOrder)
        let column = try repository.tasks(inProject: ids.project, statusID: ids.toDo)
        #expect(column.map(\.title) == ["First", "Second"])
    }

    @Test("A blank title is refused")
    func blankTitle() throws {
        let (_, repository, _, ids) = try fixture()
        #expect(throws: LocalBoardError.self) {
            try repository.create(inProject: ids.project, statusID: ids.toDo, title: "   \n ")
        }
    }

    @Test("Titles are trimmed, not stored as typed")
    func trimsTitle() throws {
        let (_, repository, _, ids) = try fixture()
        let task = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "  Tidy  ")
        #expect(task.title == "Tidy")
    }

    @Test("A task created straight into a done column is already complete")
    func createdDone() throws {
        let (_, repository, clock, ids) = try fixture()
        let task = try repository.create(inProject: ids.project, statusID: ids.done, title: "Already finished")
        #expect(task.completedAt == clock.now)
    }

    // MARK: - Moving

    @Test("Moving into a done column stamps the completion time")
    func completionStamped() throws {
        let (_, repository, clock, ids) = try fixture()
        let task = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Ship it")
        #expect(task.completedAt == nil)

        clock.advance(by: 3_600)
        let moved = try repository.move(task.id, toStatus: ids.done)

        #expect(moved.statusID == ids.done)
        #expect(moved.completedAt == clock.now)
    }

    @Test("Moving back out of done clears the completion time")
    func completionCleared() throws {
        let (_, repository, _, ids) = try fixture()
        let task = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Reopened")

        _ = try repository.move(task.id, toStatus: ids.done)
        let reopened = try repository.move(task.id, toStatus: ids.inProgress)

        #expect(reopened.completedAt == nil)
    }

    /// Re-completing should not rewrite history: the original finish time is
    /// what "when was this done" means.
    @Test("Moving within done keeps the original completion time")
    func completionPreserved() throws {
        let (_, repository, clock, ids) = try fixture()
        let first = try repository.create(inProject: ids.project, statusID: ids.done, title: "First")
        let second = try repository.create(inProject: ids.project, statusID: ids.done, title: "Second")
        let originalTime = try #require(try repository.task(id: second.id).completedAt)

        clock.advance(by: 86_400)
        let reordered = try repository.move(second.id, toStatus: ids.done, before: first.id)

        #expect(reordered.completedAt == originalTime)
    }

    @Test("A task dropped between two others lands between them")
    func dropsBetween() throws {
        let (_, repository, _, ids) = try fixture()
        let a = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "A")
        let b = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "B")
        let c = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "C")

        _ = try repository.move(c.id, toStatus: ids.toDo, after: a.id, before: b.id)

        let column = try repository.tasks(inProject: ids.project, statusID: ids.toDo)
        #expect(column.map(\.title) == ["A", "C", "B"])
    }

    @Test("Moving to the top and the bottom of a column both work")
    func dropsAtEnds() throws {
        let (_, repository, _, ids) = try fixture()
        let a = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "A")
        let b = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "B")

        _ = try repository.move(b.id, toStatus: ids.toDo, before: a.id)
        #expect(try repository.tasks(inProject: ids.project, statusID: ids.toDo).map(\.title) == ["B", "A"])

        _ = try repository.move(b.id, toStatus: ids.toDo, after: a.id)
        #expect(try repository.tasks(inProject: ids.project, statusID: ids.toDo).map(\.title) == ["A", "B"])
    }

    /// The failure mode sparse ordering actually has: a gap halved until it can
    /// no longer be split. The column must respace itself and the drop must
    /// still land where the user aimed it.
    @Test("A column whose gap is exhausted respaces itself and keeps the order")
    func rebalancesWhenGapIsExhausted() throws {
        let (database, repository, _, ids) = try fixture()
        let a = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "A")
        let b = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "B")
        let mover = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Mover")

        // Drive A and B to neighbouring positions no midpoint can separate.
        try database.execute("UPDATE task SET sort_order = ? WHERE id = ?;", [1_000.0, a.id])
        try database.execute(
            "UPDATE task SET sort_order = ? WHERE id = ?;",
            [1_000.0 + SortOrder.minimumGap / 4, b.id]
        )

        _ = try repository.move(mover.id, toStatus: ids.toDo, after: a.id, before: b.id)

        let column = try repository.tasks(inProject: ids.project, statusID: ids.toDo)
        #expect(column.map(\.title) == ["A", "Mover", "B"])

        // And the column is usable again: every position distinct, with room
        // between each pair.
        let positions = column.map(\.sortOrder)
        #expect(Set(positions).count == positions.count)
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $1 - $0 > SortOrder.minimumGap })
    }

    // MARK: - Editing and trash

    @Test("Trashed tasks leave the board but stay on disk")
    func trashing() throws {
        let (database, repository, _, ids) = try fixture()
        let task = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Mistake")

        try repository.setTrashed(true, for: task.id)
        #expect(try repository.tasks(inProject: ids.project, statusID: ids.toDo).isEmpty)
        #expect(try database.count("SELECT COUNT(*) FROM task;") == 1)

        try repository.setTrashed(false, for: task.id)
        #expect(try repository.tasks(inProject: ids.project, statusID: ids.toDo).count == 1)
    }

    @Test("An edit moves the updated stamp and leaves the created one alone")
    func editStampsUpdatedAt() throws {
        let (_, repository, clock, ids) = try fixture()
        let task = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Before")

        clock.advance(by: 60)
        try repository.setTitle("After", for: task.id)

        let edited = try repository.task(id: task.id)
        #expect(edited.title == "After")
        #expect(edited.createdAt == task.createdAt)
        #expect(edited.updatedAt == clock.now)
    }

    @Test("Type and priority survive a round trip")
    func setTypeAndPriority() throws {
        let (_, repository, _, ids) = try fixture()
        let task = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Triage me")
        #expect(task.type == .task)
        #expect(task.priority == .normal)

        try repository.setType(.bug, for: task.id)
        try repository.setPriority(.highest, for: task.id)

        let edited = try repository.task(id: task.id)
        #expect(edited.type == .bug)
        #expect(edited.priority == .highest)
    }

    @Test("A due date can be set and cleared again")
    func setAndClearDueDate() throws {
        let (_, repository, clock, ids) = try fixture()
        let task = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Deadline")
        #expect(task.dueDate == nil)

        try repository.setDueDate(clock.now, for: task.id)
        #expect(try repository.task(id: task.id).dueDate == clock.now)

        try repository.setDueDate(nil, for: task.id)
        #expect(try repository.task(id: task.id).dueDate == nil)
    }

    /// The inspector writes notes on blur, including blanking them.
    @Test("Notes can be written and emptied")
    func setDescription() throws {
        let (_, repository, _, ids) = try fixture()
        let task = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Documented")

        try repository.setDescription("Some **notes**", for: task.id)
        #expect(try repository.task(id: task.id).descriptionMarkdown == "Some **notes**")

        try repository.setDescription("", for: task.id)
        #expect(try repository.task(id: task.id).descriptionMarkdown == "")
    }

    @Test("Editing a task that is not there is an error, not a silent no-op")
    func editMissingTask() throws {
        let (_, repository, _, _) = try fixture()
        #expect(throws: LocalBoardError.self) {
            try repository.setTitle("Ghost", for: UUID().uuidString)
        }
    }

    // MARK: - Search

    @Test("Search matches titles and descriptions, by prefix")
    func search() throws {
        let (_, repository, _, ids) = try fixture()
        try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Refactor the parser")
        try repository.create(
            inProject: ids.project, statusID: ids.toDo,
            title: "Unrelated", descriptionMarkdown: "mentions the parser too"
        )
        try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Nothing to see")

        #expect(try repository.search(inProject: ids.project, matching: "parser").count == 2)
        #expect(try repository.search(inProject: ids.project, matching: "refac").count == 1)
        #expect(try repository.search(inProject: ids.project, matching: "absent").isEmpty)
    }

    @Test("Trashed tasks are not searchable")
    func searchSkipsTrash() throws {
        let (_, repository, _, ids) = try fixture()
        let task = try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Findable")
        #expect(try repository.search(inProject: ids.project, matching: "findable").count == 1)

        try repository.setTrashed(true, for: task.id)
        #expect(try repository.search(inProject: ids.project, matching: "findable").isEmpty)
    }

    /// FTS5 reads its own operators out of the string. A user typing one must
    /// get no results, never a thrown query.
    @Test("Search operators typed by the user cannot break the query")
    func searchHandlesOperators() throws {
        let (_, repository, _, ids) = try fixture()
        try repository.create(inProject: ids.project, statusID: ids.toDo, title: "Ordinary task")

        for hostile in ["\"", "NEAR(", "*", "-", "a OR b", "column:value", "((("] {
            #expect(throws: Never.self) {
                _ = try repository.search(inProject: ids.project, matching: hostile)
            }
        }
    }
}
