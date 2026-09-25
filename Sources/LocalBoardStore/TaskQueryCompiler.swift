import Foundation
import LocalBoardCore

/// Turns a parsed filter into a WHERE clause and the values to bind to it.
///
/// Note what is not here: string interpolation of anything the user typed. The
/// clause is assembled from fixed fragments and `?` placeholders; every value
/// travels in the parameter array. A title of `'; DROP TABLE task; --` is
/// compiled to `title LIKE ?` and bound as a string, which is the only reason
/// a search field can be pointed at a database at all.
struct TaskQueryCompiler {

    struct Compiled {
        let whereClause: String
        let parameters: [SQLValue]
    }

    /// Needed only to look up what kind of thing a project's own fields hold.
    /// Everything else here is pure.
    let database: Database
    let projectID: String
    let now: Date
    let calendar: Calendar
    /// Who "me" is, for `is:mine`. Nil when nobody has been chosen in
    /// Settings, in which case `is:mine` matches nothing rather than
    /// everything — an unanswered question has no answers.
    let currentPersonID: String?

    init(
        database: Database,
        projectID: String,
        now: Date,
        calendar: Calendar = .current,
        currentPersonID: String? = nil
    ) {
        self.database = database
        self.projectID = projectID
        self.now = now
        self.calendar = calendar
        self.currentPersonID = currentPersonID
    }

    func compile(_ filter: TaskFilter) throws -> Compiled {
        var parameters: [SQLValue] = []
        let clause = try fragment(filter, into: &parameters)
        return Compiled(whereClause: clause, parameters: parameters)
    }

    /// `ORDER BY due DESC` as SQL, or nil when the query did not ask.
    ///
    /// Built from the same `columnName` the comparisons use, so a field can
    /// never be orderable by one spelling and filterable by another. Nothing
    /// is interpolated that did not come from the enumeration.
    func orderClause(_ order: [QueryOrder]) throws -> String? {
        guard !order.isEmpty else { return nil }

        var parts: [String] = []
        for clause in order {
            let column: String
            switch clause.field {
            case .due, .start, .created, .updated, .completed, .priority, .type, .points, .title:
                column = "task.\(try columnName(for: clause.field))"
            case .key:
                // The number, not the text: WORK-9 sorts before WORK-10.
                column = "task.number"
            default:
                throw QueryError(
                    "`\(clause.field.rawValue)` lives in another table, so this cannot order by it yet."
                )
            }

            // Unset dates sort last whichever way round it is, because a card
            // with no due date is not the most urgent thing on the board.
            let nulls = clause.field.isDate ? "(\(column) IS NULL), " : ""
            parts.append("\(nulls)\(column) \(clause.ascending ? "ASC" : "DESC")")
        }
        return parts.joined(separator: ", ")
    }


    // MARK: - Fragments

    private func fragment(_ filter: TaskFilter, into parameters: inout [SQLValue]) throws -> String {
        switch filter {
        case .all:
            return "1"

        case .and(let branches):
            let parts = try branches.map { try fragment($0, into: &parameters) }
            return parts.isEmpty ? "1" : "(" + parts.joined(separator: " AND ") + ")"

        case .or(let branches):
            let parts = try branches.map { try fragment($0, into: &parameters) }
            return parts.isEmpty ? "1" : "(" + parts.joined(separator: " OR ") + ")"

        case .not(let inner):
            return "NOT (" + (try fragment(inner, into: &parameters)) + ")"

        case .text(let text):
            let expression = TaskRepository.ftsExpression(for: text)
            guard !expression.isEmpty else { return "1" }
            parameters.append(.text(expression))
            return "task.rowid IN (SELECT rowid FROM task_fts WHERE task_fts MATCH ?)"

        case .flag(let flag):
            return self.fragment(for: flag, into: &parameters)

        case .comparison(let field, let comparison, let value):
            return try fragment(field: field, comparison: comparison, value: value, into: &parameters)

        case .customField(let name, let comparison, let value):
            return try customFragment(name: name, comparison: comparison, value: value, into: &parameters)

        // MARK: The JQL-only shapes
        //
        // Each is expressed in terms of the fragments above rather than as new
        // SQL: `IN` is a run of equalities, `IS EMPTY` is the `none` path that
        // has always existed. One place decides what a field compares against,
        // so a new operator cannot disagree with the old ones about it.

        case .membership(let target, let values, let negated):
            guard !values.isEmpty else { return negated ? "1" : "0" }
            let parts = try values.map { value in
                try fragment(target: target, comparison: .equals, value: value, into: &parameters)
            }
            let any = "(" + parts.joined(separator: " OR ") + ")"
            return negated ? "NOT \(any)" : any

        case .emptiness(let target, let negated):
            return try fragment(
                target: target,
                comparison: negated ? .notEquals : .equals,
                value: .none,
                into: &parameters
            )

        case .contains(let target, let text):
            return try containsFragment(target: target, text: text, into: &parameters)

        case .history(let clause):
            return try historyFragment(clause, into: &parameters)
        }
    }

    /// Dispatches to the field or custom-field path, whichever the target is.
    private func fragment(
        target: QueryTarget,
        comparison: QueryComparison,
        value: QueryValue,
        into parameters: inout [SQLValue]
    ) throws -> String {
        switch target {
        case .field(let field):
            return try fragment(field: field, comparison: comparison, value: value, into: &parameters)
        case .custom(let name):
            return try customFragment(name: name, comparison: comparison, value: value, into: &parameters)
        }
    }

    /// `title ~ login` — contains, matched as a substring.
    ///
    /// Deliberately `LIKE` rather than the full-text index: `~` is written to
    /// find a fragment of a word, and FTS matches whole tokens with a prefix.
    /// `title ~ ogin` finds nothing through FTS and the card through this.
    private func containsFragment(
        target: QueryTarget,
        text: String,
        into parameters: inout [SQLValue]
    ) throws -> String {
        let pattern = "%" + Self.escapingLikeWildcards(text) + "%"

        switch target {
        case .field(let field):
            switch field {
            case .title:
                parameters.append(.text(pattern))
                return "task.title LIKE ? ESCAPE '\\'"
            case .status, .assignee, .label, .version, .epic, .sprint, .key:
                // These are names held in other tables; comparing them loosely
                // is the same join with LIKE in place of `=`.
                let exact = try fragment(target: target, comparison: .equals, value: .text(text), into: &parameters)
                return exact.replacingOccurrences(of: "name = ? COLLATE NOCASE", with: "name LIKE '%' || ? || '%' COLLATE NOCASE")
            default:
                throw QueryError("`~` looks inside text, and `\(field.rawValue)` does not hold any.")
            }

        case .custom(let name):
            guard let kind = try customFieldKinds()[name.lowercased()] else {
                throw QueryError("there is no field called `\(name)` in this project.")
            }
            guard kind.storage == .text else {
                throw QueryError("`~` looks inside text, and `\(name)` does not hold any.")
            }
            parameters.append(.text(projectID))
            parameters.append(.text(name))
            parameters.append(.text(pattern))
            return """
                task.id IN (
                    SELECT custom_field_value.task_id FROM custom_field_value
                    JOIN custom_field ON custom_field.id = custom_field_value.field_id
                    WHERE custom_field.project_id = ? AND custom_field.name = ? COLLATE NOCASE
                      AND custom_field_value.text_value LIKE ? ESCAPE '\\')
                """
        }
    }

    /// `status WAS "In Progress"`, `status CHANGED FROM x TO y DURING (a, b)`.
    ///
    /// Answered from `status_change`, which has recorded every move since
    /// schema 3 and was backfilled to each card's creation — so this is a real
    /// answer about the whole of a card's life, not only since the feature
    /// arrived. No other field has ever been recorded, which is why the parser
    /// refuses to ask about one.
    private func historyFragment(
        _ clause: HistoryClause,
        into parameters: inout [SQLValue]
    ) throws -> String {
        var conditions: [String] = ["status_change.task_id = task.id"]

        func statusClause(_ value: QueryValue, column: String) throws {
            guard case .text(let name) = value else {
                throw QueryError("`\(column)` needs a column name, like \"In Progress\".")
            }
            parameters.append(.text(projectID))
            parameters.append(.text(name))
            conditions.append("""
                status_change.\(column) IN (
                    SELECT id FROM status WHERE project_id = ? AND name = ? COLLATE NOCASE)
                """)
        }

        switch clause.kind {
        case .was:
            guard let value = clause.value else {
                throw QueryError("`WAS` needs a status.")
            }
            try statusClause(value, column: "to_status_id")

        case .changed:
            if let from = clause.from { try statusClause(from, column: "from_status_id") }
            if let to = clause.to { try statusClause(to, column: "to_status_id") }
            // A bare `status CHANGED` is "moved at all", which every card has
            // done once at creation — so it means "moved more than once".
            if clause.from == nil, clause.to == nil {
                conditions.append("status_change.from_status_id IS NOT NULL")
            }
        }

        if let start = clause.duringStart, let end = clause.duringEnd {
            parameters.append(.real(start.resolve(now: now, calendar: calendar).timeIntervalSince1970))
            parameters.append(.real(end.resolve(now: now, calendar: calendar).timeIntervalSince1970))
            conditions.append("status_change.at >= ?")
            conditions.append("status_change.at <= ?")
        }

        let exists = "EXISTS (SELECT 1 FROM status_change WHERE " + conditions.joined(separator: " AND ") + ")"
        return clause.negated ? "NOT \(exists)" : exists
    }

    /// `cf:Size >= 3`.
    ///
    /// The field's declared kind decides which column is compared and how the
    /// typed text is read — which is the whole reason values are stored in
    /// typed columns. A number field compared as text would put 10 before 9.
    private func customFragment(
        name: String,
        comparison: QueryComparison,
        value: QueryValue,
        into parameters: inout [SQLValue]
    ) throws -> String {
        guard let kind = try customFieldKinds()[name.lowercased()] else {
            throw QueryError("there is no field called `\(name)` in this project.")
        }

        let membership = """
            task.id IN (
                SELECT custom_field_value.task_id FROM custom_field_value
                JOIN custom_field ON custom_field.id = custom_field_value.field_id
                WHERE custom_field.project_id = ? AND custom_field.name = ? COLLATE NOCASE
            """

        // `cf:Size = none` asks whether it has been filled in at all, which is
        // a question about the row's existence rather than about its contents.
        if case .none = value {
            parameters.append(.text(projectID))
            parameters.append(.text(name))
            let exists = membership + ")"
            return comparison == .equals ? "NOT (\(exists))" : exists
        }

        guard case .text(let raw) = value else {
            throw QueryError("`cf:\(name)` needs something to compare against.")
        }

        let column: String
        let bound: SQLValue

        // A formula and a rollup are worked out when a card is drawn, not
        // stored, so there is no column for SQL to compare. Saying so beats
        // returning nothing and letting the user conclude their cards vanished.
        if kind.isComputed {
            throw QueryError("`\(name)` is worked out from other fields, so it can't be searched on.")
        }

        switch kind.storage {
        case .text:
            column = "text_value"
            // Text matches loosely and a choice matches exactly: half a word
            // is a reasonable way to search prose and a poor way to pick from
            // a list. A relationship holds ids, and matching one loosely is
            // how "cards linked to this one" is asked for.
            if kind != .choice {
                parameters.append(.text(projectID))
                parameters.append(.text(name))
                parameters.append(.text("%" + Self.escapingLikeWildcards(raw) + "%"))
                let clause = membership + " AND custom_field_value.text_value LIKE ? ESCAPE '\\')"
                return comparison == .notEquals ? "NOT (\(clause))" : clause
            }
            bound = .text(raw)

        case .number:
            guard let amount = Double(raw) else {
                throw QueryError("`\(name)` holds numbers, and `\(raw)` is not one.")
            }
            column = "number_value"
            bound = .real(amount)

        case .date:
            guard let date = RelativeDate.parse(raw) else {
                throw QueryError("`\(name)` holds dates. Try 2026-10-01, today or +7d.")
            }
            column = "date_value"
            bound = .real(date.resolve(now: now, calendar: calendar).timeIntervalSince1970)

        case .boolean:
            let ticked = ["yes", "true", "1", "on"].contains(raw.lowercased())
            column = "bool_value"
            bound = .integer(ticked ? 1 : 0)

        case .computed:
            // Refused above; the compiler cannot know that.
            throw QueryError("`\(name)` can't be searched on.")
        }

        parameters.append(.text(projectID))
        parameters.append(.text(name))
        parameters.append(bound)

        let clause = membership + " AND custom_field_value.\(column) \(Self.sqlOperator(comparison)) ?)"
        return clause
    }

    /// The project's field names and kinds, lowercased for lookup.
    private func customFieldKinds() throws -> [String: CustomFieldKind] {
        var kinds: [String: CustomFieldKind] = [:]
        try database.forEachRow(
            "SELECT name, kind FROM custom_field WHERE project_id = ?;", [projectID]
        ) { row in
            kinds[try row.requiredString("name").lowercased()] =
                try row.requiredEnum("kind", CustomFieldKind.self)
        }
        return kinds
    }

    /// Resolves a function used where a value is expected.
    ///
    /// Each one answers a question about *now* — who I am, which sprints are
    /// running, what has shipped — so none of them can be folded into the
    /// stored query. They are resolved every time it is compiled, which is why
    /// a saved filter using `currentUser()` means the right thing on a Mac it
    /// was not written on.
    private func fragment(
        field: QueryField,
        comparison: QueryComparison,
        function: QueryFunction,
        into parameters: inout [SQLValue]
    ) throws -> String {
        let negate = comparison == .notEquals

        func wrap(_ clause: String) -> String { negate ? "NOT (\(clause))" : clause }

        switch (field, function) {
        case (.assignee, .currentUser):
            // Nobody chosen in Settings means `currentUser()` matches nothing,
            // exactly as `is:mine` does. An unanswered question has no answers.
            guard let currentPersonID else { return negate ? "1" : "0" }
            parameters.append(.text(currentPersonID))
            return wrap("task.assignee_id = ?")

        case (.sprint, .openSprints), (.sprint, .closedSprints):
            let state = function == .openSprints ? SprintState.active : .complete
            parameters.append(.text(projectID))
            parameters.append(.integer(Int64(state.rawValue)))
            return wrap("""
                task.sprint_id IN (
                    SELECT id FROM sprint WHERE project_id = ? AND state = ?)
                """)

        case (.version, .releasedVersions), (.version, .unreleasedVersions):
            parameters.append(.text(projectID))
            parameters.append(.integer(function == .releasedVersions ? 1 : 0))
            return wrap("""
                task.version_id IN (
                    SELECT id FROM version WHERE project_id = ? AND released = ?)
                """)

        case (.key, .linkedIssues(let key)):
            // Both ends of the link, because "linked to WORK-12" does not
            // depend on which card the link was made from.
            parameters.append(.text(projectID))
            parameters.append(.text(key.uppercased()))
            parameters.append(.text(projectID))
            parameters.append(.text(key.uppercased()))
            return wrap("""
                (task.id IN (
                    SELECT task_link.other_task_id FROM task_link
                    JOIN task AS anchor ON anchor.id = task_link.task_id
                    JOIN project ON project.id = anchor.project_id
                    WHERE anchor.project_id = ? AND project.key || '-' || anchor.number = ?)
                 OR task.id IN (
                    SELECT task_link.task_id FROM task_link
                    JOIN task AS anchor ON anchor.id = task_link.other_task_id
                    JOIN project ON project.id = anchor.project_id
                    WHERE anchor.project_id = ? AND project.key || '-' || anchor.number = ?))
                """)

        default:
            throw QueryError(
                "`\(function.described)` cannot be used with `\(field.rawValue)`."
            )
        }
    }

    private func fragment(for flag: QueryFlag, into parameters: inout [SQLValue]) -> String {
        switch flag {
        case .done:
            return "task.completed_at IS NOT NULL"
        case .open:
            return "task.completed_at IS NULL"
        case .overdue:
            // Unfinished, dated, and the day has passed.
            parameters.append(.real(calendar.startOfDay(for: now).timeIntervalSince1970))
            return "(task.completed_at IS NULL AND task.due_date IS NOT NULL AND task.due_date < ?)"
        case .trashed:
            return "task.trashed = 1"
        case .assigned:
            return "task.assignee_id IS NOT NULL"
        case .unassigned:
            return "task.assignee_id IS NULL"
        case .subtask:
            return "task.parent_id IS NOT NULL"
        case .labelled:
            return "task.id IN (SELECT task_id FROM task_label)"
        case .flagged:
            return "task.flagged = 1"
        case .mine:
            guard let currentPersonID else { return "0" }
            parameters.append(.text(currentPersonID))
            return "task.assignee_id = ?"
        case .epic:
            parameters.append(.integer(Int64(TaskType.epic.rawValue)))
            return "task.type = ?"
        case .released:
            return "task.version_id IN (SELECT id FROM version WHERE released = 1)"
        case .backlog:
            // A card is in the backlog when the column showing its status is
            // marked as one. That is a property of the board, not of the card,
            // so it is asked of the mapping rather than of the task.
            return """
                task.status_id IN (
                    SELECT column_status.status_id FROM column_status
                    JOIN board_column ON board_column.id = column_status.column_id
                    WHERE board_column.is_backlog = 1
                )
                """
        }
    }

    private func fragment(
        field: QueryField,
        comparison: QueryComparison,
        value: QueryValue,
        into parameters: inout [SQLValue]
    ) throws -> String {
        // A function standing in for a value is resolved first, against the
        // clock, the settings or the database. Date functions never reach here
        // — the parser folds those into an ordinary relative date, so there is
        // still one path for dates.
        if case .function(let function) = value {
            return try fragment(
                field: field, comparison: comparison, function: function, into: &parameters
            )
        }

        // `epic = none` is about the link, and `version = none` about the
        // release; both live on the task itself, so the generic presence path
        // below handles them once `columnName` knows their columns.
        //
        // `due = none` and `assignee != none` are about presence, whatever the
        // column's type.
        if case .none = value, field == .label {
            return comparison == .notEquals
                ? "task.id IN (SELECT task_id FROM task_label)"
                : "task.id NOT IN (SELECT task_id FROM task_label)"
        }

        if case .none = value {
            let column = try columnName(for: field)
            switch comparison {
            case .equals: return "task.\(column) IS NULL"
            case .notEquals: return "task.\(column) IS NOT NULL"
            default:
                throw QueryError("`none` can only be used with `=` or `!=`.")
            }
        }

        switch field {
        case .due, .start, .created, .updated, .completed:
            guard case .date(let relative) = value else {
                throw QueryError("`\(field.rawValue)` takes a date, like 2026-10-01, today or +7d.")
            }
            return dateFragment(
                column: try columnName(for: field),
                comparison: comparison,
                date: relative,
                into: &parameters
            )

        case .priority:
            guard case .priority(let priority) = value else {
                throw QueryError("`priority` takes lowest, low, normal, high or highest.")
            }
            parameters.append(.integer(Int64(priority.rawValue)))
            return "task.priority \(Self.sqlOperator(comparison)) ?"

        case .type:
            guard case .type(let type) = value else {
                throw QueryError("`type` takes epic, story, task or bug.")
            }
            parameters.append(.integer(Int64(type.rawValue)))
            return "task.type \(Self.sqlOperator(comparison)) ?"

        case .status:
            guard case .text(let name) = value else {
                throw QueryError("`status` takes a column name, like \"In Progress\".")
            }
            parameters.append(.text(projectID))
            parameters.append(.text(name))
            let subquery = "SELECT id FROM status WHERE project_id = ? AND name = ? COLLATE NOCASE"
            return comparison == .notEquals
                ? "task.status_id NOT IN (\(subquery))"
                : "task.status_id IN (\(subquery))"

        case .assignee:
            guard case .text(let name) = value else {
                throw QueryError("`assignee` takes a person's name.")
            }
            parameters.append(.text(name))
            let subquery = "SELECT id FROM person WHERE name = ? COLLATE NOCASE"
            return comparison == .notEquals
                ? "task.assignee_id NOT IN (\(subquery))"
                : "task.assignee_id IN (\(subquery))"

        case .label:
            guard case .text(let name) = value else {
                throw QueryError("`label` takes a label's name.")
            }
            parameters.append(.text(projectID))
            parameters.append(.text(name))
            let subquery = """
                SELECT task_label.task_id FROM task_label
                JOIN label ON label.id = task_label.label_id
                WHERE label.project_id = ? AND label.name = ? COLLATE NOCASE
                """
            return comparison == .notEquals
                ? "task.id NOT IN (\(subquery))"
                : "task.id IN (\(subquery))"

        case .points:
            guard case .number(let amount) = value else {
                throw QueryError("`points` takes a number, like `points >= 3`.")
            }
            parameters.append(.real(amount))
            // A card with no estimate is not "0 points", it is unestimated, so
            // it stays out of every numeric comparison rather than counting
            // as the smallest one.
            return "(task.estimate IS NOT NULL AND task.estimate \(Self.sqlOperator(comparison)) ?)"

        case .days:
            guard case .number(let amount) = value else {
                throw QueryError("`days` takes a number, like `days >= 5`.")
            }
            return daysInColumnFragment(comparison: comparison, days: amount, into: &parameters)

        case .key:
            guard case .text(let text) = value else {
                throw QueryError("`key` takes a card tag, like WORK-14.")
            }
            return keyFragment(text, comparison: comparison, into: &parameters)

        case .version:
            guard case .text(let name) = value else {
                throw QueryError("`version` takes a release name.")
            }
            parameters.append(.text(projectID))
            parameters.append(.text(name))
            let subquery = "SELECT id FROM version WHERE project_id = ? AND name = ? COLLATE NOCASE"
            return comparison == .notEquals
                ? "task.version_id NOT IN (\(subquery))"
                : "task.version_id IN (\(subquery))"

        case .epic:
            guard case .text(let text) = value else {
                throw QueryError("`epic` takes an epic's title or key.")
            }
            return epicFragment(text, comparison: comparison, into: &parameters)

        case .sprint:
            guard case .text(let name) = value else {
                throw QueryError("`sprint` takes a sprint's name, or `active`.")
            }
            // `sprint = active` is the one people actually want to type, and
            // it survives the sprint being renamed or replaced.
            if name.lowercased() == "active" {
                parameters.append(.text(projectID))
                parameters.append(.integer(Int64(SprintState.active.rawValue)))
                let subquery = "SELECT id FROM sprint WHERE project_id = ? AND state = ?"
                return comparison == .notEquals
                    ? "task.sprint_id NOT IN (\(subquery))"
                    : "task.sprint_id IN (\(subquery))"
            }
            parameters.append(.text(projectID))
            parameters.append(.text(name))
            let subquery = "SELECT id FROM sprint WHERE project_id = ? AND name = ? COLLATE NOCASE"
            return comparison == .notEquals
                ? "task.sprint_id NOT IN (\(subquery))"
                : "task.sprint_id IN (\(subquery))"

        case .flag:
            guard case .text(let text) = value else {
                throw QueryError("`flag` takes the words written on the flag.")
            }
            parameters.append(.text("%" + Self.escapingLikeWildcards(text) + "%"))
            let matches = "(task.flagged = 1 AND task.flag_reason LIKE ? ESCAPE '\\')"
            return comparison == .notEquals ? "NOT \(matches)" : matches

        case .title:
            guard case .text(let text) = value else {
                throw QueryError("`title` takes some words to look for.")
            }
            // Substring match, with the wildcards the user did not intend
            // escaped so that a literal % stays a literal %.
            parameters.append(.text("%" + Self.escapingLikeWildcards(text) + "%"))
            return comparison == .notEquals
                ? "task.title NOT LIKE ? ESCAPE '\\'"
                : "task.title LIKE ? ESCAPE '\\'"
        }
    }

    /// A day, not an instant. `due = 2026-10-01` means any time that day, and
    /// `due < +7d` means before that day starts.
    private func dateFragment(
        column: String,
        comparison: QueryComparison,
        date: RelativeDate,
        into parameters: inout [SQLValue]
    ) -> String {
        let start = date.resolve(now: now, calendar: calendar)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)

        switch comparison {
        case .equals, .notEquals:
            parameters.append(.real(start.timeIntervalSince1970))
            parameters.append(.real(nextDay.timeIntervalSince1970))
            let within = "(task.\(column) >= ? AND task.\(column) < ?)"
            return comparison == .equals ? within : "NOT \(within)"

        case .lessThan:
            parameters.append(.real(start.timeIntervalSince1970))
            return "task.\(column) < ?"

        case .atMost:
            // "on or before that day" includes the whole of it.
            parameters.append(.real(nextDay.timeIntervalSince1970))
            return "task.\(column) < ?"

        case .greaterThan:
            parameters.append(.real(nextDay.timeIntervalSince1970))
            return "task.\(column) >= ?"

        case .atLeast:
            parameters.append(.real(start.timeIntervalSince1970))
            return "task.\(column) >= ?"
        }
    }

    private func columnName(for field: QueryField) throws -> String {
        switch field {
        case .due: "due_date"
        case .start: "start_date"
        case .created: "created_at"
        case .updated: "updated_at"
        case .completed: "completed_at"
        case .assignee: "assignee_id"
        case .priority: "priority"
        case .type: "type"
        case .status: "status_id"
        case .title: "title"
        case .label: "id"
        case .key: "number"
        case .version: "version_id"
        case .epic: "epic_id"
        case .points: "estimate"
        case .days: "status_changed_at"
        case .flag: "flag_reason"
        case .sprint: "sprint_id"
        }
    }

    /// `key = WORK-14`, and `key = 14` for the project already being looked at.
    ///
    /// Written as a tag it is matched against the project's prefix as well as
    /// the number, so a query board spanning several projects does not confuse
    /// WORK-14 with DOCS-14.
    private func keyFragment(
        _ text: String,
        comparison: QueryComparison,
        into parameters: inout [SQLValue]
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if let number = Int(trimmed) {
            parameters.append(.integer(Int64(number)))
            return comparison == .notEquals ? "task.number != ?" : "task.number = ?"
        }

        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let number = Int(parts[1]) else {
            // Not a tag at all. Nothing has that key, and saying so is more
            // useful than quietly matching everything.
            return comparison == .notEquals ? "1" : "0"
        }

        parameters.append(.integer(Int64(number)))
        parameters.append(.text(String(parts[0])))
        let matches = """
            (task.number = ? AND task.project_id IN (
                SELECT id FROM project WHERE key = ? COLLATE NOCASE))
            """
        return comparison == .notEquals ? "NOT \(matches)" : matches
    }

    /// `epic = "Checkout rewrite"`, or by the epic's own key.
    private func epicFragment(
        _ text: String,
        comparison: QueryComparison,
        into parameters: inout [SQLValue]
    ) -> String {
        var keyParameters: [SQLValue] = []
        let keyClause = keyFragment(text, comparison: .equals, into: &keyParameters)

        parameters.append(.text("%" + Self.escapingLikeWildcards(text) + "%"))
        parameters.append(contentsOf: keyParameters)

        let subquery = """
            SELECT id FROM task AS epic
            WHERE epic.title LIKE ? ESCAPE '\\'
               OR epic.id IN (SELECT task.id FROM task WHERE \(keyClause))
            """
        return comparison == .notEquals
            ? "task.epic_id NOT IN (\(subquery))"
            : "task.epic_id IN (\(subquery))"
    }

    /// `days >= 5` is a question about a date, asked in the other direction: a
    /// card has been somewhere five days when it arrived on or before the day
    /// five days ago. The inequality flips because more days means earlier.
    private func daysInColumnFragment(
        comparison: QueryComparison,
        days: Double,
        into parameters: inout [SQLValue]
    ) -> String {
        let whole = Int(days.rounded())
        let today = calendar.startOfDay(for: now)
        let boundary = calendar.date(byAdding: .day, value: -whole, to: today) ?? today
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: boundary) ?? boundary

        func bind(_ date: Date) { parameters.append(.real(date.timeIntervalSince1970)) }

        switch comparison {
        case .atLeast:
            bind(dayAfter)
            return "(task.status_changed_at IS NOT NULL AND task.status_changed_at < ?)"
        case .greaterThan:
            bind(boundary)
            return "(task.status_changed_at IS NOT NULL AND task.status_changed_at < ?)"
        case .atMost:
            bind(boundary)
            return "(task.status_changed_at IS NOT NULL AND task.status_changed_at >= ?)"
        case .lessThan:
            bind(dayAfter)
            return "(task.status_changed_at IS NOT NULL AND task.status_changed_at >= ?)"
        case .equals, .notEquals:
            bind(boundary)
            bind(dayAfter)
            let within = "(task.status_changed_at >= ? AND task.status_changed_at < ?)"
            return comparison == .equals ? within : "NOT \(within)"
        }
    }

    private static func sqlOperator(_ comparison: QueryComparison) -> String {
        switch comparison {
        case .lessThan: "<"
        case .atMost: "<="
        case .greaterThan: ">"
        case .atLeast: ">="
        case .equals: "="
        case .notEquals: "!="
        }
    }

    /// LIKE reads `%` and `_` as wildcards. A user searching for "50%" means
    /// the character.
    static func escapingLikeWildcards(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
