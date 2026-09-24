import Foundation
import LocalBoardCore

/// Named queries.
///
/// The query text is stored, never the cards it matched. A view is a question,
/// and the answer is whatever is true when it is next asked.
public struct SavedViewRepository {

    private let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    public func views(inProject projectID: String) throws -> [SavedView] {
        try database.query("SELECT * FROM saved_view WHERE project_id = ? ORDER BY sort_order;", [projectID])
            .map(SavedView.init(row:))
    }

    public func view(id: String) throws -> SavedView {
        guard let row = try database.queryOne("SELECT * FROM saved_view WHERE id = ?;", [id]) else {
            throw LocalBoardError.notFound(entity: "view \(id)")
        }
        return try SavedView(row: row)
    }

    /// Saves a query under a name.
    ///
    /// The query is parsed before it is stored. A saved view that does not
    /// parse is a trap set for later — better to refuse it while the person
    /// who wrote it is still looking at it.
    @discardableResult
    public func create(inProject projectID: String, name: String, query: String) throws -> SavedView {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A view needs a name.")
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try TaskQueryParser.parse(trimmedQuery)

        guard try !nameExists(trimmedName, inProject: projectID, excluding: nil) else {
            throw LocalBoardError.invalidInput(
                field: "name",
                detail: "This project already has a view called \(trimmedName)."
            )
        }

        let id = UUID().uuidString
        let now = clock.now
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM saved_view WHERE project_id = ?;", [projectID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO saved_view (id, project_id, name, query, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [id, projectID, trimmedName, trimmedQuery, SortOrder.between(last, nil), now]
        )
        return try view(id: id)
    }

    public func rename(_ viewID: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A view needs a name.")
        }

        let existing = try view(id: viewID)
        guard try !nameExists(trimmed, inProject: existing.projectID, excluding: viewID) else {
            throw LocalBoardError.invalidInput(
                field: "name",
                detail: "This project already has a view called \(trimmed)."
            )
        }
        try database.execute("UPDATE saved_view SET name = ? WHERE id = ?;", [trimmed, viewID])
    }

    public func setQuery(_ query: String, for viewID: String) throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try TaskQueryParser.parse(trimmed)

        let changed = try database.execute("UPDATE saved_view SET query = ? WHERE id = ?;", [trimmed, viewID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "view \(viewID)") }
    }

    public func delete(_ viewID: String) throws {
        let changed = try database.execute("DELETE FROM saved_view WHERE id = ?;", [viewID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "view \(viewID)") }
    }

    private func nameExists(_ name: String, inProject projectID: String, excluding viewID: String?) throws -> Bool {
        let rows = try database.query(
            "SELECT id FROM saved_view WHERE project_id = ? AND name = ? COLLATE NOCASE;",
            [projectID, name]
        )
        return rows.contains { $0.string("id") != viewID }
    }
}
