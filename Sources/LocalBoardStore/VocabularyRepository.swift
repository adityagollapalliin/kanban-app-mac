import Foundation
import LocalBoardCore

/// The words a project uses for its own work.
///
/// Issue types, priorities, link types and resolutions. Each is keyed by
/// `(project_id, code)` where the code is the integer already stored on the
/// card, so renaming a kind or giving it an icon touches one row and nothing
/// else in the database has to be told.
public struct VocabularyRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - A new project's vocabulary

    /// The words a project starts with.
    ///
    /// Schema 9 seeded every project that existed when it ran. A project made
    /// *after* that gets its vocabulary here, and the two have to agree — a
    /// space created yesterday and one created today must offer the same four
    /// kinds of card under the same four numbers, or a card moved between them
    /// would change kind.
    ///
    /// Idempotent, so calling it on a project that already has a vocabulary
    /// adds nothing and removes nothing.
    public func seedDefaults(forProject projectID: String, createdAt: Date? = nil) throws {
        let now = createdAt ?? clock.now

        try database.transaction {
            for (code, name, symbol, level) in [
                (0, "Epic", "bolt.fill", 1),
                (1, "Story", "bookmark.fill", 0),
                (2, "Task", "checkmark.square", 0),
                (3, "Bug", "ant.fill", 0),
            ] {
                try database.execute(
                    """
                    INSERT INTO issue_type (project_id, code, name, symbol, level, sort_order)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (project_id, code) DO NOTHING;
                    """,
                    [projectID, code, name, symbol, level, Double(code + 1) * SortOrder.step]
                )
            }

            // Rank equals code, which is what keeps `priority >= high` a plain
            // integer comparison. See `PriorityValue.rank`.
            for (code, name, symbol, color) in [
                (0, "Lowest", "chevron.down.2", "secondary"),
                (1, "Low", "chevron.down", "secondary"),
                (2, "Normal", "minus", "secondary"),
                (3, "High", "chevron.up", "orange"),
                (4, "Highest", "chevron.up.2", "red"),
            ] {
                try database.execute(
                    """
                    INSERT INTO priority_value (project_id, code, name, rank, symbol, color, sort_order)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (project_id, code) DO NOTHING;
                    """,
                    [projectID, code, name, code, symbol, color, Double(code + 1) * SortOrder.step]
                )
            }

            for (code, outward, inward, symbol, order) in [
                (0, "Blocks", "Is blocked by", "hand.raised.fill", 1),
                (2, "Relates to", "Relates to", "link", 2),
                (3, "Duplicates", "Is duplicated by", "doc.on.doc", 3),
            ] {
                try database.execute(
                    """
                    INSERT INTO link_type (project_id, code, outward, inward, symbol, sort_order)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (project_id, code) DO NOTHING;
                    """,
                    [projectID, code, outward, inward, symbol, Double(order) * SortOrder.step]
                )
            }

            for (index, name) in ["Done", "Won't Do", "Duplicate", "Cannot Reproduce"].enumerated() {
                try database.execute(
                    """
                    INSERT INTO resolution (id, project_id, name, is_default, sort_order, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (project_id, name) DO NOTHING;
                    """,
                    [UUID().uuidString, projectID, name, index == 0 ? 1 : 0,
                     Double(index + 1) * SortOrder.step, now]
                )
            }
        }
    }

    // MARK: - Issue types

    public func issueTypes(inProject projectID: String) throws -> [IssueType] {
        try database.query(
            "SELECT * FROM issue_type WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ).map(IssueType.init(row:))
    }

    public func issueType(code: Int, inProject projectID: String) throws -> IssueType? {
        try database.queryOne(
            "SELECT * FROM issue_type WHERE project_id = ? AND code = ?;", [projectID, code]
        ).map(IssueType.init(row:))
    }

    /// Adds a kind of card.
    ///
    /// The code is the next free one. Reusing the number of a deleted kind is
    /// safe precisely because deleting one is refused while any card still is
    /// it — trashed cards included, since a trashed card can be brought back.
    @discardableResult
    public func addIssueType(
        inProject projectID: String,
        name: String,
        symbol: String = "square",
        color: String = "",
        level: Int = 0,
        descriptionTemplate: String = ""
    ) throws -> IssueType {
        let trimmed = try requireName(name, "A kind of card needs a name.")
        let existing = try issueTypes(inProject: projectID)
        guard !existing.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw LocalBoardError.invalidInput(
                field: "name", detail: "There is already a kind of card called “\(trimmed)”."
            )
        }

        let code = (existing.map(\.code).max() ?? -1) + 1
        let last = existing.map(\.sortOrder).max()

        try database.execute(
            """
            INSERT INTO issue_type (project_id, code, name, symbol, color, level,
                                    description_template, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [projectID, code, trimmed, symbol, color, level, descriptionTemplate,
             SortOrder.between(last, nil)]
        )

        guard let type = try issueType(code: code, inProject: projectID) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The kind of card was not written.")
        }
        return type
    }

    public func updateIssueType(_ type: IssueType) throws {
        let trimmed = try requireName(type.name, "A kind of card needs a name.")
        let changed = try database.execute(
            """
            UPDATE issue_type SET name = ?, symbol = ?, color = ?, level = ?,
                                  description_template = ?, sort_order = ?
            WHERE project_id = ? AND code = ?;
            """,
            [trimmed, type.symbol, type.color, type.level, type.descriptionTemplate,
             type.sortOrder, type.projectID, type.code]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "issue type \(type.code)") }
    }

    /// Removes a kind of card, refusing while any card still is one.
    ///
    /// The alternative — moving those cards to another kind — is a decision
    /// about somebody's work, and the app has no business making it quietly.
    public func deleteIssueType(code: Int, inProject projectID: String) throws {
        // Trashed cards count. One can be brought back, and a code handed to
        // a different kind in the meantime would silently relabel it.
        let inUse = try database.count(
            "SELECT COUNT(*) FROM task WHERE project_id = ? AND type = ?;",
            [projectID, code]
        )
        guard inUse == 0 else {
            throw LocalBoardError.invalidInput(
                field: "type",
                detail: "\(inUse) card\(inUse == 1 ? "" : "s") still \(inUse == 1 ? "is" : "are") this kind. Change them first."
            )
        }
        let changed = try database.execute(
            "DELETE FROM issue_type WHERE project_id = ? AND code = ?;", [projectID, code]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "issue type \(code)") }
    }

    // MARK: - Priorities

    public func priorities(inProject projectID: String) throws -> [PriorityValue] {
        try database.query(
            "SELECT * FROM priority_value WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ).map(PriorityValue.init(row:))
    }

    /// Renames or re-colours a step of the scale.
    ///
    /// Note what is *not* here: adding a step. `priority >= high` compiles to
    /// an integer comparison against the code, which is only correct while
    /// every rank equals its code. Inserting a step in the middle breaks that,
    /// and the query compiler has to read ranks before it can be allowed —
    /// which is 8.5b's work, behind the language's regression baseline.
    public func updatePriority(_ value: PriorityValue) throws {
        let trimmed = try requireName(value.name, "A priority needs a name.")
        let changed = try database.execute(
            """
            UPDATE priority_value SET name = ?, symbol = ?, color = ?, sort_order = ?
            WHERE project_id = ? AND code = ?;
            """,
            [trimmed, value.symbol, value.color, value.sortOrder, value.projectID, value.code]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "priority \(value.code)") }
    }

    // MARK: - Link types

    public func linkTypes(inProject projectID: String) throws -> [LinkType] {
        try database.query(
            "SELECT * FROM link_type WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ).map(LinkType.init(row:))
    }

    @discardableResult
    public func addLinkType(
        inProject projectID: String,
        outward: String,
        inward: String,
        symbol: String = "link"
    ) throws -> LinkType {
        let out = try requireName(outward, "A link needs a name for the way out.")
        let back = try requireName(inward, "A link needs a name for the way back.")
        let existing = try linkTypes(inProject: projectID)

        // Codes 1 and 4 were the inverse-only spellings of the old enumeration
        // and may still be on links written before v9. Stepping over the whole
        // range in use keeps a new pair from colliding with one.
        let code = max((existing.map(\.code).max() ?? -1) + 1, 5)

        try database.execute(
            """
            INSERT INTO link_type (project_id, code, outward, inward, symbol, sort_order)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [projectID, code, out, back, symbol,
             SortOrder.between(existing.map(\.sortOrder).max(), nil)]
        )

        guard let type = try database.queryOne(
            "SELECT * FROM link_type WHERE project_id = ? AND code = ?;", [projectID, code]
        ).map(LinkType.init(row:)) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The link type was not written.")
        }
        return type
    }

    public func updateLinkType(_ type: LinkType) throws {
        let out = try requireName(type.outward, "A link needs a name for the way out.")
        let back = try requireName(type.inward, "A link needs a name for the way back.")
        let changed = try database.execute(
            """
            UPDATE link_type SET outward = ?, inward = ?, symbol = ?, sort_order = ?
            WHERE project_id = ? AND code = ?;
            """,
            [out, back, type.symbol, type.sortOrder, type.projectID, type.code]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "link type \(type.code)") }
    }

    // MARK: - Resolutions

    public func resolutions(inProject projectID: String) throws -> [Resolution] {
        try database.query(
            "SELECT * FROM resolution WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ).map(Resolution.init(row:))
    }

    public func defaultResolution(inProject projectID: String) throws -> Resolution? {
        try database.queryOne(
            "SELECT * FROM resolution WHERE project_id = ? AND is_default = 1 LIMIT 1;", [projectID]
        ).map(Resolution.init(row:))
    }

    @discardableResult
    public func addResolution(inProject projectID: String, name: String) throws -> Resolution {
        let trimmed = try requireName(name, "A resolution needs a name.")
        let id = UUID().uuidString
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM resolution WHERE project_id = ?;", [projectID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO resolution (id, project_id, name, is_default, sort_order, created_at)
            VALUES (?, ?, ?, 0, ?, ?);
            """,
            [id, projectID, trimmed, SortOrder.between(last, nil), clock.now]
        )

        guard let row = try database.queryOne("SELECT * FROM resolution WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The resolution was not written.")
        }
        return try Resolution(row: row)
    }

    /// Exactly one resolution is the default, so setting one clears the rest
    /// in the same transaction.
    public func setDefaultResolution(_ resolutionID: String) throws {
        try database.transaction {
            guard let row = try database.queryOne(
                "SELECT project_id FROM resolution WHERE id = ?;", [resolutionID]
            ) else {
                throw LocalBoardError.notFound(entity: "resolution \(resolutionID)")
            }
            let projectID = try row.requiredString("project_id")
            try database.execute(
                "UPDATE resolution SET is_default = 0 WHERE project_id = ?;", [projectID]
            )
            try database.execute(
                "UPDATE resolution SET is_default = 1 WHERE id = ?;", [resolutionID]
            )
        }
    }

    public func renameResolution(_ resolutionID: String, to name: String) throws {
        let trimmed = try requireName(name, "A resolution needs a name.")
        let changed = try database.execute(
            "UPDATE resolution SET name = ? WHERE id = ?;", [trimmed, resolutionID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "resolution \(resolutionID)") }
    }

    /// Removes a resolution. Cards that carried it are left with none rather
    /// than being given a different reason for having been closed.
    public func deleteResolution(_ resolutionID: String) throws {
        guard let row = try database.queryOne(
            "SELECT is_default FROM resolution WHERE id = ?;", [resolutionID]
        ) else {
            throw LocalBoardError.notFound(entity: "resolution \(resolutionID)")
        }
        guard row.bool("is_default") != true else {
            throw LocalBoardError.invalidInput(
                field: "resolution",
                detail: "That is the default resolution. Make another one the default first."
            )
        }
        try database.execute("DELETE FROM resolution WHERE id = ?;", [resolutionID])
    }

    // MARK: -

    private func requireName(_ name: String, _ detail: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: detail)
        }
        return trimmed
    }
}
