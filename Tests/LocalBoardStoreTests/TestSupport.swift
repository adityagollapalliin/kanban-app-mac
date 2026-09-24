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
