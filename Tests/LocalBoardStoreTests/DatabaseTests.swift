import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("SQLite connection")
struct DatabaseTests {

    @Test("Round-trips every storage class")
    func valueRoundTrip() throws {
        let database = try Database(location: .memory)
        try database.executeRaw("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, n TEXT);")
        try database.execute(
            "INSERT INTO t (i, r, s, b, n) VALUES (?, ?, ?, ?, ?);",
            [Int64(42), 3.5, "hello", Data([0x01, 0x02, 0x03]), SQLValue.null]
        )

        let row = try #require(try database.queryOne("SELECT i, r, s, b, n FROM t;"))
        #expect(row.int("i") == 42)
        #expect(row.double("r") == 3.5)
        #expect(row.string("s") == "hello")
        #expect(row.data("b") == Data([0x01, 0x02, 0x03]))
        #expect(row["n"] == .null)
    }

    @Test("Dates survive as comparable epoch seconds")
    func dateRoundTrip() throws {
        let database = try Database(location: .memory)
        try database.executeRaw("CREATE TABLE t (at REAL);")
        let when = Date(timeIntervalSince1970: 1_700_000_000.5)
        try database.execute("INSERT INTO t (at) VALUES (?);", [when])

        let row = try #require(try database.queryOne("SELECT at FROM t;"))
        #expect(row.date("at") == when)

        // Stored as REAL, so SQL can filter on it directly — the property the
        // query language depends on for `due < +7d`.
        #expect(try database.count("SELECT count(*) FROM t WHERE at > ?;", [when.addingTimeInterval(-1)]) == 1)
    }

    @Test("Values are bound, never interpolated, so quotes are harmless")
    func injectionSafety() throws {
        let database = try Database(location: .memory)
        try database.executeRaw("CREATE TABLE t (s TEXT);")

        let hostile = "'; DROP TABLE t; --"
        try database.execute("INSERT INTO t (s) VALUES (?);", [hostile])

        #expect(try database.count("SELECT count(*) FROM t;") == 1)
        let row = try #require(try database.queryOne("SELECT s FROM t;"))
        #expect(row.string("s") == hostile)
    }

    @Test("Wrong parameter count is refused rather than mis-bound")
    func parameterCountMismatch() throws {
        let database = try Database(location: .memory)
        try database.executeRaw("CREATE TABLE t (a TEXT, b TEXT);")

        #expect(throws: LocalBoardError.self) {
            try database.execute("INSERT INTO t (a, b) VALUES (?, ?);", ["only one"])
        }
    }

    @Test("A failing transaction rolls everything back")
    func transactionRollback() throws {
        let database = try Database(location: .memory)
        try database.executeRaw("CREATE TABLE t (id INTEGER PRIMARY KEY);")

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try database.transaction {
                try database.execute("INSERT INTO t (id) VALUES (?);", [1])
                try database.execute("INSERT INTO t (id) VALUES (?);", [2])
                throw Boom()
            }
        }
        #expect(try database.count("SELECT count(*) FROM t;") == 0)
    }

    @Test("A successful transaction commits")
    func transactionCommit() throws {
        let database = try Database(location: .memory)
        try database.executeRaw("CREATE TABLE t (id INTEGER PRIMARY KEY);")

        try database.transaction {
            try database.execute("INSERT INTO t (id) VALUES (?);", [1])
        }
        #expect(try database.count("SELECT count(*) FROM t;") == 1)
    }

    /// Commands are composed of smaller commands, so nesting has to work: the
    /// inner failure rolls back to its savepoint without losing the outer work.
    @Test("Nested transactions use savepoints")
    func nestedTransaction() throws {
        let database = try Database(location: .memory)
        try database.executeRaw("CREATE TABLE t (id INTEGER PRIMARY KEY);")

        struct Boom: Error {}
        try database.transaction {
            try database.execute("INSERT INTO t (id) VALUES (?);", [1])
            #expect(throws: Boom.self) {
                try database.transaction {
                    try database.execute("INSERT INTO t (id) VALUES (?);", [2])
                    throw Boom()
                }
            }
        }

        #expect(try database.count("SELECT count(*) FROM t;") == 1)
        let row = try #require(try database.queryOne("SELECT id FROM t;"))
        #expect(row.int("id") == 1)
    }

    @Test("Foreign keys are enforced, not merely declared")
    func foreignKeysEnforced() throws {
        let database = try Database.inMemoryMigrated()
        #expect(throws: LocalBoardError.self) {
            try database.execute(
                """
                INSERT INTO project (id, workspace_id, name, key, sort_order, created_at)
                VALUES (?, ?, ?, ?, ?, ?);
                """,
                [UUID().uuidString, "no-such-workspace", "Orphan", "ORP", 1.0, 0.0]
            )
        }
    }

    @Test("A file-backed database uses WAL, which is what makes the CLI safe")
    func walEnabled() throws {
        let container = try TemporaryContainer()
        defer { container.remove() }

        let database = try Database.openBoardDatabase(paths: container.paths)
        defer { database.close() }

        let row = try #require(try database.queryOne("PRAGMA journal_mode;"))
        #expect(row.string("journal_mode")?.lowercased() == "wal")
    }

    @Test("forEachRow streams without materialising an array")
    func streaming() throws {
        let database = try Database(location: .memory)
        try database.executeRaw("CREATE TABLE t (id INTEGER);")
        for index in 0..<50 {
            try database.execute("INSERT INTO t (id) VALUES (?);", [index])
        }

        var total = 0
        try database.forEachRow("SELECT id FROM t ORDER BY id;") { row in
            total += Int(row.int("id") ?? 0)
        }
        #expect(total == (0..<50).reduce(0, +))
    }

    @Test("Missing columns read as null instead of trapping")
    func missingColumnsAreNull() throws {
        let database = try Database(location: .memory)
        try database.executeRaw("CREATE TABLE t (a INTEGER);")
        try database.execute("INSERT INTO t (a) VALUES (?);", [1])

        let row = try #require(try database.queryOne("SELECT a FROM t;"))
        #expect(row["nope"] == .null)
        #expect(row[99] == .null)
        #expect(row.string("nope") == nil)
    }
}
