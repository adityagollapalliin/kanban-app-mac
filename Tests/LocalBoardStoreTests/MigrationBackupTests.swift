import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("A copy before the upgrade")
struct MigrationBackupTests {

    /// A real file on disk, because the whole point is the file.
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("localboard-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Migrating a file writes a copy of the version it is leaving")
    func backupIsWritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("board.sqlite")

        // A database at v1, with something in it worth not losing.
        let first = try Database(location: .file(file))
        try first.migrate(using: [.v1Foundation])
        try first.seedMinimalProject()
        first.close()

        let second = try Database(location: .file(file))
        try second.migrate()
        defer { second.close() }

        let backups = try MigrationBackup(
            directory: MigrationBackup.directory(forDatabaseAt: file)
        ).existing()

        #expect(backups.count == 1)
        // Named for the version it holds, which is the one you would go back to.
        #expect(backups[0].lastPathComponent.hasPrefix("board-v1-"))
        #expect(try second.userVersion == Migration.latestVersion)
    }

    @Test("The copy is a working database holding the old version's data")
    func backupIsUsable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("board.sqlite")

        let first = try Database(location: .file(file))
        try first.migrate(using: [.v1Foundation, .v2SavedViews])
        let ids = try first.seedMinimalProject()
        try first.insertTask(project: ids.project, status: ids.status, number: 1, title: "Worth keeping")
        first.close()

        let second = try Database(location: .file(file))
        try second.migrate()
        second.close()

        let backups = try MigrationBackup(
            directory: MigrationBackup.directory(forDatabaseAt: file)
        ).existing()
        let restored = try Database(location: .file(try #require(backups.first)))
        defer { restored.close() }

        // Still at the old version, and the card is still there.
        #expect(try restored.userVersion == 2)
        #expect(try restored.count("SELECT COUNT(*) FROM task;") == 1)
        #expect(try restored.queryOne("SELECT title FROM task;")?.string("title") == "Worth keeping")
    }

    @Test("Work committed since the last checkpoint is in the copy")
    func walContentsAreIncluded() throws {
        // The reason this uses VACUUM INTO rather than copying the file: a WAL
        // database's recent commits live in board.sqlite-wal, and a plain copy
        // of board.sqlite would silently leave them out.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("board.sqlite")

        let first = try Database(location: .file(file))
        try first.migrate(using: [.v1Foundation])
        let ids = try first.seedMinimalProject()
        for number in 1...20 {
            try first.insertTask(project: ids.project, status: ids.status, number: number, title: "Card \(number)")
        }
        first.close()

        let second = try Database(location: .file(file))
        try second.migrate()
        second.close()

        let backups = try MigrationBackup(
            directory: MigrationBackup.directory(forDatabaseAt: file)
        ).existing()
        let restored = try Database(location: .file(try #require(backups.first)))
        defer { restored.close() }
        #expect(try restored.count("SELECT COUNT(*) FROM task;") == 20)
    }

    @Test("Nothing is written when there is nothing to upgrade")
    func noUpgradeNoBackup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("board.sqlite")

        let first = try Database(location: .file(file))
        try first.migrate()
        first.close()

        // Already current: opening it again upgrades nothing, so there is
        // nothing to keep a copy of.
        let second = try Database(location: .file(file))
        try second.migrate()
        defer { second.close() }

        #expect(try MigrationBackup(
            directory: MigrationBackup.directory(forDatabaseAt: file)
        ).existing().isEmpty)
    }

    @Test("Only the newest five are kept")
    func pruning() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backups = MigrationBackup(directory: directory.appendingPathComponent("Backups"))
        try FileManager.default.createDirectory(at: backups.directory, withIntermediateDirectories: true)

        for version in 1...8 {
            let name = MigrationBackup.name(
                version: version, at: Date(timeIntervalSince1970: 1_700_000_000 + Double(version) * 60)
            )
            let url = backups.directory.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            // Modification dates decide the order, so they have to differ.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(version) * 60)],
                ofItemAtPath: url.path
            )
        }

        try backups.prune()
        let kept = try backups.existing()
        #expect(kept.count == MigrationBackup.keep)
        // The newest survive; v1 to v3 are the ones let go.
        #expect(kept.first?.lastPathComponent.hasPrefix("board-v8-") == true)
        #expect(kept.allSatisfy { !$0.lastPathComponent.hasPrefix("board-v1-") })
    }

    @Test("An in-memory database has nothing to lose and is not copied")
    func inMemoryIsSkipped() throws {
        let database = try Database(location: .memory)
        try database.migrate()
        defer { database.close() }
        #expect(try database.userVersion == Migration.latestVersion)
    }

    @Test("A backup that cannot be written stops the migration")
    func failureStopsTheUpgrade() throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("board.sqlite")

        let first = try Database(location: .file(file))
        try first.migrate(using: [.v1Foundation])
        first.close()

        // Read-only folder: the copy cannot be written. Upgrading anyway would
        // be deciding that the user's data is worth less than the upgrade.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let second = try Database(location: .file(file))
        defer { second.close() }
        #expect(throws: (any Error).self) { try second.migrate() }
        #expect(try second.userVersion == 1)
    }

    /// Closing twice used to close the SQLite connection twice — a
    /// use-after-free whose damage showed up as SQLITE_MISUSE on an unrelated
    /// connection, minutes later, in a different test.
    ///
    /// Everything that closes explicitly was doing it: the CLI, the app on
    /// teardown, and every test that opens a file.
    @Test("Closing a database twice is harmless")
    func doubleCloseIsSafe() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("board.sqlite")

        do {
            let database = try Database(location: .file(file))
            try database.migrate()
            database.close()
            database.close()
            database.close()
            // And once more when it goes out of scope, via deinit.
        }

        // The process is still in a state where SQLite works.
        let reopened = try Database(location: .file(file))
        defer { reopened.close() }
        #expect(try reopened.userVersion == Migration.latestVersion)
    }

    @Test("A closed database refuses work rather than using a freed handle")
    func closedDatabaseIsInert() throws {
        let database = try Database(location: .memory)
        try database.migrate()
        database.close()
        #expect(throws: (any Error).self) { try database.executeRaw("SELECT 1;") }
    }
}
