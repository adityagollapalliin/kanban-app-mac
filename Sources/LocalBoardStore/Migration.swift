import Foundation
import LocalBoardCore

/// One rung of the schema ladder.
///
/// Migrations are append-only: once a version ships it is never edited, because
/// someone's database is already at that version. A schema change is a new
/// `Migration` with the next number and a test that loads a fixture at the
/// previous version and migrates it forward.
public struct Migration: Sendable, Equatable {
    public let version: Int
    public let name: String
    public let statements: [String]

    public init(version: Int, name: String, statements: [String]) {
        self.version = version
        self.name = name
        self.statements = statements
    }
}

extension Migration {
    /// The full ladder, in order. `Migration.latestVersion` is what a fresh
    /// database is stamped with.
    public static let all: [Migration] = [.v1Foundation, .v2SavedViews, .v3JiraBoard, .v4CardDetail, .v5Agile, .v6Structure]

    public static var latestVersion: Int { all.map(\.version).max() ?? 0 }
}

extension Database {

    /// Brings the database up to the newest schema version.
    ///
    /// - Each migration runs inside its own transaction, so a failure leaves the
    ///   file at the last version that fully applied rather than half-upgraded.
    /// - A file from a *newer* build is refused rather than opened, so an older
    ///   version of the app cannot quietly corrupt it.
    public func migrate(using migrations: [Migration] = Migration.all) throws {
        let ordered = migrations.sorted { $0.version < $1.version }
        try validate(ordered)

        let target = ordered.map(\.version).max() ?? 0
        let current = try userVersion

        guard current <= target else {
            throw LocalBoardError.schemaTooNew(fileVersion: current, supportedVersion: target)
        }
        guard current < target else { return }

        Log.migration.info("Migrating database from version \(current, privacy: .public) to \(target, privacy: .public).")

        for migration in ordered where migration.version > current {
            do {
                try transaction {
                    for statement in migration.statements {
                        try executeRaw(statement)
                    }
                    try setUserVersion(migration.version)
                }
                Log.migration.info("Applied migration \(migration.version, privacy: .public).")
            } catch let error as LocalBoardError {
                throw LocalBoardError.migrationFailed(
                    version: migration.version,
                    detail: error.failureReason ?? error.localizedDescription
                )
            } catch {
                throw LocalBoardError.migrationFailed(
                    version: migration.version,
                    detail: error.localizedDescription
                )
            }
        }
    }

    private func validate(_ ordered: [Migration]) throws {
        var seen = Set<Int>()
        for migration in ordered {
            guard migration.version > 0 else {
                throw LocalBoardError.migrationFailed(
                    version: migration.version,
                    detail: "Migration versions start at 1."
                )
            }
            guard seen.insert(migration.version).inserted else {
                throw LocalBoardError.migrationFailed(
                    version: migration.version,
                    detail: "Two migrations share version \(migration.version)."
                )
            }
        }
    }
}
