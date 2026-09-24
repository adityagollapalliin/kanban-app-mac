import Foundation
import LocalBoardCore

/// Cards that contain other cards: subtasks by `parent_id`, and the epic a
/// card rolls up to by `epic_id`.
///
/// The two are deliberately different. A subtask is part of its parent and
/// dies with it (ON DELETE CASCADE); an epic is a heading work is filed under,
/// and deleting it only unfiles the work (ON DELETE SET NULL).
extension TaskRepository {

    public func subtasks(of taskID: String) throws -> [BoardTask] {
        try database.query(
            "SELECT * FROM task WHERE parent_id = ? AND trashed = 0 ORDER BY sort_order;", [taskID]
        ).map(BoardTask.init(row:))
    }

    public func epics(inProject projectID: String) throws -> [BoardTask] {
        try database.query(
            """
            SELECT * FROM task
            WHERE project_id = ? AND type = ? AND trashed = 0
            ORDER BY number;
            """,
            [projectID, TaskType.epic.rawValue]
        ).map(BoardTask.init(row:))
    }

    public func tasks(inEpic epicID: String) throws -> [BoardTask] {
        try database.query(
            "SELECT * FROM task WHERE epic_id = ? AND trashed = 0 ORDER BY number;", [epicID]
        ).map(BoardTask.init(row:))
    }

    /// Makes one card a subtask of another.
    ///
    /// Refuses to close a loop. Without the check a card could be made its own
    /// ancestor, and every walk of the tree afterwards — drawing it, deleting
    /// it, counting it — would run forever.
    public func setParent(_ parentID: String?, for taskID: String) throws {
        guard let parentID else {
            try update(taskID, "parent_id = ?", [SQLValue.null])
            return
        }

        guard parentID != taskID else {
            throw LocalBoardError.invalidInput(
                field: "parent",
                detail: "A card cannot be a subtask of itself."
            )
        }

        guard try !isDescendant(parentID, of: taskID) else {
            throw LocalBoardError.invalidInput(
                field: "parent",
                detail: "That card is already underneath this one, so this would make a loop."
            )
        }

        try update(taskID, "parent_id = ?", [parentID])
    }

    /// Whether `candidate` sits anywhere below `ancestor`.
    private func isDescendant(_ candidate: String, of ancestor: String) throws -> Bool {
        var current: String? = candidate
        // The chain is finite, but a file written by something else might not
        // be; stop rather than hang.
        var steps = 0

        while let id = current, steps < 1_000 {
            if id == ancestor { return true }
            let row = try database.queryOne("SELECT parent_id FROM task WHERE id = ?;", [id])
            current = row?.string("parent_id")
            steps += 1
        }
        return false
    }

    public func setEpic(_ epicID: String?, for taskID: String) throws {
        if let epicID {
            guard epicID != taskID else {
                throw LocalBoardError.invalidInput(
                    field: "epic",
                    detail: "A card cannot be filed under itself."
                )
            }
            let row = try database.queryOne("SELECT type FROM task WHERE id = ?;", [epicID])
            guard let raw = row?.int("type"), TaskType(rawValue: Int(raw)) == .epic else {
                throw LocalBoardError.invalidInput(
                    field: "epic",
                    detail: "Only a card of type Epic can hold other work."
                )
            }
        }
        try update(taskID, "epic_id = ?", [epicID.sqlValue])
    }

    /// How many subtasks each card has, and how many are finished — for the
    /// counter on the card.
    public func subtaskProgress(inProject projectID: String) throws -> [String: ChecklistProgress] {
        var progress: [String: ChecklistProgress] = [:]
        try database.forEachRow(
            """
            SELECT parent_id                                         AS parent_id,
                   COUNT(*)                                          AS total,
                   SUM(CASE WHEN completed_at IS NOT NULL THEN 1 ELSE 0 END) AS done
            FROM task
            WHERE project_id = ? AND parent_id IS NOT NULL AND trashed = 0
            GROUP BY parent_id;
            """,
            [projectID]
        ) { row in
            let parentID = try row.requiredString("parent_id")
            progress[parentID] = ChecklistProgress(
                done: Int(row.int("done") ?? 0),
                total: Int(row.int("total") ?? 0)
            )
        }
        return progress
    }
}
