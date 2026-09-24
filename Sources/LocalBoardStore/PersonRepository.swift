import Foundation
import LocalBoardCore

/// The people work can be assigned to.
///
/// There are no accounts here and no sign-in: a person is a name someone typed
/// so that `assignee = "Sam"` has something to match. Nothing about this leaves
/// the Mac, which is why it can stay this simple.
public struct PersonRepository {

    private let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    public func people() throws -> [Person] {
        try database.query("SELECT * FROM person ORDER BY sort_order;").map(Person.init(row:))
    }

    public func person(id: String) throws -> Person {
        guard let row = try database.queryOne("SELECT * FROM person WHERE id = ?;", [id]) else {
            throw LocalBoardError.notFound(entity: "person \(id)")
        }
        return try Person(row: row)
    }

    @discardableResult
    public func create(name: String, color: String = "graphite") throws -> Person {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A person needs a name.")
        }

        let id = UUID().uuidString
        let now = clock.now
        let last = try database.queryOne("SELECT MAX(sort_order) AS last FROM person;")?.double("last")

        try database.execute(
            "INSERT INTO person (id, name, color, sort_order, created_at) VALUES (?, ?, ?, ?, ?);",
            [id, trimmed, color, SortOrder.between(last, nil), now]
        )
        return try person(id: id)
    }

    public func rename(_ personID: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A person needs a name.")
        }
        let changed = try database.execute("UPDATE person SET name = ? WHERE id = ?;", [trimmed, personID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "person \(personID)") }
    }

    /// Removing someone unassigns their cards rather than taking the cards with
    /// them — the schema's ON DELETE SET NULL, and the only sane reading of
    /// "this person has left".
    public func delete(_ personID: String) throws {
        let changed = try database.execute("DELETE FROM person WHERE id = ?;", [personID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "person \(personID)") }
    }
}
