import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("Board repository")
struct BoardRepositoryTests {

    @Test("A snapshot returns the columns in board order, each with its status")
    func snapshotColumns() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let repository = BoardRepository(database: database)

        let snapshot = try repository.snapshot(boardID: ids.board)

        #expect(snapshot.board.id == ids.board)
        #expect(snapshot.columns.map(\.name) == ["To Do", "In Progress", "Done"])
        #expect(snapshot.columns.map(\.status.category) == [.toDo, .inProgress, .done])
    }

    @Test("Cards are grouped into the column their status belongs to")
    func snapshotGroupsTasks() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let repository = BoardRepository(database: database)

        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "A")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "B")
        try tasks.create(inProject: ids.project, statusID: ids.done, title: "C")

        let snapshot = try repository.snapshot(boardID: ids.board)

        #expect(snapshot.columns[0].tasks.map(\.title) == ["A", "B"])
        #expect(snapshot.columns[1].tasks.isEmpty)
        #expect(snapshot.columns[2].tasks.map(\.title) == ["C"])
        #expect(snapshot.taskCount == 3)
    }

    @Test("Cards within a column come back in board order, not insertion order")
    func snapshotOrdersWithinColumn() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let repository = BoardRepository(database: database)

        let a = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "A")
        let b = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "B")
        _ = try tasks.move(b.id, toStatus: ids.toDo, before: a.id)

        let snapshot = try repository.snapshot(boardID: ids.board)
        #expect(snapshot.columns[0].tasks.map(\.title) == ["B", "A"])
    }

    @Test("Trashed cards are absent from the board")
    func snapshotSkipsTrash() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let repository = BoardRepository(database: database)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Gone")
        try tasks.setTrashed(true, for: task.id)

        #expect(try repository.snapshot(boardID: ids.board).taskCount == 0)
    }

    /// The limit is a report, not a gate. Exceeding it must be visible and must
    /// not have been prevented.
    @Test("A column over its WIP limit says so, having accepted the card anyway")
    func wipLimit() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let repository = BoardRepository(database: database)

        try database.execute(
            "UPDATE board_column SET wip_limit = ? WHERE status_id = ?;", [1, ids.inProgress]
        )
        try tasks.create(inProject: ids.project, statusID: ids.inProgress, title: "One")

        #expect(try repository.snapshot(boardID: ids.board).columns[1].isOverWIPLimit == false)

        try tasks.create(inProject: ids.project, statusID: ids.inProgress, title: "Two")

        let column = try repository.snapshot(boardID: ids.board).columns[1]
        #expect(column.isOverWIPLimit)
        #expect(column.tasks.count == 2)
    }

    @Test("A column with no limit is never over it")
    func noWipLimit() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        for index in 1...5 {
            try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Task \(index)")
        }

        let snapshot = try BoardRepository(database: database).snapshot(boardID: ids.board)
        #expect(snapshot.columns[0].isOverWIPLimit == false)
    }

    @Test("Asking for a board that is not there is an error")
    func missingBoard() throws {
        let database = try Database.inMemoryMigrated()
        let repository = BoardRepository(database: database)
        #expect(throws: LocalBoardError.self) {
            try repository.snapshot(boardID: UUID().uuidString)
        }
    }

    // MARK: - First run

    @Test("An empty file gets a workspace, a project and a three-column board")
    func starterContent() throws {
        let database = try Database.inMemoryMigrated()
        let repository = BoardRepository(database: database)

        let board = try #require(try repository.ensureStarterContent())
        let snapshot = try repository.snapshot(boardID: board.id)

        #expect(snapshot.columns.map(\.name) == ["To Do", "In Progress", "Done"])
        #expect(snapshot.columns.map(\.status.category) == [.toDo, .inProgress, .done])
        #expect(try repository.workspaces().count == 1)
    }

    /// It runs on every launch, so running it twice must not produce a second
    /// of everything.
    @Test("Running it again opens the same board and writes nothing")
    func starterContentIsIdempotent() throws {
        let database = try Database.inMemoryMigrated()
        let repository = BoardRepository(database: database)

        let first = try #require(try repository.ensureStarterContent())
        let second = try #require(try repository.ensureStarterContent())

        #expect(first.id == second.id)
        #expect(try repository.workspaces().count == 1)
        #expect(try database.count("SELECT COUNT(*) FROM board;") == 1)
        #expect(try database.count("SELECT COUNT(*) FROM status;") == 3)
    }

    @Test("An existing board is adopted rather than joined by a starter one")
    func starterContentLeavesExistingDataAlone() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let repository = BoardRepository(database: database)

        let board = try #require(try repository.ensureStarterContent())

        #expect(board.id == ids.board)
        #expect(try database.count("SELECT COUNT(*) FROM board;") == 1)
    }

    /// A user who deleted their only board has said something; refilling it
    /// would be overruling them.
    @Test("A workspace with no boards is left as the user left it")
    func starterContentRespectsAnEmptiedWorkspace() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        try database.execute("DELETE FROM board WHERE id = ?;", [ids.board])
        let repository = BoardRepository(database: database)

        #expect(try repository.ensureStarterContent() == nil)
        #expect(try database.count("SELECT COUNT(*) FROM board;") == 0)
    }

    @Test("The sidebar reads back what was seeded")
    func sidebarQueries() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let repository = BoardRepository(database: database)

        let workspaces = try repository.workspaces()
        #expect(workspaces.map(\.id) == [ids.workspace])
        #expect(try repository.projects(inWorkspace: ids.workspace).map(\.id) == [ids.project])
        #expect(try repository.boards(inProject: ids.project).map(\.id) == [ids.board])
        #expect(try repository.statuses(inProject: ids.project).map(\.name) == ["To Do", "In Progress", "Done"])
    }

    @Test("Archived projects stay out of the sidebar unless asked for")
    func archivedProjects() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let repository = BoardRepository(database: database)

        try database.execute("UPDATE project SET archived = 1 WHERE id = ?;", [ids.project])

        #expect(try repository.projects(inWorkspace: ids.workspace).isEmpty)
        #expect(try repository.projects(inWorkspace: ids.workspace, includeArchived: true).count == 1)
    }
}
