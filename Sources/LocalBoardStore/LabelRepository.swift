import Foundation
import LocalBoardCore

/// Labels, and which cards carry them.
///
/// A label belongs to a project, not to a card: the same "needs design" means
/// the same thing on every card in the project, which is what makes
/// `label = "needs design"` worth typing.
public struct LabelRepository {

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func labels(inProject projectID: String) throws -> [Label] {
        try database.query("SELECT * FROM label WHERE project_id = ? ORDER BY name;", [projectID])
            .map(Label.init(row:))
    }

    @discardableResult
    public func create(inProject projectID: String, name: String, color: String = "slate") throws -> Label {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A label needs a name.")
        }

        let existing = try database.query(
            "SELECT id FROM label WHERE project_id = ? AND name = ? COLLATE NOCASE;", [projectID, trimmed]
        )
        guard existing.isEmpty else {
            throw LocalBoardError.invalidInput(
                field: "name",
                detail: "This project already has a label called \(trimmed)."
            )
        }

        let id = UUID().uuidString
        try database.execute(
            "INSERT INTO label (id, project_id, name, color) VALUES (?, ?, ?, ?);",
            [id, projectID, trimmed, color]
        )
        return Label(id: id, projectID: projectID, name: trimmed, color: color)
    }

    public func rename(_ labelID: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A label needs a name.")
        }
        let changed = try database.execute("UPDATE label SET name = ? WHERE id = ?;", [trimmed, labelID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "label \(labelID)") }
    }

    public func setColor(_ color: String, for labelID: String) throws {
        let changed = try database.execute("UPDATE label SET color = ? WHERE id = ?;", [color, labelID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "label \(labelID)") }
    }

    /// Deleting a label takes it off every card. The cards are untouched.
    public func delete(_ labelID: String) throws {
        let changed = try database.execute("DELETE FROM label WHERE id = ?;", [labelID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "label \(labelID)") }
    }

    // MARK: - Which cards carry which

    public func labels(forTask taskID: String) throws -> [Label] {
        try database.query(
            """
            SELECT label.* FROM label
            JOIN task_label ON task_label.label_id = label.id
            WHERE task_label.task_id = ?
            ORDER BY label.name;
            """,
            [taskID]
        ).map(Label.init(row:))
    }

    /// Every card's labels in one query, for drawing a whole board.
    public func labelsByTask(inProject projectID: String) throws -> [String: [Label]] {
        var grouped: [String: [Label]] = [:]
        try database.forEachRow(
            """
            SELECT task_label.task_id AS task_id, label.* FROM label
            JOIN task_label ON task_label.label_id = label.id
            JOIN task ON task.id = task_label.task_id
            WHERE task.project_id = ?
            ORDER BY label.name;
            """,
            [projectID]
        ) { row in
            let taskID = try row.requiredString("task_id")
            grouped[taskID, default: []].append(try Label(row: row))
        }
        return grouped
    }

    public func setLabel(_ labelID: String, on taskID: String, attached: Bool) throws {
        if attached {
            // Already there is not an error; putting a label on twice is one
            // label.
            try database.execute(
                "INSERT OR IGNORE INTO task_label (task_id, label_id) VALUES (?, ?);", [taskID, labelID]
            )
        } else {
            try database.execute(
                "DELETE FROM task_label WHERE task_id = ? AND label_id = ?;", [taskID, labelID]
            )
        }
    }
}
