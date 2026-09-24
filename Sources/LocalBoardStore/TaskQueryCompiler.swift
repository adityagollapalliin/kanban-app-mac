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

    init(projectID: String, now: Date, calendar: Calendar = .current) {
        self.projectID = projectID
        self.now = now
        self.calendar = calendar
    }

    func compile(_ filter: TaskFilter) throws -> Compiled {
        var parameters: [SQLValue] = []
        let clause = try fragment(filter, into: &parameters)
        return Compiled(whereClause: clause, parameters: parameters)
    }

    /// Whether the filter speaks about the trash itself. If it does not, the
    /// caller hides trashed cards; if it does, the user has asked and gets
    /// exactly what they asked for.
    static func mentionsTrash(_ filter: TaskFilter) -> Bool {
        switch filter {
        case .flag(.trashed): true
        case .and(let branches), .or(let branches): branches.contains(where: mentionsTrash)
        case .not(let inner): mentionsTrash(inner)
        default: false
        }
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
        }
    }

    private func fragment(
        field: QueryField,
        comparison: QueryComparison,
        value: QueryValue,
        into parameters: inout [SQLValue]
    ) throws -> String {
        // `due = none` and `assignee != none` are about presence, whatever the
        // column's type.
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
