import Foundation
import LocalBoardCore

/// Reshaping the board: projects, boards and columns.
///
/// A column is two rows — a `status` the cards point at, and a `board_column`
/// placing it on one board. They are created and destroyed together here, so
/// nothing else has to know that the pair exists.
extension BoardRepository {

    // MARK: - Projects

    /// Creates a project with the three columns every board starts with, and a
    /// board to show them on. A project without those is not yet usable, so
    /// making one without them would only be a state to recover from.
    @discardableResult
    public func createProject(
        inWorkspace workspaceID: String,
        name: String,
        key: String
    ) throws -> Project {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A project needs a name.")
        }

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmedKey.isEmpty, trimmedKey.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw LocalBoardError.invalidInput(
                field: "key",
                detail: "A key is letters and digits, like WORK. It goes in front of every card number."
            )
        }

        return try database.transaction {
            let existing = try database.query(
                "SELECT key FROM project WHERE workspace_id = ? AND key = ? COLLATE NOCASE;",
                [workspaceID, trimmedKey]
            )
            guard existing.isEmpty else {
                throw LocalBoardError.invalidInput(
                    field: "key",
                    detail: "This workspace already has a project keyed \(trimmedKey)."
                )
            }

            let projectID = UUID().uuidString
            let now = clockNow
            let last = try database.queryOne(
                "SELECT MAX(sort_order) AS last FROM project WHERE workspace_id = ?;", [workspaceID]
            )?.double("last")

            try database.execute(
                """
                INSERT INTO project (id, workspace_id, name, key, sort_order, created_at)
                VALUES (?, ?, ?, ?, ?, ?);
                """,
                [projectID, workspaceID, trimmedName, trimmedKey, SortOrder.between(last, nil), now]
            )

            let boardID = UUID().uuidString
            try database.execute(
                "INSERT INTO board (id, project_id, name, sort_order, created_at) VALUES (?, ?, ?, ?, ?);",
                [boardID, projectID, "Board", SortOrder.step, now]
            )
            try BoardPresentationRepository(database: database).seedDefaults(forBoard: boardID)

            // Every space starts with one list, because every card needs a
            // home and a space with nowhere to put a card is a state to
            // recover from rather than a state to be in.
            try database.execute(
                """
                INSERT INTO list (id, project_id, folder_id, name, sort_order, created_at)
                VALUES (?, ?, NULL, ?, ?, ?);
                """,
                [UUID().uuidString, projectID, trimmedName, SortOrder.step, now]
            )

            for (index, starter) in [("To Do", StatusCategory.toDo), ("In Progress", .inProgress), ("Done", .done)].enumerated() {
                try insertColumn(
                    boardID: boardID,
                    projectID: projectID,
                    name: starter.0,
                    category: starter.1,
                    position: Double(index + 1) * SortOrder.step
                )
            }

            guard let row = try database.queryOne("SELECT * FROM project WHERE id = ?;", [projectID]) else {
                throw LocalBoardError.databaseQueryFailed(detail: "The project was not written.")
            }
            return try Project(row: row)
        }
    }

    public func renameProject(_ projectID: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A project needs a name.")
        }
        let changed = try database.execute("UPDATE project SET name = ? WHERE id = ?;", [trimmed, projectID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "project \(projectID)") }
    }

    /// Archiving keeps everything and hides the project. Deleting is the
    /// destructive one, and it cascades — which is why the UI asks first.
    public func setArchived(_ archived: Bool, for projectID: String) throws {
        let changed = try database.execute(
            "UPDATE project SET archived = ? WHERE id = ?;", [archived, projectID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "project \(projectID)") }
    }

    public func deleteProject(_ projectID: String) throws {
        let changed = try database.execute("DELETE FROM project WHERE id = ?;", [projectID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "project \(projectID)") }
    }

    // MARK: - Boards

    @discardableResult
    public func createBoard(inProject projectID: String, name: String) throws -> Board {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A board needs a name.")
        }

        return try database.transaction {
            let boardID = UUID().uuidString
            let now = clockNow
            let last = try database.queryOne(
                "SELECT MAX(sort_order) AS last FROM board WHERE project_id = ?;", [projectID]
            )?.double("last")

            try database.execute(
                "INSERT INTO board (id, project_id, name, sort_order, created_at) VALUES (?, ?, ?, ?, ?);",
                [boardID, projectID, trimmed, SortOrder.between(last, nil), now]
            )

            try BoardPresentationRepository(database: database).seedDefaults(forBoard: boardID)

            // A new board over an existing project shows the columns that
            // project already has; a board with none would show nothing.
            for status in try statuses(inProject: projectID) {
                let columnID = UUID().uuidString
                try database.execute(
                    """
                    INSERT INTO board_column (id, board_id, status_id, name, sort_order)
                    VALUES (?, ?, ?, ?, ?);
                    """,
                    [columnID, boardID, status.id, status.name, status.sortOrder]
                )
                try database.execute(
                    "INSERT INTO column_status (column_id, status_id, sort_order) VALUES (?, ?, ?);",
                    [columnID, status.id, SortOrder.step]
                )
            }

            guard let row = try database.queryOne("SELECT * FROM board WHERE id = ?;", [boardID]) else {
                throw LocalBoardError.databaseQueryFailed(detail: "The board was not written.")
            }
            return try Board(row: row)
        }
    }

    public func renameBoard(_ boardID: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A board needs a name.")
        }
        let changed = try database.execute("UPDATE board SET name = ? WHERE id = ?;", [trimmed, boardID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "board \(boardID)") }
    }

    public func deleteBoard(_ boardID: String) throws {
        let changed = try database.execute("DELETE FROM board WHERE id = ?;", [boardID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "board \(boardID)") }
    }

    // MARK: - Columns

    @discardableResult
    public func addColumn(
        toBoard boardID: String,
        name: String,
        category: StatusCategory = .toDo
    ) throws -> BoardColumn {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A column needs a name.")
        }

        return try database.transaction {
            guard let boardRow = try database.queryOne("SELECT * FROM board WHERE id = ?;", [boardID]) else {
                throw LocalBoardError.notFound(entity: "board \(boardID)")
            }
            let board = try Board(row: boardRow)

            let taken = try statuses(inProject: board.projectID)
            guard !taken.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                throw LocalBoardError.invalidInput(
                    field: "name",
                    detail: "This project already has a column called \(trimmed)."
                )
            }

            let last = try database.queryOne(
                "SELECT MAX(sort_order) AS last FROM board_column WHERE board_id = ?;", [boardID]
            )?.double("last")

            let id = try insertColumn(
                boardID: boardID,
                projectID: board.projectID,
                name: trimmed,
                category: category,
                position: SortOrder.between(last, nil)
            )

            guard let row = try database.queryOne("SELECT * FROM board_column WHERE id = ?;", [id]) else {
                throw LocalBoardError.databaseQueryFailed(detail: "The column was not written.")
            }
            return try BoardColumn(row: row)
        }
    }

    /// Writes the status/column pair. Caller holds the transaction.
    @discardableResult
    private func insertColumn(
        boardID: String,
        projectID: String,
        name: String,
        category: StatusCategory,
        position: Double
    ) throws -> String {
        let statusID = UUID().uuidString
        let columnID = UUID().uuidString

        try database.execute(
            "INSERT INTO status (id, project_id, name, category, sort_order) VALUES (?, ?, ?, ?, ?);",
            [statusID, projectID, name, category.rawValue, position]
        )
        try database.execute(
            "INSERT INTO board_column (id, board_id, status_id, name, sort_order) VALUES (?, ?, ?, ?, ?);",
            [columnID, boardID, statusID, name, position]
        )
        // The mapping row is what the board actually reads. `status_id` on the
        // column stays as the drop target; this is the set of statuses the
        // column gathers, which for a brand-new column is just the one.
        try database.execute(
            "INSERT INTO column_status (column_id, status_id, sort_order) VALUES (?, ?, ?);",
            [columnID, statusID, SortOrder.step]
        )
        return columnID
    }

    // MARK: - Statuses under one column

    /// Folds a status into a column, so two statuses share one heading.
    ///
    /// This is the point of separating columns from statuses: "In Review" and
    /// "In Progress" can be one "Doing" column for the team that works that
    /// way and two for the team that does not, from the same project.
    ///
    /// If the status currently has a column of its own on this board, that
    /// column is removed — not the status, and not its cards. Merging two
    /// columns is exactly what the user asked for, and leaving the old heading
    /// behind showing nothing would be a leftover rather than a result.
    public func mapStatus(_ statusID: String, toColumn columnID: String) throws {
        try database.transaction {
            guard let columnRow = try database.queryOne(
                "SELECT * FROM board_column WHERE id = ?;", [columnID]
            ) else {
                throw LocalBoardError.notFound(entity: "column \(columnID)")
            }
            let column = try BoardColumn(row: columnRow)

            guard column.statusID != statusID else { return }

            // The status's own column on this board, if it has one.
            let existing = try database.query(
                """
                SELECT board_column.id AS id, board_column.status_id AS status_id
                FROM column_status
                JOIN board_column ON board_column.id = column_status.column_id
                WHERE board_column.board_id = ? AND column_status.status_id = ?
                  AND column_status.column_id != ?;
                """,
                [column.boardID, statusID, columnID]
            )

            for row in existing {
                let otherID = try row.requiredString("id")
                // Only a column whose *own* status this is can be dissolved.
                // A column gathering it alongside others is a deliberate
                // arrangement somebody made, and taking it apart is not what
                // was asked for.
                guard row.string("status_id") == statusID else {
                    throw LocalBoardError.invalidInput(
                        field: "status",
                        detail: "That status is already gathered by another column on this board."
                    )
                }
                try database.execute("DELETE FROM board_column WHERE id = ?;", [otherID])
            }

            let last = try database.queryOne(
                "SELECT MAX(sort_order) AS last FROM column_status WHERE column_id = ?;", [columnID]
            )?.double("last")

            try database.execute(
                """
                INSERT INTO column_status (column_id, status_id, sort_order) VALUES (?, ?, ?)
                ON CONFLICT (column_id, status_id) DO NOTHING;
                """,
                [columnID, statusID, SortOrder.between(last, nil)]
            )
        }
    }

    /// Splits a status back out of a column, giving it a column of its own.
    ///
    /// The new column goes on the end rather than nowhere: a status with no
    /// column on this board would take its cards off the board with it, and
    /// unmerging is meant to undo a merge, not to hide work.
    ///
    /// A column's own status cannot be split off — that would leave the column
    /// with nowhere for a drop to land, and the thing being asked for is
    /// really "delete this column".
    public func unmapStatus(_ statusID: String, fromColumn columnID: String) throws {
        try database.transaction {
            guard let columnRow = try database.queryOne(
                "SELECT * FROM board_column WHERE id = ?;", [columnID]
            ) else {
                throw LocalBoardError.notFound(entity: "column \(columnID)")
            }
            let column = try BoardColumn(row: columnRow)

            guard column.statusID != statusID else {
                throw LocalBoardError.invalidInput(
                    field: "status",
                    detail: "\(column.name) is where cards dropped here land. Delete the column instead."
                )
            }

            guard let statusRow = try database.queryOne(
                "SELECT * FROM status WHERE id = ?;", [statusID]
            ) else {
                throw LocalBoardError.notFound(entity: "status \(statusID)")
            }
            let status = try Status(row: statusRow)

            try database.execute(
                "DELETE FROM column_status WHERE column_id = ? AND status_id = ?;", [columnID, statusID]
            )

            let last = try database.queryOne(
                "SELECT MAX(sort_order) AS last FROM board_column WHERE board_id = ?;", [column.boardID]
            )?.double("last")
            let newColumnID = UUID().uuidString

            try database.execute(
                "INSERT INTO board_column (id, board_id, status_id, name, sort_order) VALUES (?, ?, ?, ?, ?);",
                [newColumnID, column.boardID, statusID, status.name, SortOrder.between(last, nil)]
            )
            try database.execute(
                "INSERT INTO column_status (column_id, status_id, sort_order) VALUES (?, ?, ?);",
                [newColumnID, statusID, SortOrder.step]
            )
        }
    }

    /// Every status this column gathers, the drop target first.
    public func mappedStatusIDs(ofColumn columnID: String) throws -> [String] {
        try database.query(
            "SELECT status_id FROM column_status WHERE column_id = ? ORDER BY sort_order;", [columnID]
        ).compactMap { $0.string("status_id") }
    }

    /// Renames both halves. The column's name is what is drawn; the status's
    /// name is what `status = "Doing"` matches, and they must not drift.
    public func renameColumn(_ columnID: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A column needs a name.")
        }

        try database.transaction {
            guard let row = try database.queryOne("SELECT * FROM board_column WHERE id = ?;", [columnID]) else {
                throw LocalBoardError.notFound(entity: "column \(columnID)")
            }
            let column = try BoardColumn(row: row)

            try database.execute("UPDATE board_column SET name = ? WHERE id = ?;", [trimmed, columnID])
            try database.execute("UPDATE status SET name = ? WHERE id = ?;", [trimmed, column.statusID])
        }
    }

    public func setWIPLimit(_ limit: Int?, for columnID: String) throws {
        if let limit, limit < 1 {
            throw LocalBoardError.invalidInput(
                field: "limit",
                detail: "A work-in-progress limit of \(limit) would make the column unusable. Leave it empty for no limit."
            )
        }
        let changed = try database.execute(
            "UPDATE board_column SET wip_limit = ? WHERE id = ?;", [limit.sqlValue, columnID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "column \(columnID)") }
    }

    /// The floor. A column below it is starved rather than overloaded, which
    /// on a pull-based board is the signal to go and find work for it.
    public func setWIPMinimum(_ minimum: Int?, for columnID: String) throws {
        if let minimum, minimum < 0 {
            throw LocalBoardError.invalidInput(
                field: "minimum", detail: "A minimum cannot be negative."
            )
        }
        let changed = try database.execute(
            "UPDATE board_column SET wip_minimum = ? WHERE id = ?;", [minimum.sqlValue, columnID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "column \(columnID)") }
    }

    public func setWIPMeasure(_ measure: WIPMeasure, for columnID: String) throws {
        let changed = try database.execute(
            "UPDATE board_column SET wip_measure = ? WHERE id = ?;", [measure.rawValue, columnID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "column \(columnID)") }
    }

    /// Marks a column as the backlog. Its cards leave the board proper and
    /// appear on the backlog screen instead; dragging one back onto the board
    /// is the commitment point, and only then does it count against WIP.
    public func setBacklog(_ isBacklog: Bool, for columnID: String) throws {
        try database.transaction {
            guard let row = try database.queryOne(
                "SELECT * FROM board_column WHERE id = ?;", [columnID]
            ) else {
                throw LocalBoardError.notFound(entity: "column \(columnID)")
            }
            let column = try BoardColumn(row: row)

            // One backlog per board: two would each claim to be the place work
            // waits, and the commitment point would stop meaning anything.
            if isBacklog {
                try database.execute(
                    "UPDATE board_column SET is_backlog = 0 WHERE board_id = ?;", [column.boardID]
                )
                try database.execute(
                    "UPDATE board SET backlog_enabled = 1 WHERE id = ?;", [column.boardID]
                )
            }
            try database.execute(
                "UPDATE board_column SET is_backlog = ? WHERE id = ?;", [isBacklog, columnID]
            )
        }
    }

    public func setCategory(_ category: StatusCategory, for columnID: String) throws {
        try database.transaction {
            guard let row = try database.queryOne("SELECT * FROM board_column WHERE id = ?;", [columnID]) else {
                throw LocalBoardError.notFound(entity: "column \(columnID)")
            }
            let column = try BoardColumn(row: row)
            try database.execute(
                "UPDATE status SET category = ? WHERE id = ?;", [category.rawValue, column.statusID]
            )
        }
    }

    /// Removes a column, moving any cards in it somewhere else first.
    ///
    /// Deleting the status would take the cards with it — `task.status_id` has
    /// no ON DELETE clause, so the write would simply fail, and forcing it
    /// would orphan work. The cards go to the column the caller names, and a
    /// column that still holds cards cannot be removed without saying where
    /// they should land.
    public func deleteColumn(_ columnID: String, movingTasksTo destinationStatusID: String?) throws {
        try database.transaction {
            guard let row = try database.queryOne("SELECT * FROM board_column WHERE id = ?;", [columnID]) else {
                throw LocalBoardError.notFound(entity: "column \(columnID)")
            }
            let column = try BoardColumn(row: row)

            let remaining = try database.count(
                "SELECT COUNT(*) FROM task WHERE status_id = ?;", [column.statusID]
            )

            if remaining > 0 {
                guard let destinationStatusID, destinationStatusID != column.statusID else {
                    throw LocalBoardError.invalidInput(
                        field: "column",
                        detail: "\(column.name) still holds \(remaining) card\(remaining == 1 ? "" : "s"). Say which column they should move to."
                    )
                }
                try database.execute(
                    "UPDATE task SET status_id = ?, updated_at = ? WHERE status_id = ?;",
                    [destinationStatusID, clockNow, column.statusID]
                )
            }

            // Deleting the status cascades to every board_column pointing at
            // it, which is the other boards' views of the same column.
            try database.execute("DELETE FROM status WHERE id = ?;", [column.statusID])
        }
    }

    /// Puts a column between two others, the same sparse ordering the cards use.
    public func moveColumn(_ columnID: String, after: String?, before: String?) throws {
        try database.transaction {
            let lower = try after.map { try columnPosition(of: $0) }
            let upper = try before.map { try columnPosition(of: $0) }

            try database.execute(
                "UPDATE board_column SET sort_order = ? WHERE id = ?;",
                [SortOrder.between(lower, upper), columnID]
            )
        }
    }

    private func columnPosition(of columnID: String) throws -> Double {
        guard let row = try database.queryOne(
            "SELECT sort_order FROM board_column WHERE id = ?;", [columnID]
        ), let value = row.double("sort_order") else {
            throw LocalBoardError.notFound(entity: "column \(columnID)")
        }
        return value
    }
}
