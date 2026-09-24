import Foundation
import LocalBoardCore

/// The board's own settings, its lanes and its quick filters.
///
/// All three are the same kind of thing — how this board chooses to show the
/// work — and they are kept together so that "configure the board" is one
/// type rather than three that have to be held in the right order.
public struct BoardPresentationRepository {

    let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Board settings

    public func setSwimlaneMode(_ mode: SwimlaneMode, for boardID: String) throws {
        try updateBoard(boardID, "swimlane_mode = ?", [mode.rawValue])
    }

    /// The board's chosen extra card rows, trimmed to what a card can carry.
    public func setCardFields(_ fields: [CardField], for boardID: String) throws {
        try updateBoard(boardID, "card_fields = ?", [CardField.stored(fields)])
    }

    /// Colouring by a saved view needs the view; every other rule must forget
    /// it, so that switching away and back does not silently restore a choice
    /// the user has moved on from.
    public func setColorRule(_ rule: CardColorRule, viewID: String? = nil, for boardID: String) throws {
        try updateBoard(
            boardID,
            "color_rule = ?, color_view_id = ?",
            [rule.rawValue, (rule == .query ? viewID : nil).sqlValue]
        )
    }

    public func setStaleDays(_ days: Int, for boardID: String) throws {
        guard days >= 1 else {
            throw LocalBoardError.invalidInput(
                field: "stale_days", detail: "A card has to be somewhere at least a day."
            )
        }
        try updateBoard(boardID, "stale_days = ?", [days])
    }

    public func setBacklogEnabled(_ enabled: Bool, for boardID: String) throws {
        try updateBoard(boardID, "backlog_enabled = ?", [enabled])
    }

    /// Points a board at a question rather than at a project.
    ///
    /// The query is parsed before it is stored, so a board cannot be left
    /// defined by something that will never run.
    public func setFilterQuery(_ query: String, for boardID: String) throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            _ = try TaskQueryParser.parse(trimmed)
        }
        try updateBoard(boardID, "filter_query = ?", [trimmed])
    }

    private func updateBoard(_ boardID: String, _ assignment: String, _ values: [SQLValueConvertible]) throws {
        let changed = try database.execute(
            "UPDATE board SET \(assignment) WHERE id = ?;", values + [boardID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "board \(boardID)") }
    }

    // MARK: - Swimlanes

    /// Pinned lanes first, then the rest, each group in its own order — which
    /// is the order they are matched in, so "first match wins" reads down the
    /// list exactly as it is shown.
    public func swimlanes(inBoard boardID: String) throws -> [Swimlane] {
        try database.query(
            "SELECT * FROM swimlane WHERE board_id = ? ORDER BY pinned DESC, sort_order;",
            [boardID]
        ).map(Swimlane.init(row:))
    }

    @discardableResult
    public func createSwimlane(
        inBoard boardID: String,
        name: String,
        query: String,
        pinned: Bool = false
    ) throws -> Swimlane {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A swimlane needs a name.")
        }
        _ = try TaskQueryParser.parse(query)

        let id = UUID().uuidString
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM swimlane WHERE board_id = ? AND pinned = ?;",
            [boardID, pinned]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO swimlane (id, board_id, name, query, pinned, sort_order)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [id, boardID, trimmedName, query, pinned, SortOrder.between(last, nil)]
        )

        guard let row = try database.queryOne("SELECT * FROM swimlane WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The swimlane was not written.")
        }
        return try Swimlane(row: row)
    }

    public func updateSwimlane(_ laneID: String, name: String, query: String) throws {
        _ = try TaskQueryParser.parse(query)
        let changed = try database.execute(
            "UPDATE swimlane SET name = ?, query = ? WHERE id = ?;", [name, query, laneID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "swimlane \(laneID)") }
    }

    public func deleteSwimlane(_ laneID: String) throws {
        let changed = try database.execute("DELETE FROM swimlane WHERE id = ?;", [laneID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "swimlane \(laneID)") }
    }

    public func moveSwimlane(_ laneID: String, after: String?, before: String?) throws {
        let lower = try after.map { try swimlanePosition(of: $0) }
        let upper = try before.map { try swimlanePosition(of: $0) }
        try database.execute(
            "UPDATE swimlane SET sort_order = ? WHERE id = ?;",
            [SortOrder.between(lower, upper), laneID]
        )
    }

    private func swimlanePosition(of laneID: String) throws -> Double {
        guard let value = try database.queryOne(
            "SELECT sort_order FROM swimlane WHERE id = ?;", [laneID]
        )?.double("sort_order") else {
            throw LocalBoardError.notFound(entity: "swimlane \(laneID)")
        }
        return value
    }

    // MARK: - Quick filters

    public func quickFilters(inBoard boardID: String) throws -> [QuickFilter] {
        try database.query(
            "SELECT * FROM quick_filter WHERE board_id = ? ORDER BY sort_order;", [boardID]
        ).map(QuickFilter.init(row:))
    }

    @discardableResult
    public func createQuickFilter(
        inBoard boardID: String,
        name: String,
        query: String
    ) throws -> QuickFilter {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A quick filter needs a name.")
        }
        _ = try TaskQueryParser.parse(query)

        let id = UUID().uuidString
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM quick_filter WHERE board_id = ?;", [boardID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO quick_filter (id, board_id, name, query, sort_order)
            VALUES (?, ?, ?, ?, ?);
            """,
            [id, boardID, trimmedName, query, SortOrder.between(last, nil)]
        )

        guard let row = try database.queryOne("SELECT * FROM quick_filter WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The quick filter was not written.")
        }
        return try QuickFilter(row: row)
    }

    public func updateQuickFilter(_ filterID: String, name: String, query: String) throws {
        _ = try TaskQueryParser.parse(query)
        let changed = try database.execute(
            "UPDATE quick_filter SET name = ?, query = ? WHERE id = ?;", [name, query, filterID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "quick filter \(filterID)") }
    }

    public func deleteQuickFilter(_ filterID: String) throws {
        let changed = try database.execute("DELETE FROM quick_filter WHERE id = ?;", [filterID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "quick filter \(filterID)") }
    }

    /// The four a new board starts with, and the Expedite lane every board has.
    ///
    /// Rows rather than hardcoded buttons, so the first thing anyone finds out
    /// about them is that they can be renamed, rewritten or thrown away.
    func seedDefaults(forBoard boardID: String) throws {
        try createSwimlane(inBoard: boardID, name: "Expedite", query: "priority >= highest", pinned: true)

        for (name, query) in [
            ("My Tasks", "is:mine"),
            ("Recently Updated", "updated >= -3d"),
            ("Flagged", "is:flagged"),
            ("Due This Week", "due <= +7d is:open"),
        ] {
            try createQuickFilter(inBoard: boardID, name: name, query: query)
        }
    }
}
