import Foundation
import LocalBoardCore

/// Which fields each kind of card shows, insists on, and starts with.
///
/// A row is a *departure* from the default. No rows means every field shows
/// and none is required, which is how the app behaved before this existed —
/// so a project that never opens this screen notices nothing.
public struct FieldConfigRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    public func configurations(inProject projectID: String, forType code: Int) throws -> [FieldConfiguration] {
        try database.query(
            """
            SELECT * FROM field_config
            WHERE project_id = ? AND issue_type_code = ? ORDER BY sort_order;
            """,
            [projectID, code]
        ).map(FieldConfiguration.init(row:))
    }

    /// Every kind's configuration at once, keyed by issue-type code.
    public func configurationsByType(inProject projectID: String) throws -> [Int: [FieldConfiguration]] {
        var found: [Int: [FieldConfiguration]] = [:]
        try database.forEachRow(
            "SELECT * FROM field_config WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ) { row in
            found[try row.requiredInt("issue_type_code"), default: []].append(try FieldConfiguration(row: row))
        }
        return found
    }

    /// Records a departure from the default for one field of one kind.
    ///
    /// A configuration that says nothing — shown, not required, no default —
    /// deletes the row instead of storing it, so the table holds only the
    /// decisions somebody actually made.
    public func set(
        inProject projectID: String,
        forType code: Int,
        field: FieldReference,
        shown: Bool,
        required: Bool,
        defaultValue: String
    ) throws {
        let trimmed = defaultValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !(shown && !required && trimmed.isEmpty) else {
            try database.execute(
                """
                DELETE FROM field_config
                WHERE project_id = ? AND issue_type_code = ? AND field_ref = ?;
                """,
                [projectID, code, field.stored]
            )
            return
        }

        // A field nobody can see cannot also be one they must fill in. Storing
        // both would make a card impossible to create and impossible to fix.
        guard !(required && !shown) else {
            throw LocalBoardError.invalidInput(
                field: "required",
                detail: "A field that is hidden cannot also be required — there would be no way to fill it in."
            )
        }

        let last = try database.queryOne(
            """
            SELECT MAX(sort_order) AS last FROM field_config
            WHERE project_id = ? AND issue_type_code = ?;
            """,
            [projectID, code]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO field_config (id, project_id, issue_type_code, field_ref, shown,
                                      required, default_value, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (project_id, issue_type_code, field_ref) DO UPDATE SET
                shown = ?, required = ?, default_value = ?;
            """,
            [UUID().uuidString, projectID, code, field.stored, shown ? 1 : 0,
             required ? 1 : 0, trimmed, SortOrder.between(last, nil),
             shown ? 1 : 0, required ? 1 : 0, trimmed]
        )
    }

    /// Whether a field is shown for a kind of card.
    public func isShown(_ field: FieldReference, forType code: Int, inProject projectID: String) throws -> Bool {
        guard let row = try database.queryOne(
            """
            SELECT shown FROM field_config
            WHERE project_id = ? AND issue_type_code = ? AND field_ref = ?;
            """,
            [projectID, code, field.stored]
        ) else { return true }
        return row.bool("shown") ?? true
    }

    /// The fields a card of this kind must have filled in, and has not.
    ///
    /// Asked when a card is saved rather than when it is created: a card is
    /// often made from a title alone and filled in afterwards, and refusing to
    /// create one until every required field is answered would make the quick
    /// add useless.
    public func missingRequired(forTask taskID: String) throws -> [String] {
        guard let row = try database.queryOne(
            "SELECT project_id, type FROM task WHERE id = ?;", [taskID]
        ) else { return [] }

        let projectID = try row.requiredString("project_id")
        let code = try row.requiredInt("type")

        let required = try configurations(inProject: projectID, forType: code).filter(\.required)
        guard !required.isEmpty else { return [] }

        let rules = TransitionRuleRepository(database: database, clock: clock)
        var missing: [String] = []

        for configuration in required where !(try rules.isFilledIn(configuration.field, on: taskID)) {
            switch configuration.field {
            case .builtIn(let name):
                missing.append(name)
            case .custom(let id):
                let name = try database.queryOne(
                    "SELECT name FROM custom_field WHERE id = ?;", [id]
                )?.string("name")
                missing.append(name ?? "a field")
            }
        }
        return missing
    }

    /// Fills in a new card's defaults for its kind.
    ///
    /// Run after the card exists rather than folded into its insert, because
    /// a default can be a date expression, a custom field's value or a
    /// resolution — three different tables — and one of them failing should
    /// not lose the card.
    public func applyDefaults(toTask taskID: String) throws {
        guard let row = try database.queryOne(
            "SELECT project_id, type FROM task WHERE id = ?;", [taskID]
        ) else { return }

        let projectID = try row.requiredString("project_id")
        let code = try row.requiredInt("type")
        let defaults = try configurations(inProject: projectID, forType: code)
            .filter { !$0.defaultValue.isEmpty }
        guard !defaults.isEmpty else { return }

        let rules = TransitionRuleRepository(database: database, clock: clock)
        for configuration in defaults {
            // A default that will not apply is skipped rather than fatal: the
            // card is already made, and losing it over a mistyped default
            // would be a poor trade.
            try? rules.setField(configuration.field, to: configuration.defaultValue, on: taskID)
        }
    }
}
