import Foundation
import LocalBoardCore

/// A board and everything needed to draw it, read in one pass.
///
/// The view is handed a value, not a cursor: by the time it renders, the
/// database work is finished and nothing it touches can fail.
public struct BoardSnapshot: Sendable, Equatable, Identifiable {
    public let board: Board
    public let columns: [LoadedColumn]

    /// The column cards wait in before anyone has committed to them. Kept out
    /// of `columns` so the board proper shows work in flight and nothing else;
    /// it has its own screen.
    public let backlog: LoadedColumn?

    /// What each card carries, keyed by card id. Gathered in one query each
    /// rather than per card, so a board of two hundred cards costs the same
    /// handful of statements as a board of two.
    public let labels: [String: [CardLabel]]
    public let checklists: [String: ChecklistProgress]
    public let subtasks: [String: ChecklistProgress]

    public var id: String { board.id }
    public var taskCount: Int { columns.reduce(0) { $0 + $1.tasks.count } }

    public init(
        board: Board,
        columns: [LoadedColumn],
        backlog: LoadedColumn? = nil,
        labels: [String: [CardLabel]] = [:],
        checklists: [String: ChecklistProgress] = [:],
        subtasks: [String: ChecklistProgress] = [:]
    ) {
        self.board = board
        self.columns = columns
        self.backlog = backlog
        self.labels = labels
        self.checklists = checklists
        self.subtasks = subtasks
    }
}

/// One column, the statuses it gathers, and the cards standing in them.
///
/// A column is not a status. It shows *several*, which is what lets "In
/// Review" and "In Progress" share one heading on a board that thinks of them
/// as one step and stand apart on a board that does not — from the same data,
/// without either board rewriting the other's.
public struct LoadedColumn: Sendable, Equatable, Identifiable {
    public let column: BoardColumn
    /// Where a card dropped on this column lands. One of `statuses`.
    public let status: Status
    /// Everything the column gathers, the drop target first.
    public let statuses: [Status]
    public let tasks: [BoardTask]

    public var id: String { column.id }
    public var name: String { column.name }

    /// What the column's limit is counting: cards, or the points on them.
    ///
    /// Unestimated cards contribute nothing to a points measure. That is a
    /// real hole rather than a rounding choice, and the header says so by
    /// showing the count alongside.
    public var wipAmount: Double {
        switch column.wipMeasure {
        case .cardCount: Double(tasks.count)
        case .estimate: tasks.reduce(0) { $0 + ($1.estimate ?? 0) }
        }
    }

    public var wipState: WIPState { column.state(for: wipAmount) }

    /// Reported, never enforced. The board says the limit is exceeded; it does
    /// not refuse the drop that exceeded it.
    public var isOverWIPLimit: Bool { wipState == .breached }

    /// How many cards carry no estimate, when points are what is being counted.
    public var unestimatedCount: Int {
        column.wipMeasure == .estimate ? tasks.count { $0.estimate == nil } : 0
    }

    public init(column: BoardColumn, status: Status, statuses: [Status] = [], tasks: [BoardTask]) {
        self.column = column
        self.status = status
        self.statuses = statuses.isEmpty ? [status] : statuses
        self.tasks = tasks
    }
}

/// Reads the board structure: workspaces, projects, boards and their columns.
public struct BoardRepository {

    let database: Database
    private let clock: any ClockProvider

    /// The clock, for the editing extension in BoardRepository+Editing.
    var clockNow: Date { clock.now }

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
    /// column: the columns and their statuses come back in one join, the cards
    /// in a single pass, grouped in memory.
    public func snapshot(boardID: String, includeTrashed: Bool = false) throws -> BoardSnapshot {
        guard let boardRow = try database.queryOne("SELECT * FROM board WHERE id = ?;", [boardID]) else {
            throw LocalBoardError.notFound(entity: "board \(boardID)")
        }
        let board = try Board(row: boardRow)

        let columns = try loadColumns(boardID: boardID)

        let tasks = try board.isQueryBoard
            ? tasksMatchingBoardQuery(board)
            : allTasks(projectID: board.projectID, includeTrashed: includeTrashed)

        // Which column a card belongs to. A card whose status this board does
        // not show has nowhere to go and is left off rather than guessed at —
        // except on a query board, where cards arrive from other projects and
        // the shared vocabulary is the category rather than the status itself.
        var columnForStatus: [String: Int] = [:]
        for (index, column) in columns.enumerated() {
            for status in column.statuses { columnForStatus[status.id] = index }
        }
        var firstColumnOfCategory: [StatusCategory: Int] = [:]
        for (index, column) in columns.enumerated() where firstColumnOfCategory[column.status.category] == nil {
            firstColumnOfCategory[column.status.category] = index
        }

        let categoryOfStatus = try statusCategories()
        var grouped: [Int: [BoardTask]] = [:]
        for task in tasks {
            let index: Int?
            if let mapped = columnForStatus[task.statusID] {
                index = mapped
            } else if board.isQueryBoard, let category = categoryOfStatus[task.statusID] {
                index = firstColumnOfCategory[category]
            } else {
                index = nil
            }
            guard let index else { continue }
            grouped[index, default: []].append(task)
        }

        let filled = columns.enumerated().map { index, column in
            LoadedColumn(
                column: column.column,
                status: column.status,
                statuses: column.statuses,
                // Sparse ordering is per column, and a column now gathers
                // several; sorting here is what keeps two statuses under one
                // heading from interleaving by accident.
                tasks: (grouped[index] ?? []).sorted { $0.sortOrder < $1.sortOrder }
            )
        }

        let projectID = board.projectID
        return BoardSnapshot(
            board: board,
            columns: filled.filter { !$0.column.isBacklog },
            backlog: filled.first { $0.column.isBacklog },
            labels: try LabelRepository(database: database).labelsByTask(inProject: projectID),
            checklists: try ChecklistRepository(database: database).progressByTask(inProject: projectID),
            subtasks: try TaskRepository(database: database).subtaskProgress(inProject: projectID)
        )
    }

    /// The board's columns with every status each one gathers.
    ///
    /// Two queries rather than one join, because a column with three statuses
    /// would otherwise come back three times and have to be de-duplicated in
    /// exactly the order the join happened to produce.
    private func loadColumns(boardID: String) throws -> [LoadedColumn] {
        let columnRows = try database.query(
            "SELECT * FROM board_column WHERE board_id = ? ORDER BY sort_order;", [boardID]
        )
        guard !columnRows.isEmpty else { return [] }

        var statusesByColumn: [String: [Status]] = [:]
        try database.forEachRow(
            """
            SELECT column_status.column_id AS column_id, status.*
            FROM column_status
            JOIN status ON status.id = column_status.status_id
            JOIN board_column ON board_column.id = column_status.column_id
            WHERE board_column.board_id = ?
            ORDER BY column_status.sort_order;
            """,
            [boardID]
        ) { row in
            statusesByColumn[try row.requiredString("column_id"), default: []].append(try Status(row: row))
        }

        return try columnRows.map { row in
            let column = try BoardColumn(row: row)
            var statuses = statusesByColumn[column.id] ?? []

            // The drop target leads, whatever order the mapping is in: it is
            // the column's own status, and the header names it first.
            if let targetIndex = statuses.firstIndex(where: { $0.id == column.statusID }), targetIndex != 0 {
                statuses.insert(statuses.remove(at: targetIndex), at: 0)
            }

            guard let target = statuses.first else {
                // A column with no mapping row at all predates v3 and was
                // missed by the backfill. Read its own status directly rather
                // than dropping the column and the cards standing in it.
                guard let statusRow = try database.queryOne(
                    "SELECT * FROM status WHERE id = ?;", [column.statusID]
                ) else {
                    throw LocalBoardError.notFound(entity: "status \(column.statusID)")
                }
                let status = try Status(row: statusRow)
                return LoadedColumn(column: column, status: status, statuses: [status], tasks: [])
            }

            return LoadedColumn(column: column, status: target, statuses: statuses, tasks: [])
        }
    }

    private func statusCategories() throws -> [String: StatusCategory] {
        var categories: [String: StatusCategory] = [:]
        try database.forEachRow("SELECT id, category FROM status;") { row in
            categories[try row.requiredString("id")] = try row.requiredEnum("category", StatusCategory.self)
        }
        return categories
    }

    /// One query for the whole project's cards. A board with nine columns
    /// costs the same as a board with one.
    private func allTasks(projectID: String, includeTrashed: Bool) throws -> [BoardTask] {
        try database.query(
            """
            SELECT * FROM task
            WHERE project_id = ?\(includeTrashed ? "" : " AND trashed = 0")
            ORDER BY status_id, sort_order;
            """,
            [projectID]
        ).map(BoardTask.init(row:))
    }

    /// A board defined by a question gathers whatever answers it, from any
    /// project in the workspace rather than from one.
    ///
    /// A query that no longer parses is not allowed to blank the board: the
    /// board falls back to its own project, and the failure surfaces where the
    /// query is edited rather than as an empty screen with no explanation.
    private func tasksMatchingBoardQuery(_ board: Board) throws -> [BoardTask] {
        let repository = TaskRepository(database: database, clock: clock)
        do {
            return try repository.tasks(matching: board.filterQuery, inProject: board.projectID, acrossProjects: true)
        } catch is QueryError {
            return try allTasks(projectID: board.projectID, includeTrashed: false)
        }
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
            let columnID = UUID().uuidString
            try database.execute(
                """
                INSERT INTO board_column (id, board_id, status_id, name, sort_order)
                VALUES (?, ?, ?, ?, ?);
                """,
                [columnID, boardID, statusID, starter.name, position]
            )
            try database.execute(
                "INSERT INTO column_status (column_id, status_id, sort_order) VALUES (?, ?, ?);",
                [columnID, statusID, SortOrder.step]
            )
        }

        try BoardPresentationRepository(database: database).seedDefaults(forBoard: boardID)

        guard let row = try database.queryOne("SELECT * FROM board WHERE id = ?;", [boardID]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The starter board was not written.")
        }
        return try Board(row: row)
    }
}
