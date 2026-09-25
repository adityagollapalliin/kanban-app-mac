import Foundation
import LocalBoardCore

/// Who a card belongs to, and where else it appears.
///
/// Two ideas that look alike and are not: several people on one card, and one
/// card in several lists. Both keep a single primary answer on the `task` row
/// — `assignee_id` and `list_id` — so every query written before either
/// existed still returns what it always did, and the extra rows live beside
/// them rather than replacing them.
public struct MembershipRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - Several people on one card

    public func assignees(ofTask taskID: String) throws -> [TaskAssignee] {
        try database.query(
            "SELECT * FROM task_assignee WHERE task_id = ? ORDER BY sort_order;", [taskID]
        ).map(TaskAssignee.init(row:))
    }

    /// Every card's assignees in one query, for a board that would otherwise
    /// ask once per card.
    public func assigneesByTask(inProject projectID: String) throws -> [String: [TaskAssignee]] {
        let rows = try database.query(
            """
            SELECT task_assignee.* FROM task_assignee
            JOIN task ON task.id = task_assignee.task_id
            WHERE task.project_id = ?
            ORDER BY task_assignee.sort_order;
            """,
            [projectID]
        ).map(TaskAssignee.init(row:))

        return Dictionary(grouping: rows, by: \.taskID)
    }

    /// Adds someone to a card.
    ///
    /// The first person added also becomes `task.assignee_id`, so the card,
    /// the query language and `is:mine` all agree about who is on it without
    /// any of them learning about this table.
    public func addAssignee(_ personID: String, to taskID: String, estimate: Double? = nil) throws {
        try database.transaction {
            let last = try database.queryOne(
                "SELECT MAX(sort_order) AS last FROM task_assignee WHERE task_id = ?;", [taskID]
            )?.double("last")

            try database.execute(
                """
                INSERT INTO task_assignee (task_id, person_id, estimate, sort_order)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (task_id, person_id) DO UPDATE SET estimate = ?;
                """,
                [taskID, personID, estimate.sqlValue, SortOrder.between(last, nil), estimate.sqlValue]
            )
            try syncPrimary(taskID)
        }
    }

    public func removeAssignee(_ personID: String, from taskID: String) throws {
        try database.transaction {
            try database.execute(
                "DELETE FROM task_assignee WHERE task_id = ? AND person_id = ?;", [taskID, personID]
            )
            try syncPrimary(taskID)
        }
    }

    /// How much of the work is this person's. `nil` puts them back to an
    /// unstated share, which the workload view reads as an equal split rather
    /// than as nothing.
    public func setEstimate(_ estimate: Double?, forAssignee personID: String, on taskID: String) throws {
        let changed = try database.execute(
            "UPDATE task_assignee SET estimate = ? WHERE task_id = ? AND person_id = ?;",
            [estimate.sqlValue, taskID, personID]
        )
        guard changed > 0 else {
            throw LocalBoardError.notFound(entity: "assignee \(personID) on \(taskID)")
        }
    }

    /// Keeps `task.assignee_id` pointing at the first assignee, or at nobody
    /// when the last one is removed.
    private func syncPrimary(_ taskID: String) throws {
        let first = try database.queryOne(
            "SELECT person_id FROM task_assignee WHERE task_id = ? ORDER BY sort_order LIMIT 1;", [taskID]
        )?.string("person_id")

        try database.execute(
            "UPDATE task SET assignee_id = ?, updated_at = ? WHERE id = ?;",
            [first.sqlValue, clock.now, taskID]
        )
    }

    /// What one person is carrying: every card they are on, anywhere.
    public func tasks(assignedTo personID: String, includeDone: Bool = false) throws -> [BoardTask] {
        let clause = includeDone ? "" : " AND task.completed_at IS NULL"
        return try database.query(
            """
            SELECT task.* FROM task_assignee
            JOIN task ON task.id = task_assignee.task_id
            WHERE task_assignee.person_id = ? AND task.trashed = 0\(clause)
            ORDER BY task.due_date, task.sort_order;
            """,
            [personID]
        ).map(BoardTask.init(row:))
    }

    // MARK: - One card, several lists

    /// The lists a card appears in beyond its home. The home list is on the
    /// card itself, so there is one answer to "where does this live" and a
    /// separate one to "where else is it shown".
    public func extraLists(ofTask taskID: String) throws -> [TaskList] {
        try database.query(
            """
            SELECT list.* FROM task_list
            JOIN list ON list.id = task_list.list_id
            WHERE task_list.task_id = ?
            ORDER BY list.sort_order;
            """,
            [taskID]
        ).map(TaskList.init(row:))
    }

    /// Adding a card to the list it already calls home does nothing rather
    /// than recording a second membership: it is already there, and saying so
    /// twice would show it twice.
    public func addTask(_ taskID: String, toList listID: String) throws {
        let home = try database.queryOne("SELECT list_id FROM task WHERE id = ?;", [taskID])?.string("list_id")
        guard home != listID else { return }

        try database.execute(
            "INSERT OR IGNORE INTO task_list (task_id, list_id, added_at) VALUES (?, ?, ?);",
            [taskID, listID, clock.now]
        )
    }

    public func removeTask(_ taskID: String, fromList listID: String) throws {
        try database.execute(
            "DELETE FROM task_list WHERE task_id = ? AND list_id = ?;", [taskID, listID]
        )
    }

    /// Moves a card's home, keeping every other list it appears in. A card
    /// that has moved house is still on the same noticeboards.
    public func setHomeList(_ listID: String, forTask taskID: String) throws {
        try database.transaction {
            // If it was also shown in the list it is moving into, that
            // membership is now redundant — it lives there.
            try database.execute(
                "DELETE FROM task_list WHERE task_id = ? AND list_id = ?;", [taskID, listID]
            )
            let changed = try database.execute(
                "UPDATE task SET list_id = ?, updated_at = ? WHERE id = ?;", [listID, clock.now, taskID]
            )
            guard changed > 0 else { throw LocalBoardError.notFound(entity: "task \(taskID)") }
        }
    }

    /// Every card a list shows: the ones that live there, and the ones added
    /// to it from elsewhere. One query, because a list that asked twice would
    /// have to merge and re-sort two answers.
    public func tasks(inList listID: String, includeTrashed: Bool = false) throws -> [BoardTask] {
        let clause = includeTrashed ? "" : " AND task.trashed = 0"
        return try database.query(
            """
            SELECT task.* FROM task
            WHERE (task.list_id = ?
                   OR task.id IN (SELECT task_id FROM task_list WHERE list_id = ?))\(clause)
            ORDER BY task.sort_order;
            """,
            [listID, listID]
        ).map(BoardTask.init(row:))
    }

    /// Which cards are borrowed rather than resident, so a list can mark them.
    public func borrowedTaskIDs(inList listID: String) throws -> Set<String> {
        Set(try database.query(
            "SELECT task_id FROM task_list WHERE list_id = ?;", [listID]
        ).compactMap { $0.string("task_id") })
    }

    /// Where else each card on a board appears, gathered once. The card shows
    /// a small badge for this, and a query per card per redraw is how the
    /// timeline once cost a filesystem walk a frame.
    public func extraListsByTask(inProject projectID: String) throws -> [String: [TaskList]] {
        let rows = try database.query(
            """
            SELECT task_list.task_id AS task_id, list.* FROM task_list
            JOIN list ON list.id = task_list.list_id
            JOIN task ON task.id = task_list.task_id
            WHERE task.project_id = ?
            ORDER BY list.sort_order;
            """,
            [projectID]
        )

        var byTask: [String: [TaskList]] = [:]
        for row in rows {
            guard let taskID = row.string("task_id") else { continue }
            byTask[taskID, default: []].append(try TaskList(row: row))
        }
        return byTask
    }
}
