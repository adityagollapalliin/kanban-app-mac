import Foundation
import LocalBoardCore

/// A copy of the database, taken before it is upgraded.
///
/// The migration ladder already runs each rung in its own transaction, so a
/// failure leaves the file at the last version that fully applied rather than
/// half-upgraded. That is recoverable but it is not *reversible*: once v9 has
/// been written there is no way back to v8, and a migration that is wrong in a
/// way the tests did not catch has already eaten the only copy.
///
/// So: before the first statement of any upgrade, the file is copied. The copy
/// is named for the version it holds, which is the version you would be going
/// back to.
public struct MigrationBackup {

    /// How many to keep. Enough to cover a few upgrades in a row without the
    /// backups quietly becoming the largest thing in the container.
    public static let keep = 5

    let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Where the backups live, given the database's own folder.
    public static func directory(forDatabaseAt file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    /// `board-v8-20260925-183100.sqlite` — sortable, and made of characters
    /// every filesystem allows, which the colons in an ISO timestamp are not.
    ///
    /// Built from components rather than a `DateFormatter`: a shared formatter
    /// is not `Sendable`, and making one per backup to spell eight numbers
    /// would be paying a lot for very little.
    public static func name(version: Int, at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return "board-v\(version)-\(stamp).sqlite"
    }

    /// Copies the database as it stands.
    ///
    /// Two decisions worth keeping:
    ///
    /// The copy is taken with SQLite's online backup API — see
    /// `Database.backup(to:)` for why neither a file copy nor `VACUUM INTO`
    /// will do.
    ///
    /// - Returns: the file written, or nil for an in-memory database, which
    ///   has nothing to lose.
    @discardableResult
    public func write(from database: Database, version: Int, now: Date = Date()) throws -> URL? {
        guard case .file(let source) = database.location else { return nil }
        return try write(fromFileAt: source, version: version, now: now)
    }

    /// The same, given the file rather than the open database.
    @discardableResult
    public func write(fromFileAt source: URL, version: Int, now: Date = Date()) throws -> URL? {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(Self.name(version: version, at: now))
        // A second upgrade in the same second would otherwise collide with the
        // first and fail the whole migration over a file name.
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        let reader = try Database(location: .file(source))
        defer { reader.close() }
        try reader.backup(to: destination)

        try prune()
        return destination
    }

    /// The backups on disk, newest first.
    public func existing() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "sqlite" && $0.lastPathComponent.hasPrefix("board-v") }

        return files.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if leftDate == rightDate { return left.lastPathComponent > right.lastPathComponent }
            return leftDate > rightDate
        }
    }

    /// Deletes all but the newest `keep`.
    ///
    /// Pruning failures are not migration failures: a backup that could not be
    /// tidied away is a housekeeping problem, and refusing to upgrade over it
    /// would be worse than the untidiness.
    func prune() throws {
        let files = try existing()
        guard files.count > Self.keep else { return }
        for file in files.dropFirst(Self.keep) {
            try? fileManager.removeItem(at: file)
        }
    }
}
