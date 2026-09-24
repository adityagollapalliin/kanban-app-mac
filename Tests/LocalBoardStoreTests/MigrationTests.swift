import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("Schema migration")
struct MigrationTests {

    @Test("A fresh database lands on the latest version")
    func freshDatabase() throws {
        let database = try Database.inMemoryMigrated()
        #expect(try database.userVersion == Migration.latestVersion)
    }

    @Test("Migrating twice is a no-op")
    func idempotent() throws {
        let database = try Database.inMemoryMigrated()
        try database.migrate()
        #expect(try database.userVersion == Migration.latestVersion)
    }

    /// The data-migration story: a database stamped at an older version is
    /// carried forward, and the rows that were already there survive.
    @Test("An older database is carried forward without losing rows")
    func upgradeFromOlderVersion() throws {
        let database = try Database(location: .memory)
        let first = try #require(Migration.all.first)
        try database.migrate(using: [first])
        #expect(try database.userVersion == first.version)

        let ids = try database.seedMinimalProject()
        try database.insertTask(project: ids.project, status: ids.status, number: 1, title: "Survivor")

        try database.migrate(using: Migration.all)

        #expect(try database.userVersion == Migration.latestVersion)
        #expect(try database.count("SELECT count(*) FROM task;") == 1)
    }

    /// The ladder's own rule: a new version is a new Migration plus a test
    /// that carries a database at the previous version forward.
    @Test("v1 upgrades to v2 and gains saved views without losing anything")
    func upgradeToSavedViews() throws {
        let database = try Database(location: .memory)
        let v1 = try #require(Migration.all.first { $0.version == 1 })
        try database.migrate(using: [v1])

        let ids = try database.seedMinimalProject()
        try database.insertTask(project: ids.project, status: ids.status, number: 1, title: "Older than v2")

        // Saved views do not exist yet at v1.
        #expect(throws: (any Error).self) {
            try database.count("SELECT COUNT(*) FROM saved_view;")
        }

        try database.migrate(using: Migration.all)

        #expect(try database.userVersion == 2)
        #expect(try database.count("SELECT COUNT(*) FROM saved_view;") == 0)
        #expect(try database.count("SELECT COUNT(*) FROM task;") == 1)

        // And the new table works on the carried-forward project.
        try SavedViewRepository(database: database)
            .create(inProject: ids.project, name: "Open", query: "is:open")
        #expect(try database.count("SELECT COUNT(*) FROM saved_view;") == 1)
    }

    /// Guards against an older build silently mangling a newer file.
    @Test("A newer database is refused, not opened")
    func refusesNewerSchema() throws {
        let database = try Database(location: .memory)
        try database.migrate()
        try database.setUserVersion(Migration.latestVersion + 5)

        #expect(throws: LocalBoardError.schemaTooNew(
            fileVersion: Migration.latestVersion + 5,
            supportedVersion: Migration.latestVersion
        )) {
            try database.migrate()
        }
    }

    @Test("Duplicate versions in the ladder are rejected")
    func duplicateVersions() throws {
        let database = try Database(location: .memory)
        let duplicate = Migration(version: 1, name: "clash", statements: ["CREATE TABLE a (x INTEGER);"])

        #expect(throws: LocalBoardError.self) {
            try database.migrate(using: [.v1Foundation, duplicate])
        }
    }

    @Test("Versions below 1 are rejected")
    func zeroVersionRejected() throws {
        let database = try Database(location: .memory)
        #expect(throws: LocalBoardError.self) {
            try database.migrate(using: [Migration(version: 0, name: "bad", statements: [])])
        }
    }

    /// A migration that fails halfway must not leave a half-applied schema.
    @Test("A failing migration leaves the previous version intact")
    func failedMigrationRollsBack() throws {
        let database = try Database(location: .memory)
        let broken = Migration(
            version: 2,
            name: "broken",
            statements: [
                "CREATE TABLE fine (x INTEGER);",
                "CREATE TABLE fine (x INTEGER);",  // same name again: fails
            ]
        )

        #expect(throws: LocalBoardError.self) {
            try database.migrate(using: [.v1Foundation, broken])
        }

        #expect(try database.userVersion == 1)
        #expect(try database.count("SELECT count(*) FROM sqlite_master WHERE name = 'fine';") == 0)
        // Version 1's tables are still there and usable.
        #expect(try database.count("SELECT count(*) FROM task;") == 0)
    }

    @Test("Migrations are ordered by version, not by array position")
    func ordering() throws {
        let database = try Database(location: .memory)
        let second = Migration(version: 2, name: "second", statements: ["CREATE TABLE later (x INTEGER);"])

        try database.migrate(using: [second, .v1Foundation])

        #expect(try database.userVersion == 2)
        #expect(try database.count("SELECT count(*) FROM sqlite_master WHERE name = 'later';") == 1)
    }

    @Test("The shipped ladder is append-only and gap-free")
    func ladderShape() {
        let versions = Migration.all.map(\.version)
        #expect(versions == Array(1...versions.count))
        #expect(Migration.latestVersion == versions.count)
    }
}
