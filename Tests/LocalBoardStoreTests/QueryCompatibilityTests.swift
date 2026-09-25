import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

/// Proof that the query language has not changed meaning.
///
/// Every entry in `QueryCorpus` is compiled against the same fixed database
/// and the same stopped clock, and the resulting SQL and bound values are
/// compared against `Fixtures/query-baseline.json`, which was recorded before
/// Milestone 8.5 touched the parser.
///
/// The baseline is the contract. A failure here means a saved filter somebody
/// is relying on would now return different cards.
@Suite("The query language keeps its promises")
struct QueryCompatibilityTests {

    // MARK: The fixture

    /// A fixed moment, so every relative date resolves to the same number.
    static let now = Date(timeIntervalSince1970: 1_780_000_000)   // 2026-06-08

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A database with one of everything a query can name, at known ids.
    ///
    /// The ids are fixed rather than generated, because they end up in the
    /// baseline as bound values — a UUID would make the file different on
    /// every run and the comparison worthless.
    static func fixture() throws -> (Database, String) {
        let database = try Database(location: .memory)
        try database.migrate()

        let workspace = "ws-1", project = "pr-1"
        let now = Self.now.timeIntervalSince1970

        try database.execute(
            "INSERT INTO workspace (id, name, sort_order, created_at) VALUES (?, ?, ?, ?);",
            [workspace, "Personal", 1_000.0, now]
        )
        try database.execute(
            """
            INSERT INTO project (id, workspace_id, name, key, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [project, workspace, "Work", "WORK", 1_000.0, now]
        )
        for (index, entry) in [("To Do", 0), ("In Progress", 1), ("Done", 2)].enumerated() {
            try database.execute(
                "INSERT INTO status (id, project_id, name, category, sort_order) VALUES (?, ?, ?, ?, ?);",
                ["st-\(index)", project, entry.0, entry.1, Double(index + 1) * 1_000]
            )
        }
        try database.execute(
            "INSERT INTO person (id, name, sort_order, created_at) VALUES (?, ?, ?, ?);",
            ["pe-1", "Ada Lovelace", 1_000.0, now]
        )
        try database.execute(
            "INSERT INTO label (id, project_id, name, color) VALUES (?, ?, ?, ?);",
            ["la-1", project, "backend", "blue"]
        )
        try database.execute(
            """
            INSERT INTO version (id, project_id, name, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?);
            """,
            ["ve-1", project, "1.0", 1_000.0, now]
        )
        try database.execute(
            """
            INSERT INTO sprint (id, project_id, name, state, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            ["sp-1", project, "Sprint 1", 1, 1_000.0, now]
        )
        try database.execute(
            """
            INSERT INTO task (id, project_id, status_id, number, title, description_md,
                              sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, '', ?, ?, ?);
            """,
            ["ta-1", project, "st-0", 1, "Write the export format", 1_000.0, now, now]
        )

        // One custom field per storage kind, so `cf:` compiles every branch.
        for (index, entry) in [
            ("Size", CustomFieldKind.number), ("Notes", .text), ("Signed", .checkbox),
            ("Reviewed", .date), ("Stage", .choice),
        ].enumerated() {
            try database.execute(
                """
                INSERT INTO custom_field (id, project_id, name, kind, options, sort_order, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                ["cf-\(index)", project, entry.0, entry.1.rawValue,
                 entry.1 == .choice ? "Alpha\nBeta" : "", Double(index + 1) * 1_000, now]
            )
        }

        // `is:mine` needs somebody to be "me", or it matches nothing.
        try AppSettings(database: database).setCurrentPerson("pe-1")

        return (database, project)
    }

    // MARK: Recording and comparing

    /// What one query compiles to. `nil` sql means the parser rejected it.
    struct Record: Codable, Equatable {
        var query: String
        var source: String
        var sql: String?
        var parameters: [String]?
        var rejected: Bool { sql == nil }
    }

    static func record(_ entry: QueryCorpus.Entry) throws -> Record {
        let (database, project) = try fixture()
        defer { database.close() }

        let compiler = TaskQueryCompiler(
            database: database,
            projectID: project,
            now: now,
            calendar: calendar,
            currentPersonID: try AppSettings(database: database).currentPersonID
        )

        do {
            let filter = try TaskQueryParser.parse(entry.query)
            let compiled = try compiler.compile(filter)
            return Record(
                query: entry.query,
                source: entry.source.rawValue,
                sql: compiled.whereClause,
                parameters: compiled.parameters.map(Self.describe)
            )
        } catch {
            return Record(query: entry.query, source: entry.source.rawValue, sql: nil, parameters: nil)
        }
    }

    /// Bound values as text, so the baseline is readable and diffable.
    static func describe(_ value: SQLValue) -> String {
        switch value {
        case .null: "null"
        case .integer(let number): "int:\(number)"
        case .real(let number): "real:\(number)"
        case .text(let text): "text:\(text)"
        case .blob(let data): "blob:\(data.count)"
        }
    }

    static var baselineURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/query-baseline.json")
    }

    static func loadBaseline() throws -> [String: Record] {
        let data = try Data(contentsOf: baselineURL)
        let records = try JSONDecoder().decode([Record].self, from: data)
        return Dictionary(uniqueKeysWithValues: records.map { ($0.query, $0) })
    }

    // MARK: The tests

    @Test("Every query in the corpus compiles to exactly what it did before")
    func baselineHolds() throws {
        let baseline = try Self.loadBaseline()

        for entry in QueryCorpus.all {
            guard let expected = baseline[entry.query] else {
                Issue.record("`\(entry.query)` is in the corpus but not in the baseline. Regenerate it deliberately.")
                continue
            }
            let actual = try Self.record(entry)

            #expect(
                actual.sql == expected.sql,
                "`\(entry.query)` (\(entry.source.rawValue)) compiles differently.\n  was: \(expected.sql ?? "rejected")\n  now: \(actual.sql ?? "rejected")"
            )
            #expect(
                actual.parameters == expected.parameters,
                "`\(entry.query)` (\(entry.source.rawValue)) binds different values.\n  was: \(expected.parameters ?? [])\n  now: \(actual.parameters ?? [])"
            )
        }
    }

    @Test("The baseline covers the corpus, and nothing has quietly left it")
    func baselineIsComplete() throws {
        let baseline = try Self.loadBaseline()
        let corpus = Set(QueryCorpus.all.map(\.query))

        #expect(corpus.count == baseline.count,
                "The corpus has \(corpus.count) queries and the baseline \(baseline.count).")

        for query in baseline.keys where !corpus.contains(query) {
            Issue.record("`\(query)` is in the baseline but no longer in the corpus. Removing a query removes its protection.")
        }
    }

    /// The counts are asserted so that a query silently disappearing from the
    /// corpus is a failure rather than a smaller, quieter test run.
    @Test("The corpus still covers what it was built to cover")
    func corpusShape() {
        #expect(QueryCorpus.live.count == 4)
        #expect(QueryCorpus.starter.count == 4)
        #expect(QueryCorpus.builtIn.count == 4)
        #expect(QueryCorpus.fromTests.count == 20)
        #expect(QueryCorpus.all.count >= 80)

        // The collision set must not quietly shrink: every one of these is a
        // string that means "search for these words" today, and the whole
        // point of recording them is that 8.5 cannot change that silently.
        #expect(QueryCorpus.textSearchToday.count == 6)

        // Every flag the language defines is exercised somewhere.
        let text = QueryCorpus.all.map(\.query).joined(separator: " ")
        for flag in QueryFlag.allCases {
            #expect(text.lowercased().contains("is:\(flag.rawValue.lowercased())"),
                    "No query in the corpus uses is:\(flag.rawValue)")
        }

        // As is every field.
        for field in QueryField.allCases {
            #expect(text.lowercased().contains(field.rawValue.lowercased()),
                    "No query in the corpus mentions \(field.rawValue)")
        }
    }
}
