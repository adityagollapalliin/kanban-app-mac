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
    public func create(
        inProject projectID: String,
        name: String,
        query: String,
        syntax: QuerySyntax = .simple
    ) throws -> SavedView {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A view needs a name.")
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try TaskQueryParser.parse(trimmedQuery, syntax: syntax)

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
            INSERT INTO saved_view (id, project_id, name, query, syntax, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [id, projectID, trimmedName, trimmedQuery, syntax.rawValue,
             SortOrder.between(last, nil), now]
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

    /// Changes a view's query, in whichever language it is written in.
    ///
    /// A view's syntax is *not* changed here. Moving a filter from one
    /// language to the other is `convert(_:)`, which is a deliberate act with
    /// a preview — never something that happens because somebody edited the
    /// text.
    public func setQuery(_ query: String, for viewID: String) throws {
        let existing = try view(id: viewID)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try TaskQueryParser.parse(trimmed, syntax: existing.syntax)

        let changed = try database.execute("UPDATE saved_view SET query = ? WHERE id = ?;", [trimmed, viewID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "view \(viewID)") }
    }

    public func setStarred(_ starred: Bool, for viewID: String) throws {
        let changed = try database.execute(
            "UPDATE saved_view SET starred = ? WHERE id = ?;", [starred ? 1 : 0, viewID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "view \(viewID)") }
    }

    public func setColumns(_ columns: [String], for viewID: String) throws {
        let changed = try database.execute(
            "UPDATE saved_view SET columns = ? WHERE id = ?;",
            [SavedView.storedColumns(columns), viewID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "view \(viewID)") }
    }

    // MARK: - Moving a filter to the other language

    /// What converting a filter would do, worked out without saving anything.
    ///
    /// Two questions are answered, because both matter and only one of them is
    /// obvious: does the text still parse, and does it still match the same
    /// cards. A query can survive the first and fail the second — `ORDER BY
    /// due` parses in both languages and means completely different things.
    public struct ConversionPreview: Sendable, Equatable {
        public var from: QuerySyntax
        public var to: QuerySyntax
        public var query: String
        /// Nil when it parses; the reason when it does not.
        public var problem: String?
        public var matchesBefore: Int
        public var matchesAfter: Int

        public var parses: Bool { problem == nil }
        public var resultsChange: Bool { parses && matchesBefore != matchesAfter }
    }

    public func previewConversion(_ viewID: String, to syntax: QuerySyntax) throws -> ConversionPreview {
        let existing = try view(id: viewID)
        let tasks = TaskRepository(database: database, clock: clock)

        let before = (try? tasks.tasks(
            matching: existing.query, inProject: existing.projectID, syntax: existing.syntax
        ).count) ?? 0

        var preview = ConversionPreview(
            from: existing.syntax, to: syntax, query: existing.query,
            problem: nil, matchesBefore: before, matchesAfter: before
        )

        do {
            _ = try TaskQueryParser.parse(existing.query, syntax: syntax)
            preview.matchesAfter = try tasks.tasks(
                matching: existing.query, inProject: existing.projectID, syntax: syntax
            ).count
        } catch let error as QueryError {
            preview.problem = error.message
        } catch {
            preview.problem = error.localizedDescription
        }

        return preview
    }

    /// Moves a filter to the other language, refusing one that would break.
    ///
    /// Never called on the user's behalf. A filter's language changes because
    /// somebody asked for it to, having been shown what it would do.
    public func convert(_ viewID: String, to syntax: QuerySyntax) throws {
        let preview = try previewConversion(viewID, to: syntax)
        guard preview.parses else {
            throw LocalBoardError.invalidInput(
                field: "query",
                detail: "This filter does not read as \(syntax.label.lowercased()): \(preview.problem ?? "")"
            )
        }
        let changed = try database.execute(
            "UPDATE saved_view SET syntax = ? WHERE id = ?;", [syntax.rawValue, viewID]
        )
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
