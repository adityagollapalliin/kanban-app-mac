import Foundation
import LocalBoardCore

/// Goals, and the folders they sit in.
///
/// A goal whose figure comes from the cards is refreshed rather than watched:
/// `refresh` counts the matching cards and writes the number down. Keeping it
/// live on every card edit would mean every move on the board went looking
/// for goals that might care, and a count that is a few seconds stale is a
/// better trade than that.
public struct GoalRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - Folders

    public func folders(inProject projectID: String) throws -> [GoalFolder] {
        try database.query(
            "SELECT * FROM goal_folder WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ).map(GoalFolder.init(row:))
    }

    @discardableResult
    public func createFolder(inProject projectID: String, named name: String) throws -> GoalFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A folder needs a name.")
        }
        let id = UUID().uuidString
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM goal_folder WHERE project_id = ?;", [projectID]
        )?.double("last")

        try database.execute(
            "INSERT INTO goal_folder (id, project_id, name, sort_order, created_at) VALUES (?, ?, ?, ?, ?);",
            [id, projectID, trimmed, SortOrder.between(last, nil), clock.now]
        )
        guard let row = try database.queryOne("SELECT * FROM goal_folder WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The folder was not written.")
        }
        return try GoalFolder(row: row)
    }

    /// Removes a folder. The goals in it move up to the space rather than
    /// going with it — deleting a folder is tidying, not throwing work away.
    public func deleteFolder(_ folderID: String) throws {
        let changed = try database.execute("DELETE FROM goal_folder WHERE id = ?;", [folderID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "goal folder \(folderID)") }
    }

    public func renameFolder(_ folderID: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A folder needs a name.")
        }
        let changed = try database.execute(
            "UPDATE goal_folder SET name = ? WHERE id = ?;", [trimmed, folderID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "goal folder \(folderID)") }
    }

    // MARK: - Goals

    public func goals(inProject projectID: String, includingArchived: Bool = false) throws -> [Goal] {
        let clause = includingArchived ? "" : " AND archived = 0"
        return try database.query(
            "SELECT * FROM goal WHERE project_id = ?\(clause) ORDER BY sort_order;", [projectID]
        ).map(Goal.init(row:))
    }

    public func goal(id: String) throws -> Goal {
        guard let row = try database.queryOne("SELECT * FROM goal WHERE id = ?;", [id]) else {
            throw LocalBoardError.notFound(entity: "goal \(id)")
        }
        return try Goal(row: row)
    }

    @discardableResult
    public func create(
        inProject projectID: String,
        name: String,
        kind: GoalKind = .number,
        target: Double = 1,
        start: Double = 0,
        currency: String = "USD",
        query: String = "",
        listID: String? = nil,
        folderID: String? = nil,
        ownerID: String? = nil,
        dueAt: Date? = nil,
        notes: String = ""
    ) throws -> Goal {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A goal needs a name.")
        }

        // A goal whose target equals its start has no distance to cover, which
        // is a goal that is met the moment it is made. Almost always a slip.
        if kind != .boolean, target == start {
            throw LocalBoardError.invalidInput(
                field: "target",
                detail: "The target is the same as the starting figure, so there is nothing to reach."
            )
        }

        let id = UUID().uuidString
        let now = clock.now
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM goal WHERE project_id = ?;", [projectID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO goal (
                id, project_id, folder_id, name, notes, kind, start_number, target_number,
                current_number, currency, query, list_id, owner_id, due_at,
                sort_order, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [id, projectID, folderID.sqlValue, trimmed, notes, kind.rawValue,
             start, kind == .boolean ? 1 : target, start, currency, query,
             listID.sqlValue, ownerID.sqlValue, dueAt.sqlValue,
             SortOrder.between(last, nil), now, now]
        )

        // An automatic goal is counted the moment it is made, so it opens
        // showing where it already stands rather than at zero.
        if kind.isAutomatic { try refresh(id) }
        return try goal(id: id)
    }

    public func update(_ goal: Goal) throws {
        let changed = try database.execute(
            """
            UPDATE goal SET
                folder_id = ?, name = ?, notes = ?, kind = ?, start_number = ?, target_number = ?,
                current_number = ?, currency = ?, query = ?, list_id = ?, owner_id = ?,
                due_at = ?, completed_at = ?, archived = ?, updated_at = ?
            WHERE id = ?;
            """,
            [goal.folderID.sqlValue, goal.name, goal.notes, goal.kind.rawValue,
             goal.start, goal.target, goal.current, goal.currency, goal.query,
             goal.listID.sqlValue, goal.ownerID.sqlValue, goal.dueAt.sqlValue,
             goal.completedAt.sqlValue, goal.archived ? 1 : 0, clock.now, goal.id]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "goal \(goal.id)") }
    }

    /// Records where the figure stands, for the goals somebody keeps by hand.
    public func setCurrent(_ value: Double, for goalID: String) throws {
        var goal = try goal(id: goalID)
        guard !goal.kind.isAutomatic else {
            throw LocalBoardError.invalidInput(
                field: "current",
                detail: "This goal counts its own tasks, so its figure can't be typed in."
            )
        }
        goal.current = value
        goal.completedAt = goal.isMet ? (goal.completedAt ?? clock.now) : nil
        try update(goal)
    }

    public func setFolder(_ folderID: String?, for goalID: String) throws {
        let changed = try database.execute(
            "UPDATE goal SET folder_id = ?, updated_at = ? WHERE id = ?;",
            [folderID.sqlValue, clock.now, goalID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "goal \(goalID)") }
    }

    public func setArchived(_ archived: Bool, for goalID: String) throws {
        let changed = try database.execute(
            "UPDATE goal SET archived = ?, updated_at = ? WHERE id = ?;",
            [archived ? 1 : 0, clock.now, goalID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "goal \(goalID)") }
    }

    public func delete(_ goalID: String) throws {
        let changed = try database.execute("DELETE FROM goal WHERE id = ?;", [goalID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "goal \(goalID)") }
    }

    // MARK: - Counting the automatic ones

    /// Recounts one goal from the cards it watches.
    ///
    /// The target is how many need finishing and the figure is how many have
    /// been. A goal with neither a query nor a list watches the whole space,
    /// which is a reasonable thing to mean by "ship everything".
    public func refresh(_ goalID: String) throws {
        var goal = try goal(id: goalID)
        guard goal.kind.isAutomatic else { return }

        let counts = try counts(for: goal)
        goal.current = Double(counts.done)
        // A goal that says "finish the list" has a moving target, because the
        // list moves. Writing it down each time is what makes the bar honest
        // when three more cards arrive.
        if goal.query.isEmpty, goal.listID != nil, counts.total > 0 {
            goal.target = Double(counts.total)
        }
        goal.completedAt = goal.isMet ? (goal.completedAt ?? clock.now) : nil
        try update(goal)
    }

    /// Recounts every automatic goal in a project.
    public func refreshAll(inProject projectID: String) throws {
        for goal in try goals(inProject: projectID) where goal.kind.isAutomatic {
            try refresh(goal.id)
        }
    }

    /// How many cards a goal is watching, and how many are finished.
    public func counts(for goal: Goal) throws -> (done: Int, total: Int) {
        var clauses = ["task.project_id = ?", "task.trashed = 0"]
        var parameters: [SQLValue] = [.text(goal.projectID)]

        if let listID = goal.listID {
            clauses.append("task.list_id = ?")
            parameters.append(.text(listID))
        }

        // A goal's query is compiled by the compiler the search bar uses, so a
        // goal can watch anything a saved view can.
        if !goal.query.trimmingCharacters(in: .whitespaces).isEmpty {
            let filter = try TaskQueryParser.parse(goal.query)
            let compiler = TaskQueryCompiler(
                database: database,
                projectID: goal.projectID,
                now: clock.now,
                currentPersonID: try AppSettings(database: database).currentPersonID
            )
            let compiled = try compiler.compile(filter)
            clauses.append(compiled.whereClause)
            parameters.append(contentsOf: compiled.parameters)
        }

        let common = clauses.joined(separator: " AND ")
        let total = try database.count("SELECT COUNT(*) FROM task WHERE \(common);", parameters)
        let done = try database.count(
            "SELECT COUNT(*) FROM task WHERE \(common) AND task.completed_at IS NOT NULL;",
            parameters
        )
        return (done, total)
    }
}
