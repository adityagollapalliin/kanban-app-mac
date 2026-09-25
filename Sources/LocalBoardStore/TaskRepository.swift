import Foundation
import LocalBoardCore

/// Reads and writes tasks.
///
/// Every mutation that touches more than one row runs in a transaction, and
/// every timestamp comes from the injected clock rather than `Date()`, so the
/// tests can place a task in time without sleeping.
public struct TaskRepository {

    let database: Database
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

    /// The card behind a printed tag: WORK-14 is number 14 of project WORK.
    public func task(number: Int, inProject projectID: String) throws -> BoardTask {
        guard let row = try database.queryOne(
            "SELECT * FROM task WHERE project_id = ? AND number = ?;", [projectID, number]
        ) else {
            throw LocalBoardError.notFound(entity: "card number \(number)")
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

    /// Runs a filter-language query: `due < +7d priority >= high not is:done`.
    ///
    /// Trashed cards are excluded unless the query asks about them, so
    /// `is:trashed` works without a separate switch and every other query
    /// stays clean by default.
    public func tasks(
        matching source: String,
        inProject projectID: String,
        acrossProjects: Bool = false
    ) throws -> [BoardTask] {
        let filter = try TaskQueryParser.parse(source)
        let compiler = TaskQueryCompiler(
            database: database,
            projectID: projectID,
            now: clock.now,
            currentPersonID: try AppSettings(database: database).currentPersonID
        )
        let compiled = try compiler.compile(filter)

        let trashClause = filter.mentionsTrash ? "" : " AND task.trashed = 0"

        // A board defined by a question spans the workspace; every other query
        // is asked of one project. `projectID` is still passed to the compiler
        // either way, because `status = "Doing"` has to resolve somewhere.
        let projectClause = acrossProjects ? "1" : "task.project_id = ?"
        let leading: [SQLValue] = acrossProjects ? [] : [.text(projectID)]

        return try database.query(
            """
            SELECT task.* FROM task
            WHERE \(projectClause) AND \(compiled.whereClause)\(trashClause)
            ORDER BY task.priority DESC,
                     (task.due_date IS NULL),
                     task.due_date,
                     task.updated_at DESC;
            """,
            leading + compiled.parameters
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
        dueDate: Date? = nil,
        listID: String? = nil
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
                                  assignee_id, priority, due_date, sort_order, status_changed_at,
                                  list_id, created_at, updated_at, completed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    id, projectID, statusID, number, type.rawValue, trimmed, descriptionMarkdown,
                    assigneeID.sqlValue, priority.rawValue, dueDate.sqlValue, position, now,
                    // Every card has a home list. Told which, it goes there;
                    // told nothing, it joins the project's first — which on a
                    // file that has never made a second list is the only one.
                    (try listID ?? defaultListID(projectID: projectID)).sqlValue,
                    now, now,
                    // A task created straight into a done column is already done.
                    try isComplete(statusID: statusID) ? now.sqlValue : SQLValue.null,
                ]
            )

            if let assigneeID {
                try database.execute(
                    """
                    INSERT INTO task_assignee (task_id, person_id, estimate, sort_order)
                    VALUES (?, ?, NULL, ?);
                    """,
                    [id, assigneeID, SortOrder.step]
                )
            }

            // The opening entry of the card's history. Without it the first
            // move would look like the card's whole life, and every chart
            // drawn from the history would start a step late.
            try recordStatusChange(taskID: id, from: nil, to: statusID, at: now)

            let created = try task(id: id)
            try AutomationRepository(database: database, clock: clock)
                .run(trigger: .created, task: created, statusID: statusID, depth: 0)
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

    /// The list a new card joins when nobody says. `nil` only on a project
    /// with no lists at all, which the v6 migration made impossible for
    /// existing files and `createProject` makes impossible for new ones.
    func defaultListID(projectID: String) throws -> String? {
        try database.queryOne(
            "SELECT id FROM list WHERE project_id = ? ORDER BY sort_order LIMIT 1;", [projectID]
        )?.string("id")
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
        try move(taskID, toStatus: statusID, after: after, before: before, automationDepth: 0)
    }

    /// The real move. `automationDepth` is how many rules deep this already
    /// is, so a rule that moves a card cannot set off an endless cascade.
    @discardableResult
    func move(
        _ taskID: String,
        toStatus statusID: String,
        after: String? = nil,
        before: String? = nil,
        automationDepth: Int
    ) throws -> BoardTask {
        try database.transaction {
            let moving = try task(id: taskID)

            // The one rule in the app that refuses rather than reports. A WIP
            // limit is an agreement between people and the board is not party
            // to it; an allowed-transition list exists precisely so that some
            // moves are impossible, and a rule that only tutted would not be
            // that.
            if moving.statusID != statusID {
                let workflow = WorkflowRepository(database: database, clock: clock)
                guard try workflow.permits(
                    from: moving.statusID, to: statusID, inProject: moving.projectID
                ) else {
                    throw LocalBoardError.invalidInput(
                        field: "status",
                        detail: "\(try name(ofStatus: moving.statusID)) does not lead to "
                              + "\(try name(ofStatus: statusID)) in this project."
                    )
                }
            }

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

            // Reordering within a column is not a status change. Only a real
            // crossing restarts the column clock and earns a history row —
            // otherwise dragging a card up its own column would reset how long
            // it has been stuck there, which is exactly the thing the dots are
            // meant to make visible.
            let changedColumn = moving.statusID != statusID
            let columnSince: SQLValue = changedColumn
                ? now.sqlValue
                : (moving.statusChangedAt ?? moving.createdAt).sqlValue

            try database.execute(
                """
                UPDATE task SET status_id = ?, sort_order = ?, updated_at = ?, completed_at = ?,
                                status_changed_at = ?
                WHERE id = ?;
                """,
                [statusID, SortOrder.between(lower, upper), now, completedAt, columnSince, taskID]
            )

            if changedColumn {
                try recordStatusChange(taskID: taskID, from: moving.statusID, to: statusID, at: now)

                // A card that recurs on completion produces its next one here,
                // where "finished" actually happens — not on a timer that
                // would have to work out afterwards that it had.
                if destinationIsDone, moving.completedAt == nil {
                    try RecurrenceRepository(database: database, clock: clock).completed(taskID, at: now)
                }

                let moved = try task(id: taskID)
                let automations = AutomationRepository(database: database, clock: clock)

                // Rules run inside the same transaction as the move, so a card
                // never briefly exists in the state a rule was meant to stop.
                try automations.run(
                    trigger: .statusChanged, task: moved, statusID: statusID, depth: automationDepth
                )

                // Finishing a subtask may have finished its parent's list.
                if let parentID = moved.parentID, try automations.allSubtasksDone(of: parentID) {
                    try automations.run(
                        trigger: .allSubtasksDone,
                        task: try task(id: parentID),
                        statusID: nil,
                        depth: automationDepth
                    )
                }
            }
            return try task(id: taskID)
        }
    }

    private func name(ofStatus statusID: String) throws -> String {
        try database.queryOne("SELECT name FROM status WHERE id = ?;", [statusID])?
            .string("name") ?? "That column"
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
    ///
    /// `trashed_at` is stamped here and cleared on the way back, because it is
    /// what the thirty-day purge counts from: `updated_at` moves when the
    /// trashing itself is recorded and so cannot answer "how long has this
    /// been in the bin".
    public func setTrashed(_ trashed: Bool, for taskID: String) throws {
        try update(taskID, "trashed = ?, trashed_at = ?", [trashed, trashed ? clock.now.sqlValue : SQLValue.null])
    }

    /// Marks a card as blocked, with the reason in the user's own words.
    ///
    /// Separate from priority on purpose: priority is how much the work
    /// matters, a flag is what is standing in its way. A card can be both
    /// low-priority and blocked, and conflating them loses one of them.
    public func setFlag(_ flagged: Bool, reason: String = "", for taskID: String) throws {
        // Unflagging clears the reason. A stale explanation attached to a card
        // that is no longer blocked is worse than none.
        let text = flagged ? reason.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        try update(taskID, "flagged = ?, flag_reason = ?", [flagged, text])
    }

    public func setEstimate(_ estimate: Double?, for taskID: String) throws {
        try update(taskID, "estimate = ?", [estimate.sqlValue])
    }

    public func setVersion(_ versionID: String?, for taskID: String) throws {
        try update(taskID, "version_id = ?", [versionID.sqlValue])
    }

    public func setStartDate(_ start: Date?, for taskID: String) throws {
        try update(taskID, "start_date = ?", [start.sqlValue])
    }

    // MARK: - History

    /// Appends one entry to a card's journey. Caller holds the transaction.
    func recordStatusChange(taskID: String, from: String?, to: String, at moment: Date) throws {
        try database.execute(
            """
            INSERT INTO status_change (id, task_id, from_status_id, to_status_id, at)
            VALUES (?, ?, ?, ?, ?);
            """,
            [UUID().uuidString, taskID, from.sqlValue, to, moment]
        )
    }

    /// A card's moves, oldest first.
    public func history(ofTask taskID: String) throws -> [StatusChange] {
        try database.query(
            "SELECT * FROM status_change WHERE task_id = ? ORDER BY at;", [taskID]
        ).map(StatusChange.init(row:))
    }

    /// One field, plus the `updated_at` stamp every edit owes.
    func update(_ taskID: String, _ assignment: String, _ values: [SQLValueConvertible]) throws {
        let changed = try database.execute(
            "UPDATE task SET \(assignment), updated_at = ? WHERE id = ?;",
            values + [clock.now, taskID]
        )
        guard changed > 0 else {
            throw LocalBoardError.notFound(entity: "task \(taskID)")
        }
    }
}
