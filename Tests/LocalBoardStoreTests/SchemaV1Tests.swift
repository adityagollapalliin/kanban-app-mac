import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("Schema v1 behaviour")
struct SchemaV1Tests {

    @Test("Deleting a project takes its tasks with it")
    func cascadeDelete() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedMinimalProject()
        try database.insertTask(project: ids.project, status: ids.status, number: 1, title: "Gone soon")

        try database.execute("DELETE FROM project WHERE id = ?;", [ids.project])

        #expect(try database.count("SELECT count(*) FROM task;") == 0)
        #expect(try database.count("SELECT count(*) FROM status;") == 0)
    }

    @Test("Deleting a person unassigns their tasks rather than deleting them")
    func assigneeSetNull() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedMinimalProject()
        let person = UUID().uuidString
        try database.execute(
            "INSERT INTO person (id, name, sort_order, created_at) VALUES (?, ?, ?, ?);",
            [person, "Sam", 1.0, 0.0]
        )
        let task = try database.insertTask(project: ids.project, status: ids.status, number: 1, title: "Assigned")
        try database.execute("UPDATE task SET assignee_id = ? WHERE id = ?;", [person, task])

        try database.execute("DELETE FROM person WHERE id = ?;", [person])

        #expect(try database.count("SELECT count(*) FROM task;") == 1)
        let row = try #require(try database.queryOne("SELECT assignee_id FROM task WHERE id = ?;", [task]))
        #expect(row["assignee_id"] == .null)
    }

    @Test("Task numbers are unique per project but may repeat across projects")
    func taskNumberUniqueness() throws {
        let database = try Database.inMemoryMigrated()
        let first = try database.seedMinimalProject()

        try database.insertTask(project: first.project, status: first.status, number: 1, title: "WORK-1")
        #expect(throws: LocalBoardError.self) {
            try database.insertTask(project: first.project, status: first.status, number: 1, title: "clash")
        }

        // A second project reuses number 1 happily.
        let secondProject = UUID().uuidString
        let secondStatus = UUID().uuidString
        try database.execute(
            "INSERT INTO project (id, workspace_id, name, key, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?);",
            [secondProject, first.workspace, "Home", "HOME", 2_000.0, 0.0]
        )
        try database.execute(
            "INSERT INTO status (id, project_id, name, category, sort_order) VALUES (?, ?, ?, ?, ?);",
            [secondStatus, secondProject, "To Do", 0, 1_000.0]
        )
        try database.insertTask(project: secondProject, status: secondStatus, number: 1, title: "HOME-1")

        #expect(try database.count("SELECT count(*) FROM task;") == 2)
    }

    @Test("A board column maps each status at most once")
    func columnUniqueness() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedMinimalProject()
        let board = UUID().uuidString
        try database.execute(
            "INSERT INTO board (id, project_id, name, sort_order, created_at) VALUES (?, ?, ?, ?, ?);",
            [board, ids.project, "Sprint board", 1_000.0, 0.0]
        )
        try database.execute(
            "INSERT INTO board_column (id, board_id, status_id, name, sort_order) VALUES (?, ?, ?, ?, ?);",
            [UUID().uuidString, board, ids.status, "To Do", 1_000.0]
        )

        #expect(throws: LocalBoardError.self) {
            try database.execute(
                "INSERT INTO board_column (id, board_id, status_id, name, sort_order) VALUES (?, ?, ?, ?, ?);",
                [UUID().uuidString, board, ids.status, "To Do again", 2_000.0]
            )
        }
    }

    @Test("WIP limit is optional and stored as written")
    func wipLimitIsNullable() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedMinimalProject()
        let board = UUID().uuidString
        try database.execute(
            "INSERT INTO board (id, project_id, name, sort_order, created_at) VALUES (?, ?, ?, ?, ?);",
            [board, ids.project, "Board", 1_000.0, 0.0]
        )
        try database.execute(
            "INSERT INTO board_column (id, board_id, status_id, name, wip_limit, sort_order) VALUES (?, ?, ?, ?, ?, ?);",
            [UUID().uuidString, board, ids.status, "Doing", SQLValue.null, 1_000.0]
        )

        let row = try #require(try database.queryOne("SELECT wip_limit FROM board_column;"))
        #expect(row["wip_limit"] == .null)
        #expect(row.int("wip_limit") == nil)
    }

    /// Sparse ordering is what keeps a drag-and-drop to a single row update.
    @Test("Midpoint insertion orders a card between its neighbours")
    func sparseSortOrder() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedMinimalProject()

        try database.insertTask(project: ids.project, status: ids.status, number: 1, title: "first", sortOrder: 1_000)
        try database.insertTask(project: ids.project, status: ids.status, number: 2, title: "third", sortOrder: 2_000)
        try database.insertTask(project: ids.project, status: ids.status, number: 3, title: "second", sortOrder: 1_500)

        let titles = try database.query(
            "SELECT title FROM task WHERE status_id = ? ORDER BY sort_order;", [ids.status]
        ).compactMap { $0.string("title") }

        #expect(titles == ["first", "second", "third"])
    }

    @Test("Full-text search finds tasks by title and description")
    func fullTextSearch() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedMinimalProject()

        try database.insertTask(
            project: ids.project, status: ids.status, number: 1,
            title: "Refactor the exporter", description: "Split JSON and CSV paths"
        )
        try database.insertTask(
            project: ids.project, status: ids.status, number: 2,
            title: "Fix calendar drag", description: "Dropping on a weekend misplaces the card"
        )

        let byTitle = try database.query(
            "SELECT t.title FROM task_fts f JOIN task t ON t.rowid = f.rowid WHERE task_fts MATCH ?;",
            ["exporter"]
        )
        #expect(byTitle.count == 1)
        #expect(byTitle.first?.string("title") == "Refactor the exporter")

        let byDescription = try database.query(
            "SELECT t.title FROM task_fts f JOIN task t ON t.rowid = f.rowid WHERE task_fts MATCH ?;",
            ["weekend"]
        )
        #expect(byDescription.first?.string("title") == "Fix calendar drag")
    }

    @Test("The search index follows edits and deletions")
    func fullTextStaysInSync() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedMinimalProject()
        let task = try database.insertTask(
            project: ids.project, status: ids.status, number: 1, title: "Original heading"
        )

        try database.execute("UPDATE task SET title = ? WHERE id = ?;", ["Renamed heading", task])
        #expect(try database.count("SELECT count(*) FROM task_fts WHERE task_fts MATCH ?;", ["Original"]) == 0)
        #expect(try database.count("SELECT count(*) FROM task_fts WHERE task_fts MATCH ?;", ["Renamed"]) == 1)

        try database.execute("DELETE FROM task WHERE id = ?;", [task])
        #expect(try database.count("SELECT count(*) FROM task_fts WHERE task_fts MATCH ?;", ["Renamed"]) == 0)
    }

    @Test("Search ignores diacritics, so 'resume' finds 'résumé'")
    func diacriticInsensitiveSearch() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedMinimalProject()
        try database.insertTask(project: ids.project, status: ids.status, number: 1, title: "Update résumé")

        #expect(try database.count("SELECT count(*) FROM task_fts WHERE task_fts MATCH ?;", ["resume"]) == 1)
    }

    @Test("Subtasks cascade from their parent, epic links merely detach")
    func parentAndEpicLinks() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedMinimalProject()

        let epic = try database.insertTask(project: ids.project, status: ids.status, number: 1, title: "Epic")
        let parent = try database.insertTask(project: ids.project, status: ids.status, number: 2, title: "Parent")
        let child = try database.insertTask(project: ids.project, status: ids.status, number: 3, title: "Child")
        try database.execute("UPDATE task SET parent_id = ?, epic_id = ? WHERE id = ?;", [parent, epic, child])

        try database.execute("DELETE FROM task WHERE id = ?;", [epic])
        #expect(try database.count("SELECT count(*) FROM task WHERE id = ?;", [child]) == 1)

        try database.execute("DELETE FROM task WHERE id = ?;", [parent])
        #expect(try database.count("SELECT count(*) FROM task WHERE id = ?;", [child]) == 0)
    }
}
