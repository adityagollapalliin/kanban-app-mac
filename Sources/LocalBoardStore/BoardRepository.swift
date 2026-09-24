import Foundation
import LocalBoardCore

/// A board and everything needed to draw it, read in one pass.
///
/// The view is handed a value, not a cursor: by the time it renders, the
/// database work is finished and nothing it touches can fail.
public struct BoardSnapshot: Sendable, Equatable, Identifiable {
    public let board: Board
    public let columns: [LoadedColumn]

    public var id: String { board.id }
    public var taskCount: Int { columns.reduce(0) { $0 + $1.tasks.count } }

    public init(board: Board, columns: [LoadedColumn]) {
        self.board = board
        self.columns = columns
    }
}

/// One column with the status behind it and the cards in it.
public struct LoadedColumn: Sendable, Equatable, Identifiable {
    public let column: BoardColumn
    public let status: Status
    public let tasks: [BoardTask]

    public var id: String { column.id }
    public var name: String { column.name }

    /// Reported, never enforced. The board says the limit is exceeded; it does
    /// not refuse the drop that exceeded it.
    public var isOverWIPLimit: Bool {
        guard let limit = column.wipLimit else { return false }
        return tasks.count > limit
    }

    public init(column: BoardColumn, status: Status, tasks: [BoardTask]) {
        self.column = column
        self.status = status
        self.tasks = tasks
    }
}

/// Reads the board structure: workspaces, projects, boards and their columns.
public struct BoardRepository {

    private let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - The sidebar

    public func workspaces() throws -> [Workspace] {
        try database.query("SELECT * FROM workspace ORDER BY sort_order;").map(Workspace.init(row:))
    }

    public func projects(inWorkspace workspaceID: String, includeArchived: Bool = false) throws -> [Project] {
        let sql = """
            SELECT * FROM project WHERE workspace_id = ?\(includeArchived ? "" : " AND archived = 0")
            ORDER BY sort_order;
            """
        return try database.query(sql, [workspaceID]).map(Project.init(row:))
    }

    public func boards(inProject projectID: String) throws -> [Board] {
        try database.query("SELECT * FROM board WHERE project_id = ? ORDER BY sort_order;", [projectID])
            .map(Board.init(row:))
    }

    public func statuses(inProject projectID: String) throws -> [Status] {
        try database.query("SELECT * FROM status WHERE project_id = ? ORDER BY sort_order;", [projectID])
            .map(Status.init(row:))
    }

    // MARK: - The board

    /// Everything one board needs, in a handful of queries rather than one per
    /// column: the columns come back in a single join, the cards in a single
    /// pass over the project's tasks, grouped in memory.
    public func snapshot(boardID: String, includeTrashed: Bool = false) throws -> BoardSnapshot {
        guard let boardRow = try database.queryOne("SELECT * FROM board WHERE id = ?;", [boardID]) else {
            throw LocalBoardError.notFound(entity: "board \(boardID)")
        }
        let board = try Board(row: boardRow)

        // The column carries its own name and the status carries the category,
        // so both are aliased out of one join rather than fetched separately.
        let columnRows = try database.query(
            """
            SELECT board_column.id          AS column_id,
                   board_column.board_id    AS board_id,
                   board_column.status_id   AS status_id,
                   board_column.name        AS column_name,
                   board_column.wip_limit   AS wip_limit,
                   board_column.sort_order  AS column_sort_order,
                   status.project_id        AS status_project_id,
                   status.name              AS status_name,
                   status.category          AS status_category,
                   status.sort_order        AS status_sort_order
            FROM board_column
            JOIN status ON status.id = board_column.status_id
            WHERE board_column.board_id = ?
            ORDER BY board_column.sort_order;
            """,
            [boardID]
        )

        let tasksByStatus = try tasksGroupedByStatus(
            projectID: board.projectID,
            includeTrashed: includeTrashed
        )

        let columns = try columnRows.map { row -> LoadedColumn in
            let statusID = try row.requiredString("status_id")
            let column = BoardColumn(
                id: try row.requiredString("column_id"),
                boardID: try row.requiredString("board_id"),
                statusID: statusID,
                name: try row.requiredString("column_name"),
                wipLimit: row.int("wip_limit").map(Int.init),
                sortOrder: try row.requiredDouble("column_sort_order")
            )
            let status = Status(
                id: statusID,
                projectID: try row.requiredString("status_project_id"),
                name: try row.requiredString("status_name"),
                category: try row.requiredEnum("status_category", StatusCategory.self),
                sortOrder: try row.requiredDouble("status_sort_order")
            )
            return LoadedColumn(column: column, status: status, tasks: tasksByStatus[statusID] ?? [])
        }

        return BoardSnapshot(board: board, columns: columns)
    }

    /// One query for the whole project's cards, grouped by status. A board with
    /// nine columns costs the same as a board with one.
    private func tasksGroupedByStatus(
        projectID: String,
        includeTrashed: Bool
    ) throws -> [String: [BoardTask]] {
        var grouped: [String: [BoardTask]] = [:]
        try database.forEachRow(
            """
            SELECT * FROM task
            WHERE project_id = ?\(includeTrashed ? "" : " AND trashed = 0")
            ORDER BY status_id, sort_order;
            """,
            [projectID]
        ) { row in
            let task = try BoardTask(row: row)
            grouped[task.statusID, default: []].append(task)
        }
        return grouped
    }

    // MARK: - First run

    /// Creates a workspace, project, statuses, board and columns if the file is
    /// empty, and returns the board to open. On an existing file it finds the
    /// first board instead and writes nothing.
    ///
    /// Idempotent by design: it runs on every launch, because "is this the
    /// first launch" is a question about the data, not about a flag somewhere
    /// that can disagree with it.
    @discardableResult
    public func ensureStarterContent() throws -> Board? {
        try database.transaction {
            if let existing = try database.queryOne("SELECT * FROM board ORDER BY sort_order LIMIT 1;") {
                return try Board(row: existing)
            }
            guard try database.count("SELECT COUNT(*) FROM workspace;") == 0 else {
                // Someone has already made a workspace and removed its boards.
                // That is a deliberate state; leave it alone.
                return nil
            }
            return try seedStarterContent()
        }
    }

    private func seedStarterContent() throws -> Board {
        let now = clock.now
        let workspaceID = UUID().uuidString
        let projectID = UUID().uuidString
        let boardID = UUID().uuidString

        try database.execute(
            "INSERT INTO workspace (id, name, sort_order, created_at) VALUES (?, ?, ?, ?);",
            [workspaceID, "Personal", SortOrder.step, now]
        )
        try database.execute(
            """
            INSERT INTO project (id, workspace_id, name, key, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [projectID, workspaceID, "My Project", "TASK", SortOrder.step, now]
        )
        try database.execute(
            "INSERT INTO board (id, project_id, name, sort_order, created_at) VALUES (?, ?, ?, ?, ?);",
            [boardID, projectID, "Board", SortOrder.step, now]
        )

        // The three columns every Kanban board starts with. The categories are
        // what make "done" mean something to the rest of the app.
        let starters: [(name: String, category: StatusCategory)] = [
            ("To Do", .toDo),
            ("In Progress", .inProgress),
            ("Done", .done),
        ]

        for (index, starter) in starters.enumerated() {
            let statusID = UUID().uuidString
            let position = Double(index + 1) * SortOrder.step
            try database.execute(
                "INSERT INTO status (id, project_id, name, category, sort_order) VALUES (?, ?, ?, ?, ?);",
                [statusID, projectID, starter.name, starter.category.rawValue, position]
            )
            try database.execute(
                """
                INSERT INTO board_column (id, board_id, status_id, name, sort_order)
                VALUES (?, ?, ?, ?, ?);
                """,
                [UUID().uuidString, boardID, statusID, starter.name, position]
            )
        }

        guard let row = try database.queryOne("SELECT * FROM board WHERE id = ?;", [boardID]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The starter board was not written.")
        }
        return try Board(row: row)
    }
}
