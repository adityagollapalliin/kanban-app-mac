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

            // A new board over an existing project shows the columns that
            // project already has; a board with none would show nothing.
            for status in try statuses(inProject: projectID) {
                try database.execute(
                    """
                    INSERT INTO board_column (id, board_id, status_id, name, sort_order)
                    VALUES (?, ?, ?, ?, ?);
                    """,
                    [UUID().uuidString, boardID, status.id, status.name, status.sortOrder]
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
        return columnID
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
