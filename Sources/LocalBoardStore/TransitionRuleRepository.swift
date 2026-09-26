import Foundation
import LocalBoardCore

/// The rules on a move, and what they say about one card.
///
/// Three questions, asked at three moments:
///
/// * `isOffered` — would this move even appear? Conditions are about the card,
///   so a move that fails one simply is not there, and nobody has to be told
///   why a button they never saw is missing.
/// * `refusal` — may it complete? Validators are about what is missing, so a
///   move that fails one is offered, attempted, and refused with every reason
///   at once rather than one at a time.
/// * `runPostFunctions` — what happens afterwards, which cannot refuse
///   anything and so never runs before the move is written.
public struct TransitionRuleRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - Reading and writing rules

    public func rules(onTransition transitionID: String) throws -> [TransitionRule] {
        try database.query(
            "SELECT * FROM transition_rule WHERE transition_id = ? ORDER BY phase, sort_order;",
            [transitionID]
        ).map(TransitionRule.init(row:))
    }

    /// Every rule in a project, by transition — one query rather than one per
    /// transition, because the board asks about all of them at once whenever
    /// it draws a card's menu.
    public func rulesByTransition(inProject projectID: String) throws -> [String: [TransitionRule]] {
        var found: [String: [TransitionRule]] = [:]
        try database.forEachRow(
            """
            SELECT transition_rule.* FROM transition_rule
            JOIN workflow_transition ON workflow_transition.id = transition_rule.transition_id
            WHERE workflow_transition.project_id = ?
            ORDER BY transition_rule.phase, transition_rule.sort_order;
            """,
            [projectID]
        ) { row in
            found[try row.requiredString("transition_id"), default: []].append(try TransitionRule(row: row))
        }
        return found
    }

    @discardableResult
    public func add(
        _ kind: TransitionRuleKind,
        toTransition transitionID: String,
        target: String = "",
        value: String = "",
        query: String = "",
        syntax: QuerySyntax = .simple
    ) throws -> TransitionRule {
        if kind.needsTarget, target.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LocalBoardError.invalidInput(
                field: "target", detail: "“\(kind.label)” needs to know which one."
            )
        }
        if kind.needsQuery {
            // Checked here rather than when the move is attempted: a rule that
            // does not parse would refuse every move with a message about
            // syntax, which is nobody's idea of a workflow.
            do {
                _ = try TaskQueryParser.parse(query, syntax: syntax)
            } catch let error as QueryError {
                throw LocalBoardError.invalidInput(field: "query", detail: error.message)
            }
        }

        let id = UUID().uuidString
        let last = try database.queryOne(
            """
            SELECT MAX(sort_order) AS last FROM transition_rule
            WHERE transition_id = ? AND phase = ?;
            """,
            [transitionID, kind.phase.rawValue]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO transition_rule (id, transition_id, phase, kind, target, value,
                                         query, syntax, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [id, transitionID, kind.phase.rawValue, kind.rawValue, target, value,
             query, syntax.rawValue, SortOrder.between(last, nil), clock.now]
        )

        guard let row = try database.queryOne("SELECT * FROM transition_rule WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The rule was not written.")
        }
        return try TransitionRule(row: row)
    }

    public func remove(_ ruleID: String) throws {
        let changed = try database.execute("DELETE FROM transition_rule WHERE id = ?;", [ruleID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "rule \(ruleID)") }
    }

    // MARK: - Asking about one card

    /// Whether this move should be offered for this card.
    public func isOffered(_ transitionID: String, forTask taskID: String) throws -> Bool {
        let conditions = try rules(onTransition: transitionID).filter { $0.phase == .condition }
        for condition in conditions where !(try satisfies(condition, taskID: taskID)) {
            return false
        }
        return true
    }

    /// Why this move may not complete, or nil when it may.
    ///
    /// Every failing validator is reported together. Telling somebody they
    /// need a resolution, then — once they have chosen one — that they also
    /// need an estimate, is how a workflow earns its reputation.
    public func refusal(
        _ transitionID: String, forTask taskID: String, transitionName: String
    ) throws -> TransitionRefusal? {
        let validators = try rules(onTransition: transitionID).filter { $0.phase == .validator }
        var reasons: [String] = []

        for validator in validators where !(try satisfies(validator, taskID: taskID)) {
            reasons.append(try describe(validator))
        }

        guard !reasons.isEmpty else { return nil }
        return TransitionRefusal(transitionName: transitionName, reasons: reasons)
    }

    /// Runs what happens after the move, having already been written.
    public func runPostFunctions(_ transitionID: String, forTask taskID: String) throws {
        let after = try rules(onTransition: transitionID).filter { $0.phase == .postFunction }
        guard !after.isEmpty else { return }

        for rule in after {
            switch rule.kind {
            case .clearFlag:
                try database.execute(
                    "UPDATE task SET flagged = 0, flag_reason = '', updated_at = ? WHERE id = ?;",
                    [clock.now, taskID]
                )

            case .assign:
                let person: SQLValue = rule.target.isEmpty ? .null : .text(rule.target)
                try database.execute(
                    "UPDATE task SET assignee_id = ?, updated_at = ? WHERE id = ?;",
                    [person, clock.now, taskID]
                )
                if !rule.target.isEmpty {
                    try database.execute(
                        """
                        INSERT INTO task_assignee (task_id, person_id, estimate, sort_order)
                        VALUES (?, ?, NULL, 1000.0)
                        ON CONFLICT (task_id, person_id) DO NOTHING;
                        """,
                        [taskID, rule.target]
                    )
                }

            case .setResolution:
                try ComponentRepository(database: database, clock: clock)
                    .setResolution(rule.target.isEmpty ? nil : rule.target, forTask: taskID)

            case .addComment:
                guard !rule.value.isEmpty else { continue }
                try database.execute(
                    """
                    INSERT INTO comment (id, task_id, author_id, body_md, created_at)
                    VALUES (?, ?, NULL, ?, ?);
                    """,
                    [UUID().uuidString, taskID, rule.value, clock.now]
                )

            case .setField:
                try setField(FieldReference(stored: rule.target), to: rule.value, on: taskID)

            default:
                // A condition or validator stored with a post-function phase
                // would be a bug rather than input; doing nothing is the right
                // response to one.
                continue
            }
        }
    }

    // MARK: - What a rule means

    private func satisfies(_ rule: TransitionRule, taskID: String) throws -> Bool {
        switch rule.kind {
        case .allSubtasksDone:
            let open = try database.count(
                """
                SELECT COUNT(*) FROM task
                WHERE parent_id = ? AND trashed = 0 AND completed_at IS NULL;
                """,
                [taskID]
            )
            return open == 0

        case .assignedToMe:
            guard let me = try AppSettings(database: database).currentPersonID else { return false }
            let mine = try database.count(
                "SELECT COUNT(*) FROM task WHERE id = ? AND assignee_id = ?;", [taskID, me]
            )
            return mine > 0

        case .matchesQuery:
            guard let projectID = try database.queryOne(
                "SELECT project_id FROM task WHERE id = ?;", [taskID]
            )?.string("project_id") else { return false }
            let matching = try TaskRepository(database: database, clock: clock)
                .tasks(matching: rule.query, inProject: projectID, syntax: rule.syntax)
            return matching.contains { $0.id == taskID }

        case .resolutionRequired:
            return try database.count(
                "SELECT COUNT(*) FROM task WHERE id = ? AND resolution_id IS NOT NULL;", [taskID]
            ) > 0

        case .timeLoggedRequired:
            return try database.count(
                "SELECT COALESCE(SUM(minutes), 0) FROM work_log WHERE task_id = ?;", [taskID]
            ) > 0

        case .commentRequired:
            return try database.count(
                "SELECT COUNT(*) FROM comment WHERE task_id = ?;", [taskID]
            ) > 0

        case .fieldRequired:
            return try isFilledIn(FieldReference(stored: rule.target), on: taskID)

        default:
            // A post-function is not a question, so it never stands in the way.
            return true
        }
    }

    private func describe(_ rule: TransitionRule) throws -> String {
        switch rule.kind {
        case .resolutionRequired: return "a resolution"
        case .timeLoggedRequired: return "some time logged against it"
        case .commentRequired: return "a comment"
        case .fieldRequired:
            let field = FieldReference(stored: rule.target)
            switch field {
            case .builtIn(let name):
                return "a \(name)"
            case .custom(let id):
                let name = try database.queryOne(
                    "SELECT name FROM custom_field WHERE id = ?;", [id]
                )?.string("name")
                return "a value for \(name ?? "a field")"
            }
        default: return rule.kind.label
        }
    }

    // MARK: - Fields, by reference

    /// The columns a built-in field reference reads and writes.
    private static let builtInColumns: [String: String] = [
        "assignee": "assignee_id", "due": "due_date", "start": "start_date",
        "priority": "priority", "estimate": "estimate", "description": "description_md",
        "environment": "environment", "version": "version_id", "sprint": "sprint_id",
        "epic": "epic_id",
    ]

    public func isFilledIn(_ field: FieldReference, on taskID: String) throws -> Bool {
        switch field {
        case .builtIn("resolution"):
            return try database.count(
                "SELECT COUNT(*) FROM task WHERE id = ? AND resolution_id IS NOT NULL;", [taskID]
            ) > 0

        case .builtIn(let name):
            guard let column = Self.builtInColumns[name] else { return true }
            // Text columns count as empty when they are blank, not only when
            // they are NULL — `description_md` defaults to an empty string.
            return try database.count(
                """
                SELECT COUNT(*) FROM task
                WHERE id = ? AND \(column) IS NOT NULL AND TRIM(CAST(\(column) AS TEXT)) <> '';
                """,
                [taskID]
            ) > 0

        case .custom(let fieldID):
            return try database.count(
                """
                SELECT COUNT(*) FROM custom_field_value
                WHERE task_id = ? AND field_id = ?
                  AND (text_value IS NOT NULL OR number_value IS NOT NULL
                       OR date_value IS NOT NULL OR bool_value IS NOT NULL);
                """,
                [taskID, fieldID]
            ) > 0
        }
    }

    /// Writes a field named by reference.
    ///
    /// Dates are read the way the query language reads them, so `+7d` in a
    /// post-function means a week from the move rather than a literal string
    /// nobody can use.
    public func setField(_ field: FieldReference, to value: String, on taskID: String) throws {
        switch field {
        case .builtIn("resolution"):
            try ComponentRepository(database: database, clock: clock)
                .setResolution(value.isEmpty ? nil : value, forTask: taskID)

        case .builtIn(let name):
            guard let column = Self.builtInColumns[name] else { return }
            let bound: SQLValue
            if value.isEmpty {
                bound = .null
            } else if ["due", "start"].contains(name) {
                guard let date = RelativeDate.parse(value) else {
                    throw LocalBoardError.invalidInput(
                        field: name, detail: "`\(value)` is not a date. Try 2026-10-01, today or +7d."
                    )
                }
                bound = .real(date.resolve(now: clock.now).timeIntervalSince1970)
            } else if name == "priority" {
                guard let number = Int(value) else {
                    throw LocalBoardError.invalidInput(
                        field: name, detail: "A priority is a number from 0 to 4."
                    )
                }
                bound = .integer(Int64(number))
            } else if name == "estimate" {
                guard let number = Double(value) else {
                    throw LocalBoardError.invalidInput(field: name, detail: "An estimate is a number.")
                }
                bound = .real(number)
            } else {
                bound = .text(value)
            }
            try database.execute(
                "UPDATE task SET \(column) = ?, updated_at = ? WHERE id = ?;",
                [bound, clock.now, taskID]
            )

        case .custom(let fieldID):
            guard let kindRaw = try database.queryOne(
                "SELECT kind FROM custom_field WHERE id = ?;", [fieldID]
            )?.int("kind"), let kind = CustomFieldKind(rawValue: Int(kindRaw)) else { return }

            let fields = CustomFieldRepository(database: database, clock: clock)
            guard !value.isEmpty else {
                try fields.setValue(nil, forField: fieldID, onTask: taskID)
                return
            }

            switch kind.storage {
            case .text:
                try fields.setValue(
                    kind == .choice ? .choice(value) : .text(value), forField: fieldID, onTask: taskID
                )
            case .number:
                if let number = Double(value) {
                    try fields.setValue(.number(number), forField: fieldID, onTask: taskID)
                }
            case .date:
                if let date = RelativeDate.parse(value) {
                    try fields.setValue(
                        .date(date.resolve(now: clock.now)), forField: fieldID, onTask: taskID
                    )
                }
            case .boolean:
                let ticked = ["yes", "true", "1", "on"].contains(value.lowercased())
                try fields.setValue(ticked ? .checkbox(true) : nil, forField: fieldID, onTask: taskID)
            case .computed:
                // Works itself out; there is nothing to set.
                return
            }
        }
    }
}
