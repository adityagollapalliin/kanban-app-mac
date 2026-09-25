import Foundation
import LocalBoardCore

/// Whiteboards and the things on them.
public struct WhiteboardRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - Boards

    public func boards(inProject projectID: String?) throws -> [Whiteboard] {
        if let projectID {
            return try database.query(
                "SELECT * FROM whiteboard WHERE project_id = ? ORDER BY sort_order;", [projectID]
            ).map(Whiteboard.init(row:))
        }
        return try database.query("SELECT * FROM whiteboard ORDER BY sort_order;")
            .map(Whiteboard.init(row:))
    }

    @discardableResult
    public func create(named name: String, inProject projectID: String?) throws -> Whiteboard {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID().uuidString
        let last = try database.queryOne("SELECT MAX(sort_order) AS last FROM whiteboard;")?.double("last")

        try database.execute(
            """
            INSERT INTO whiteboard (id, project_id, name, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [
                id, projectID.sqlValue, trimmed.isEmpty ? "Whiteboard" : trimmed,
                SortOrder.between(last, nil), clock.now, clock.now,
            ]
        )
        return try board(id: id)
    }

    public func board(id: String) throws -> Whiteboard {
        guard let row = try database.queryOne("SELECT * FROM whiteboard WHERE id = ?;", [id]) else {
            throw LocalBoardError.notFound(entity: "whiteboard \(id)")
        }
        return try Whiteboard(row: row)
    }

    public func rename(_ boardID: String, to name: String) throws {
        try database.execute("UPDATE whiteboard SET name = ? WHERE id = ?;", [name, boardID])
    }

    public func delete(_ boardID: String) throws {
        let changed = try database.execute("DELETE FROM whiteboard WHERE id = ?;", [boardID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "whiteboard \(boardID)") }
    }

    // MARK: - Items

    public func items(onBoard boardID: String) throws -> [WhiteboardItem] {
        try database.query(
            "SELECT * FROM whiteboard_item WHERE board_id = ? ORDER BY sort_order;", [boardID]
        ).map(WhiteboardItem.init(row:))
    }

    @discardableResult
    public func add(_ item: WhiteboardItem) throws -> WhiteboardItem {
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM whiteboard_item WHERE board_id = ?;", [item.boardID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO whiteboard_item (id, board_id, kind, x, y, width, height, text, color,
                                         shape, points, from_item, to_item, task_id, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                item.id, item.boardID, item.kind.rawValue, item.x, item.y, item.width, item.height,
                item.text, item.color, item.shape.rawValue, item.encodedPoints,
                item.fromItem.sqlValue, item.toItem.sqlValue, item.taskID.sqlValue,
                SortOrder.between(last, nil), clock.now,
            ]
        )
        try touch(item.boardID)
        return item
    }

    public func move(_ itemID: String, to x: Double, _ y: Double) throws {
        try database.execute("UPDATE whiteboard_item SET x = ?, y = ? WHERE id = ?;", [x, y, itemID])
    }

    public func resize(_ itemID: String, width: Double, height: Double) throws {
        try database.execute(
            "UPDATE whiteboard_item SET width = ?, height = ? WHERE id = ?;",
            [max(40, width), max(30, height), itemID]
        )
    }

    public func setText(_ text: String, for itemID: String) throws {
        try database.execute("UPDATE whiteboard_item SET text = ? WHERE id = ?;", [text, itemID])
    }

    public func setColor(_ color: String, for itemID: String) throws {
        try database.execute("UPDATE whiteboard_item SET color = ? WHERE id = ?;", [color, itemID])
    }

    public func delete(item itemID: String) throws {
        try database.execute("DELETE FROM whiteboard_item WHERE id = ?;", [itemID])
    }

    /// Turns a sticky into a card and remembers which, so the canvas can say
    /// it became one rather than offering to make a second.
    @discardableResult
    public func convertToTask(
        _ itemID: String, inProject projectID: String, statusID: String, listID: String? = nil
    ) throws -> BoardTask {
        let item = try item(id: itemID)
        guard item.taskID == nil else { return try TaskRepository(database: database, clock: clock).task(id: item.taskID!) }

        let title = item.text.split(separator: "\n").first.map(String.init)
            ?? item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw LocalBoardError.invalidInput(
                field: "text", detail: "An empty sticky has nothing to make a card out of."
            )
        }

        // The rest of the sticky becomes the card's notes, so nothing written
        // on the canvas is lost in the move.
        let rest = item.text.split(separator: "\n").dropFirst().joined(separator: "\n")

        return try database.transaction {
            let task = try TaskRepository(database: database, clock: clock).create(
                inProject: projectID, statusID: statusID, title: title,
                descriptionMarkdown: rest, listID: listID
            )
            try database.execute(
                "UPDATE whiteboard_item SET task_id = ? WHERE id = ?;", [task.id, itemID]
            )
            return task
        }
    }

    public func item(id: String) throws -> WhiteboardItem {
        guard let row = try database.queryOne("SELECT * FROM whiteboard_item WHERE id = ?;", [id]) else {
            throw LocalBoardError.notFound(entity: "item \(id)")
        }
        return try WhiteboardItem(row: row)
    }

    private func touch(_ boardID: String) throws {
        try database.execute("UPDATE whiteboard SET updated_at = ? WHERE id = ?;", [clock.now, boardID])
    }
}
