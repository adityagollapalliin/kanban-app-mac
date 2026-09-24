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

    let projectID: String
    let now: Date
    let calendar: Calendar
    /// Who "me" is, for `is:mine`. Nil when nobody has been chosen in
    /// Settings, in which case `is:mine` matches nothing rather than
    /// everything — an unanswered question has no answers.
    let currentPersonID: String?

    init(
        projectID: String,
        now: Date,
        calendar: Calendar = .current,
        currentPersonID: String? = nil
    ) {
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
