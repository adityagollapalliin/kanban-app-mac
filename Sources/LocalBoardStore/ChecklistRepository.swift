import Foundation
import LocalBoardCore

/// The checklist on a card.
public struct ChecklistRepository {

    private let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    public func items(forTask taskID: String) throws -> [ChecklistItem] {
        try database.query(
            "SELECT * FROM checklist_item WHERE task_id = ? ORDER BY sort_order;", [taskID]
        ).map(ChecklistItem.init(row:))
    }

    @discardableResult
    public func add(toTask taskID: String, text: String) throws -> ChecklistItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "text", detail: "A checklist item needs some words.")
        }

        let id = UUID().uuidString
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM checklist_item WHERE task_id = ?;", [taskID]
        )?.double("last")

        try database.execute(
            "INSERT INTO checklist_item (id, task_id, text, sort_order) VALUES (?, ?, ?, ?);",
            [id, taskID, trimmed, SortOrder.between(last, nil)]
        )
        try touch(taskID)

        return ChecklistItem(id: id, taskID: taskID, text: trimmed, sortOrder: SortOrder.between(last, nil))
    }

    public func setDone(_ done: Bool, for itemID: String) throws {
        let changed = try database.execute(
            "UPDATE checklist_item SET done = ? WHERE id = ?;", [done, itemID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "checklist item \(itemID)") }
        try touchOwner(of: itemID)
    }

    public func setText(_ text: String, for itemID: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "text", detail: "A checklist item needs some words.")
        }
        let changed = try database.execute(
            "UPDATE checklist_item SET text = ? WHERE id = ?;", [trimmed, itemID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "checklist item \(itemID)") }
        try touchOwner(of: itemID)
    }

    public func delete(_ itemID: String) throws {
        try touchOwner(of: itemID)
        let changed = try database.execute("DELETE FROM checklist_item WHERE id = ?;", [itemID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "checklist item \(itemID)") }
    }

    /// Every card's progress in one query, for the counters on the cards.
    public func progressByTask(inProject projectID: String) throws -> [String: ChecklistProgress] {
        var progress: [String: ChecklistProgress] = [:]
        try database.forEachRow(
            """
            SELECT checklist_item.task_id  AS task_id,
                   COUNT(*)                AS total,
                   SUM(checklist_item.done) AS done
            FROM checklist_item
            JOIN task ON task.id = checklist_item.task_id
            WHERE task.project_id = ?
            GROUP BY checklist_item.task_id;
            """,
            [projectID]
        ) { row in
            let taskID = try row.requiredString("task_id")
            progress[taskID] = ChecklistProgress(
                done: Int(row.int("done") ?? 0),
                total: Int(row.int("total") ?? 0)
            )
        }
        return progress
    }

    /// Ticking a box is a change to the card, so the card's stamp moves too.
    private func touch(_ taskID: String) throws {
        try database.execute("UPDATE task SET updated_at = ? WHERE id = ?;", [clock.now, taskID])
    }

    private func touchOwner(of itemID: String) throws {
        guard let row = try database.queryOne(
            "SELECT task_id FROM checklist_item WHERE id = ?;", [itemID]
        ), let taskID = row.string("task_id") else { return }
        try touch(taskID)
    }
}
