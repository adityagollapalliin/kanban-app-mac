import Foundation
import LocalBoardCore

/// Fields a project defines for itself.
///
/// Values are stored in typed columns rather than as text. A number kept as
/// `"12"` cannot be compared, sorted or summed, and `Size > 3` in the query
/// language would fall back to string comparison — which puts 10 before 9.
/// The cost is one column per kind and a `switch` here; the benefit is that
/// every custom field is a first-class thing to ask questions about.
public struct CustomFieldRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - The fields themselves

    public func fields(inProject projectID: String) throws -> [CustomField] {
        try database.query(
            "SELECT * FROM custom_field WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ).map(CustomField.init(row:))
    }

    @discardableResult
    public func create(
        inProject projectID: String,
        name: String,
        kind: CustomFieldKind,
        options: [String] = []
    ) throws -> CustomField {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A field needs a name.")
        }

        // A choice field with nothing to choose from is a field nobody can
        // fill in, which is a mistake worth catching at the moment it is made.
        if kind == .choice, CustomField.stored(options).isEmpty {
            throw LocalBoardError.invalidInput(
                field: "options", detail: "A choice field needs at least one choice."
            )
        }

        let id = UUID().uuidString
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM custom_field WHERE project_id = ?;", [projectID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO custom_field (id, project_id, name, kind, options, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [id, projectID, trimmed, kind.rawValue, CustomField.stored(options),
             SortOrder.between(last, nil), clock.now]
        )

        guard let row = try database.queryOne("SELECT * FROM custom_field WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The field was not written.")
        }
        return try CustomField(row: row)
    }

    public func rename(_ fieldID: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A field needs a name.")
        }
        let changed = try database.execute(
            "UPDATE custom_field SET name = ? WHERE id = ?;", [trimmed, fieldID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "field \(fieldID)") }
    }

    /// Changes the choices on offer.
    ///
    /// Values already set to a choice that has been removed are left alone.
    /// Rewriting them would be deciding on the user's behalf what a card that
    /// said "Blocked" now means, and there is no right answer to that.
    public func setOptions(_ options: [String], for fieldID: String) throws {
        let stored = CustomField.stored(options)
        guard !stored.isEmpty else {
            throw LocalBoardError.invalidInput(
                field: "options", detail: "A choice field needs at least one choice."
            )
        }
        let changed = try database.execute(
            "UPDATE custom_field SET options = ? WHERE id = ?;", [stored, fieldID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "field \(fieldID)") }
    }

    /// Removes a field and every value anyone put in it. The cascade is the
    /// point: a value with no field is unreadable, not merely orphaned.
    public func delete(_ fieldID: String) throws {
        let changed = try database.execute("DELETE FROM custom_field WHERE id = ?;", [fieldID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "field \(fieldID)") }
    }

    // MARK: - Values

    public func values(forTask taskID: String) throws -> [String: CustomFieldValue] {
        var found: [String: CustomFieldValue] = [:]

        try database.forEachRow(
            """
            SELECT custom_field_value.*, custom_field.kind AS field_kind
            FROM custom_field_value
            JOIN custom_field ON custom_field.id = custom_field_value.field_id
            WHERE custom_field_value.task_id = ?;
            """,
            [taskID]
        ) { row in
            let fieldID = try row.requiredString("field_id")
            let kind = try row.requiredEnum("field_kind", CustomFieldKind.self)
            if let value = Self.value(from: row, kind: kind) { found[fieldID] = value }
        }

        return found
    }

    /// Every card's values in one project, for the board's card rows — one
    /// query rather than one per card.
    public func valuesByTask(inProject projectID: String) throws -> [String: [String: CustomFieldValue]] {
        var found: [String: [String: CustomFieldValue]] = [:]

        try database.forEachRow(
            """
            SELECT custom_field_value.*, custom_field.kind AS field_kind
            FROM custom_field_value
            JOIN custom_field ON custom_field.id = custom_field_value.field_id
            WHERE custom_field.project_id = ?;
            """,
            [projectID]
        ) { row in
            let taskID = try row.requiredString("task_id")
            let fieldID = try row.requiredString("field_id")
            let kind = try row.requiredEnum("field_kind", CustomFieldKind.self)
            if let value = Self.value(from: row, kind: kind) {
                found[taskID, default: [:]][fieldID] = value
            }
        }

        return found
    }

    /// Reads whichever column the field's kind uses. A row whose column is
    /// NULL is a value that was cleared, and comes back as nothing at all.
    private static func value(from row: Row, kind: CustomFieldKind) -> CustomFieldValue? {
        switch kind {
        case .text:
            return row.string("text_value").map(CustomFieldValue.text)
        case .choice:
            return row.string("text_value").map(CustomFieldValue.choice)
        case .number:
            return row.double("number_value").map(CustomFieldValue.number)
        case .date:
            return row.date("date_value").map(CustomFieldValue.date)
        case .checkbox:
            return row.bool("bool_value").map(CustomFieldValue.checkbox)
        }
    }

    /// Writes one value, or clears it when `value` is nil.
    ///
    /// The field's declared kind wins over the value's: a caller handing a
    /// number to a text field is a bug, and storing it in the wrong column
    /// would make it invisible to every read.
    public func setValue(
        _ value: CustomFieldValue?,
        forField fieldID: String,
        onTask taskID: String
    ) throws {
        guard let value else {
            try database.execute(
                "DELETE FROM custom_field_value WHERE task_id = ? AND field_id = ?;",
                [taskID, fieldID]
            )
            return
        }

        guard let row = try database.queryOne("SELECT kind FROM custom_field WHERE id = ?;", [fieldID]),
              let raw = row.int("kind"),
              let kind = CustomFieldKind(rawValue: Int(raw)) else {
            throw LocalBoardError.notFound(entity: "field \(fieldID)")
        }
        guard kind == value.kind else {
            throw LocalBoardError.invalidInput(
                field: "value",
                detail: "That field holds \(kind.label.lowercased()), not \(value.kind.label.lowercased())."
            )
        }

        var text: SQLValue = .null
        var number: SQLValue = .null
        var date: SQLValue = .null
        var flag: SQLValue = .null

        switch value {
        case .text(let string), .choice(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty answer is no answer: clearing the field is what the
            // user meant by deleting the last character out of it.
            guard !trimmed.isEmpty else {
                try database.execute(
                    "DELETE FROM custom_field_value WHERE task_id = ? AND field_id = ?;",
                    [taskID, fieldID]
                )
                return
            }
            text = .text(trimmed)
        case .number(let amount):
            number = .real(amount)
        case .date(let day):
            date = .real(day.timeIntervalSince1970)
        case .checkbox(let ticked):
            flag = .integer(ticked ? 1 : 0)
        }

        try database.execute(
            """
            INSERT INTO custom_field_value (task_id, field_id, text_value, number_value, date_value, bool_value)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (task_id, field_id) DO UPDATE SET
                text_value = ?, number_value = ?, date_value = ?, bool_value = ?;
            """,
            [taskID, fieldID, text, number, date, flag, text, number, date, flag]
        )
    }
}
