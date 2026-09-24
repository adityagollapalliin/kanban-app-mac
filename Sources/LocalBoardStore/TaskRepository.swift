import Foundation
import LocalBoardCore

/// Reads and writes tasks.
///
/// Every mutation that touches more than one row runs in a transaction, and
/// every timestamp comes from the injected clock rather than `Date()`, so the
/// tests can place a task in time without sleeping.
public struct TaskRepository {

    private let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - Reading

    /// One column's tasks, in board order. Trashed tasks are excluded: they
    /// stay on disk but leave every board query, which is what makes the trash
    /// recoverable rather than a delete.
    public func tasks(
        inProject projectID: String,
        statusID: String,
        includeTrashed: Bool = false
    ) throws -> [BoardTask] {
        let sql = """
            SELECT * FROM task
            WHERE project_id = ? AND status_id = ?\(includeTrashed ? "" : " AND trashed = 0")
            ORDER BY sort_order;
            """
        return try database.query(sql, [projectID, statusID]).map(BoardTask.init(row:))
    }

    public func task(id: String) throws -> BoardTask {
        guard let row = try database.queryOne("SELECT * FROM task WHERE id = ?;", [id]) else {
            throw LocalBoardError.notFound(entity: "task \(id)")
        }
        return try BoardTask(row: row)
    }

    /// Full-text search across titles and descriptions, newest-relevance first.
    public func search(inProject projectID: String, matching text: String) throws -> [BoardTask] {
        let expression = Self.ftsExpression(for: text)
        guard !expression.isEmpty else { return [] }

        return try database.query(
            """
            SELECT task.* FROM task_fts
            JOIN task ON task.rowid = task_fts.rowid
            WHERE task_fts MATCH ? AND task.project_id = ? AND task.trashed = 0
            ORDER BY rank;
            """,
            [expression, projectID]
        ).map(BoardTask.init(row:))
    }

    /// Turns what the user typed into an FTS5 expression.
    ///
    /// Each word becomes a quoted prefix term, so `"` and the operators FTS5
    /// reads (`NEAR`, `-`, `*`, `:`) cannot change the shape of the query. The
    /// value is still bound, never interpolated; this is about the expression
    /// grammar inside the bound string, which binding does not cover.
    static func ftsExpression(for text: String) -> String {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\"\($0)\"*" }
            .joined(separator: " ")
    }

    // MARK: - Creating

    /// Adds a task to the end of its column.
    ///
    /// The per-project number is allocated inside the transaction, so two adds
    /// racing from the app and the CLI cannot be handed the same one — the
    /// `UNIQUE (project_id, number)` constraint would reject the second anyway,
    /// but this way neither has to retry.
    @discardableResult
    public func create(
        inProject projectID: String,
        statusID: String,
        title: String,
        type: TaskType = .task,
        priority: Priority = .normal,
        descriptionMarkdown: String = "",
        assigneeID: String? = nil,
        dueDate: Date? = nil
    ) throws -> BoardTask {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "title", detail: "A task needs a title.")
        }

        return try database.transaction {
            let number = try allocateTaskNumber(projectID: projectID)
            let position = SortOrder.between(try lastPosition(projectID: projectID, statusID: statusID), nil)
            let now = clock.now
            let id = UUID().uuidString

            try database.execute(
                """
                INSERT INTO task (id, project_id, status_id, number, type, title, description_md,
                                  assignee_id, priority, due_date, sort_order, created_at, updated_at,
                                  completed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    id, projectID, statusID, number, type.rawValue, trimmed, descriptionMarkdown,
                    assigneeID.sqlValue, priority.rawValue, dueDate.sqlValue, position, now, now,
                    // A task created straight into a done column is already done.
                    try isComplete(statusID: statusID) ? now.sqlValue : SQLValue.null,
                ]
            )
            return try task(id: id)
        }
    }

    /// Claims the next number and advances the counter. Caller holds the
    /// transaction.
    private func allocateTaskNumber(projectID: String) throws -> Int {
        guard let row = try database.queryOne(
            "SELECT next_task_number FROM project WHERE id = ?;", [projectID]
        ), let number = row.int("next_task_number") else {
            throw LocalBoardError.notFound(entity: "project \(projectID)")
        }
        try database.execute(
            "UPDATE project SET next_task_number = next_task_number + 1 WHERE id = ?;", [projectID]
        )
        return Int(number)
    }

    private func lastPosition(projectID: String, statusID: String) throws -> Double? {
        try database.queryOne(
            """
            SELECT MAX(sort_order) AS last FROM task
            WHERE project_id = ? AND status_id = ? AND trashed = 0;
            """,
            [projectID, statusID]
        )?.double("last")
    }

    private func isComplete(statusID: String) throws -> Bool {
        guard let row = try database.queryOne("SELECT category FROM status WHERE id = ?;", [statusID]),
              let raw = row.int("category") else {
            throw LocalBoardError.notFound(entity: "status \(statusID)")
        }
        return StatusCategory(rawValue: Int(raw))?.isComplete ?? false
    }

    // MARK: - Moving

    /// Drops a task into a column between two neighbours, either of which may
    /// be `nil` for the ends of the list.
    ///
    /// Moving into a done column stamps `completed_at`; moving back out clears
    /// it. That keeps "when was this finished" answerable from the row itself
    /// rather than from an audit trail the schema does not have.
    @discardableResult
    public func move(
        _ taskID: String,
        toStatus statusID: String,
        after: String? = nil,
        before: String? = nil
    ) throws -> BoardTask {
        try database.transaction {
            let moving = try task(id: taskID)

            var lower = try after.map { try position(of: $0) }
            var upper = try before.map { try position(of: $0) }

            // Spread the column out first if the gap can no longer be split,
            // then read the neighbours again: rebalancing moved them.
            if SortOrder.needsRebalance(lower, upper) {
                try rebalance(projectID: moving.projectID, statusID: statusID, excluding: taskID)
                lower = try after.map { try position(of: $0) }
                upper = try before.map { try position(of: $0) }
            }

            let now = clock.now
            let destinationIsDone = try isComplete(statusID: statusID)
            let completedAt: SQLValue = destinationIsDone
                ? (moving.completedAt ?? now).sqlValue
                : .null

            try database.execute(
                """
                UPDATE task SET status_id = ?, sort_order = ?, updated_at = ?, completed_at = ?
                WHERE id = ?;
                """,
                [statusID, SortOrder.between(lower, upper), now, completedAt, taskID]
            )
            return try task(id: taskID)
        }
    }

    private func position(of taskID: String) throws -> Double {
        guard let row = try database.queryOne("SELECT sort_order FROM task WHERE id = ?;", [taskID]),
              let value = row.double("sort_order") else {
            throw LocalBoardError.notFound(entity: "task \(taskID)")
        }
        return value
    }

    /// Respaces a column so midpoints are splittable again. The moving task is
    /// left out because it is about to be given a position of its own.
    private func rebalance(projectID: String, statusID: String, excluding taskID: String?) throws {
        let ordered = try tasks(inProject: projectID, statusID: statusID)
            .filter { $0.id != taskID }
        let positions = SortOrder.rebalanced(count: ordered.count)

        for (task, position) in zip(ordered, positions) {
            try database.execute("UPDATE task SET sort_order = ? WHERE id = ?;", [position, task.id])
        }
    }

    // MARK: - Editing

    public func setTitle(_ title: String, for taskID: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "title", detail: "A task needs a title.")
        }
        try update(taskID, "title = ?", [trimmed])
    }

    public func setDescription(_ markdown: String, for taskID: String) throws {
        try update(taskID, "description_md = ?", [markdown])
    }

    public func setType(_ type: TaskType, for taskID: String) throws {
        try update(taskID, "type = ?", [type.rawValue])
    }

    public func setPriority(_ priority: Priority, for taskID: String) throws {
        try update(taskID, "priority = ?", [priority.rawValue])
    }

    public func setAssignee(_ personID: String?, for taskID: String) throws {
        try update(taskID, "assignee_id = ?", [personID.sqlValue])
    }

    public func setDueDate(_ due: Date?, for taskID: String) throws {
        try update(taskID, "due_date = ?", [due.sqlValue])
    }

    /// Trashing hides a task from every board. The row stays, so it can come
    /// back with its history, its number and its place intact.
    public func setTrashed(_ trashed: Bool, for taskID: String) throws {
        try update(taskID, "trashed = ?", [trashed])
    }

    /// One field, plus the `updated_at` stamp every edit owes.
    private func update(_ taskID: String, _ assignment: String, _ values: [SQLValueConvertible]) throws {
        let changed = try database.execute(
            "UPDATE task SET \(assignment), updated_at = ? WHERE id = ?;",
            values + [clock.now, taskID]
        )
        guard changed > 0 else {
            throw LocalBoardError.notFound(entity: "task \(taskID)")
        }
    }
}
