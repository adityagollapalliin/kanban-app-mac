import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("Reshaping the board")
struct StructureEditingTests {

    private func fixture() throws -> (Database, BoardRepository, (workspace: String, project: String, board: String, toDo: String, inProgress: String, done: String)) {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        return (database, BoardRepository(database: database), ids)
    }

    // MARK: - Projects

    /// A project with no columns and no board is not usable, so making one
    /// without them would only be a state to recover from.
    @Test("A new project arrives ready to use")
    func createProject() throws {
        let (_, repository, ids) = try fixture()

        let project = try repository.createProject(inWorkspace: ids.workspace, name: "Second", key: "two")

        #expect(project.key == "TWO", "keys are upper-cased, since they are printed on every card")
        let boards = try repository.boards(inProject: project.id)
        #expect(boards.count == 1)
        #expect(try repository.statuses(inProject: project.id).map(\.name) == ["To Do", "In Progress", "Done"])
        #expect(try repository.snapshot(boardID: boards[0].id).columns.count == 3)
    }

    @Test("Keys are unique within a workspace")
    func duplicateKey() throws {
        let (_, repository, ids) = try fixture()
        #expect(throws: LocalBoardError.self) {
            try repository.createProject(inWorkspace: ids.workspace, name: "Clash", key: "work")
        }
    }

    @Test("A key has to be letters and digits")
    func badKey() throws {
        let (_, repository, ids) = try fixture()
        #expect(throws: LocalBoardError.self) {
            try repository.createProject(inWorkspace: ids.workspace, name: "Odd", key: "a b/c")
        }
        #expect(throws: LocalBoardError.self) {
            try repository.createProject(inWorkspace: ids.workspace, name: "Nameless", key: "")
        }
    }

    @Test("Archiving hides a project; deleting takes it and its cards")
    func archiveAndDelete() throws {
        let (database, repository, ids) = try fixture()
        try TaskRepository(database: database).create(
            inProject: ids.project, statusID: ids.toDo, title: "Doomed"
        )

        try repository.setArchived(true, for: ids.project)
        #expect(try repository.projects(inWorkspace: ids.workspace).isEmpty)
        #expect(try database.count("SELECT COUNT(*) FROM task;") == 1)

        try repository.deleteProject(ids.project)
        #expect(try database.count("SELECT COUNT(*) FROM task;") == 0, "the cascade takes the cards")
    }

    // MARK: - Boards

    /// A second board over the same project should show that project's
    /// columns; a board with none would show nothing at all.
    @Test("A new board starts with the project's existing columns")
    func createBoard() throws {
        let (_, repository, ids) = try fixture()

        let board = try repository.createBoard(inProject: ids.project, name: "Planning")
        let snapshot = try repository.snapshot(boardID: board.id)

        #expect(snapshot.columns.map(\.name) == ["To Do", "In Progress", "Done"])
        #expect(try repository.boards(inProject: ids.project).count == 2)
    }

    @Test("Two boards over one project show the same cards")
    func boardsShareCards() throws {
        let (database, repository, ids) = try fixture()
        try TaskRepository(database: database).create(
            inProject: ids.project, statusID: ids.toDo, title: "Shared"
        )

        let second = try repository.createBoard(inProject: ids.project, name: "Planning")

        #expect(try repository.snapshot(boardID: ids.board).taskCount == 1)
        #expect(try repository.snapshot(boardID: second.id).taskCount == 1)
    }

    // MARK: - Columns

    @Test("A column can be added, renamed and given a limit")
    func columnLifecycle() throws {
        let (_, repository, ids) = try fixture()

        let column = try repository.addColumn(toBoard: ids.board, name: "Review", category: .inProgress)
        #expect(try repository.snapshot(boardID: ids.board).columns.map(\.name).last == "Review")

        try repository.renameColumn(column.id, to: "In Review")
        let renamed = try repository.snapshot(boardID: ids.board).columns.last
        #expect(renamed?.name == "In Review")
        // Both halves move: the status name is what `status = "In Review"` matches.
        #expect(renamed?.status.name == "In Review")

        try repository.setWIPLimit(3, for: column.id)
        #expect(try repository.snapshot(boardID: ids.board).columns.last?.column.wipLimit == 3)

        try repository.setWIPLimit(nil, for: column.id)
        #expect(try repository.snapshot(boardID: ids.board).columns.last?.column.wipLimit == nil)
    }

    @Test("A limit below one would make the column unusable")
    func sillyLimit() throws {
        let (_, repository, ids) = try fixture()
        let column = try repository.addColumn(toBoard: ids.board, name: "Review")
        #expect(throws: LocalBoardError.self) { try repository.setWIPLimit(0, for: column.id) }
    }

    @Test("Two columns on a board cannot share a name")
    func duplicateColumnName() throws {
        let (_, repository, ids) = try fixture()
        #expect(throws: LocalBoardError.self) {
            try repository.addColumn(toBoard: ids.board, name: "to do")
        }
    }

    /// Deleting a status would take its cards with it, so a column holding
    /// work cannot go without saying where the work should land.
    @Test("A column holding cards cannot be removed without somewhere to put them")
    func deletingBusyColumn() throws {
        let (database, repository, ids) = try fixture()
        let tasks = TaskRepository(database: database)
        try tasks.create(inProject: ids.project, statusID: ids.inProgress, title: "In flight")

        let columns = try repository.snapshot(boardID: ids.board).columns
        let busy = try #require(columns.first { $0.status.id == ids.inProgress })

        #expect(throws: LocalBoardError.self) {
            try repository.deleteColumn(busy.id, movingTasksTo: nil)
        }
        #expect(try database.count("SELECT COUNT(*) FROM task;") == 1)

        try repository.deleteColumn(busy.id, movingTasksTo: ids.toDo)

        let after = try repository.snapshot(boardID: ids.board)
        #expect(after.columns.map(\.name) == ["To Do", "Done"])
        #expect(after.columns[0].tasks.map(\.title) == ["In flight"], "the cards moved rather than died")
    }

    @Test("An empty column just goes")
    func deletingEmptyColumn() throws {
        let (_, repository, ids) = try fixture()
        let columns = try repository.snapshot(boardID: ids.board).columns
        let empty = try #require(columns.first { $0.status.id == ids.done })

        try repository.deleteColumn(empty.id, movingTasksTo: nil)
        #expect(try repository.snapshot(boardID: ids.board).columns.map(\.name) == ["To Do", "In Progress"])
    }

    @Test("Columns can be reordered")
    func reorderColumns() throws {
        let (_, repository, ids) = try fixture()
        let columns = try repository.snapshot(boardID: ids.board).columns
        let done = columns[2]
        let toDo = columns[0]

        try repository.moveColumn(done.id, after: nil, before: toDo.id)

        #expect(try repository.snapshot(boardID: ids.board).columns.map(\.name) == ["Done", "To Do", "In Progress"])
    }

    @Test("A column's category can change, which changes what done means")
    func columnCategory() throws {
        let (database, repository, ids) = try fixture()
        let tasks = TaskRepository(database: database)
        let columns = try repository.snapshot(boardID: ids.board).columns
        let review = try repository.addColumn(toBoard: ids.board, name: "Review", category: .inProgress)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Work")
        _ = try tasks.move(task.id, toStatus: try #require(
            repository.snapshot(boardID: ids.board).columns.last?.status.id
        ))
        #expect(try tasks.task(id: task.id).completedAt == nil)

        try repository.setCategory(.done, for: review.id)
        _ = try tasks.move(task.id, toStatus: columns[0].status.id)
        _ = try tasks.move(task.id, toStatus: try #require(
            repository.snapshot(boardID: ids.board).columns.last?.status.id
        ))

        #expect(try tasks.task(id: task.id).completedAt != nil)
    }
}
