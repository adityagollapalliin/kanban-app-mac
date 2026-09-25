import Foundation
import LocalBoardCore
@testable import LocalBoardStore

/// A temporary container that cleans itself up. Every store test gets its own,
/// so nothing touches the real app container.
struct TemporaryContainer {
    let paths: ContainerPaths

    init() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("localboard-tests-\(UUID().uuidString)", isDirectory: true)
        paths = ContainerPaths(dataDirectory: root)
        try paths.createDirectoriesIfNeeded()
    }

    func remove() {
        try? FileManager.default.removeItem(at: paths.dataDirectory)
    }
}

extension Database {
    /// A migrated in-memory database. Fast, and impossible to leave behind.
    static func inMemoryMigrated(_ migrations: [Migration] = Migration.all) throws -> Database {
        let database = try Database(location: .memory)
        try database.migrate(using: migrations)
        return database
    }

    /// Inserts the minimum tree a task needs: workspace → project → status.
    /// Returns the ids so tests can hang assertions off them.
    @discardableResult
    func seedMinimalProject(
        workspaceID: String = UUID().uuidString,
        projectID: String = UUID().uuidString,
        statusID: String = UUID().uuidString
    ) throws -> (workspace: String, project: String, status: String) {
        let now = Date().timeIntervalSince1970
        try execute(
            "INSERT INTO workspace (id, name, sort_order, created_at) VALUES (?, ?, ?, ?);",
            [workspaceID, "Personal", 1_000.0, now]
        )
        try execute(
            """
            INSERT INTO project (id, workspace_id, name, key, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [projectID, workspaceID, "Work", "WORK", 1_000.0, now]
        )
        try execute(
            "INSERT INTO status (id, project_id, name, category, sort_order) VALUES (?, ?, ?, ?, ?);",
            [statusID, projectID, "To Do", 0, 1_000.0]
        )
        return (workspaceID, projectID, statusID)
    }

    @discardableResult
    func hasTable(_ name: String) throws -> Bool {
        try count("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?;", [name]) > 0
    }

    @discardableResult
    func insertTask(
        project: String,
        status: String,
        number: Int,
        title: String,
        description: String = "",
        sortOrder: Double = 1_000
    ) throws -> String {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        try execute(
            """
            INSERT INTO task (id, project_id, status_id, number, title, description_md,
                              sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [id, project, status, number, title, description, sortOrder, now, now]
        )
        return id
    }
}

extension Database {
    /// A project with the three statuses a board actually has, so tests can
    /// move a task across categories and watch `completed_at` follow.
    @discardableResult
    func seedBoardProject() throws -> (
        workspace: String, project: String, board: String,
        toDo: String, inProgress: String, done: String
    ) {
        let now = Date().timeIntervalSince1970
        let workspaceID = UUID().uuidString
        let projectID = UUID().uuidString
        let boardID = UUID().uuidString

        try execute(
            "INSERT INTO workspace (id, name, sort_order, created_at) VALUES (?, ?, ?, ?);",
            [workspaceID, "Personal", 1_000.0, now]
        )
        try execute(
            """
            INSERT INTO project (id, workspace_id, name, key, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [projectID, workspaceID, "Work", "WORK", 1_000.0, now]
        )
        try execute(
            "INSERT INTO board (id, project_id, name, sort_order, created_at) VALUES (?, ?, ?, ?, ?);",
            [boardID, projectID, "Board", 1_000.0, now]
        )
        // Since schema 6 every card has a home list, and `createProject` makes
        // one — so a hand-seeded project without one is a shape the app cannot
        // actually produce. Skipped on a database deliberately held at an
        // earlier version, which the migration tests do.
        if try hasTable("list") {
            try execute(
                """
                INSERT INTO list (id, project_id, folder_id, name, sort_order, created_at)
                VALUES (?, ?, NULL, ?, ?, ?);
                """,
                [UUID().uuidString, projectID, "Work", 1_000.0, now]
            )
        }

        var ids: [String] = []
        for (index, starter) in [("To Do", 0), ("In Progress", 1), ("Done", 2)].enumerated() {
            let statusID = UUID().uuidString
            let position = Double(index + 1) * 1_000
            try execute(
                "INSERT INTO status (id, project_id, name, category, sort_order) VALUES (?, ?, ?, ?, ?);",
                [statusID, projectID, starter.0, starter.1, position]
            )
            let columnID = UUID().uuidString
            try execute(
                "INSERT INTO board_column (id, board_id, status_id, name, sort_order) VALUES (?, ?, ?, ?, ?);",
                [columnID, boardID, statusID, starter.0, position]
            )
            try execute(
                "INSERT INTO column_status (column_id, status_id, sort_order) VALUES (?, ?, ?);",
                [columnID, statusID, 1_000.0]
            )
            ids.append(statusID)
        }

        return (workspaceID, projectID, boardID, ids[0], ids[1], ids[2])
    }
}
