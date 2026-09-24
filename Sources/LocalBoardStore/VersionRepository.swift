import Foundation
import LocalBoardCore

/// Releases, and how far through one a project is.
public struct VersionRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    public func versions(inProject projectID: String, includeReleased: Bool = true) throws -> [Version] {
        let sql = """
            SELECT * FROM version
            WHERE project_id = ?\(includeReleased ? "" : " AND released = 0")
            ORDER BY sort_order;
            """
        return try database.query(sql, [projectID]).map(Version.init(row:))
    }

    public func version(id: String) throws -> Version {
        guard let row = try database.queryOne("SELECT * FROM version WHERE id = ?;", [id]) else {
            throw LocalBoardError.notFound(entity: "version \(id)")
        }
        return try Version(row: row)
    }

    @discardableResult
    public func create(
        inProject projectID: String,
        name: String,
        descriptionMarkdown: String = "",
        releaseDate: Date? = nil
    ) throws -> Version {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A version needs a name.")
        }

        let id = UUID().uuidString
        let now = clock.now
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM version WHERE project_id = ?;", [projectID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO version (id, project_id, name, description_md, release_date, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [id, projectID, trimmed, descriptionMarkdown, releaseDate.sqlValue,
             SortOrder.between(last, nil), now]
        )
        return try version(id: id)
    }

    public func rename(_ versionID: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A version needs a name.")
        }
        try update(versionID, "name = ?", [trimmed])
    }

    public func setReleaseDate(_ date: Date?, for versionID: String) throws {
        try update(versionID, "release_date = ?", [date.sqlValue])
    }

    /// Shipping a version does not touch its cards.
    ///
    /// Unfinished work in a released version is a fact worth being able to
    /// see, not an inconsistency to be tidied away at the moment of release.
    public func setReleased(_ released: Bool, for versionID: String) throws {
        try update(versionID, "released = ?", [released])
    }

    /// Removes a version. Its cards stay and simply lose the link, exactly as
    /// deleting a person leaves their cards unassigned.
    public func delete(_ versionID: String) throws {
        let changed = try database.execute("DELETE FROM version WHERE id = ?;", [versionID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "version \(versionID)") }
    }

    // MARK: - Progress

    /// How much of a release is finished, counted both ways.
    ///
    /// Cards and points are both reported because they disagree, and which of
    /// them a team believes is not something this can decide for them.
    public func progress(ofVersion versionID: String) throws -> ReleaseProgress {
        guard let row = try database.queryOne(
            """
            SELECT COUNT(*)                                                   AS total,
                   SUM(CASE WHEN completed_at IS NOT NULL THEN 1 ELSE 0 END)  AS done,
                   COALESCE(SUM(estimate), 0)                                 AS points,
                   COALESCE(SUM(CASE WHEN completed_at IS NOT NULL
                                     THEN estimate ELSE 0 END), 0)            AS donePoints
            FROM task WHERE version_id = ? AND trashed = 0;
            """,
            [versionID]
        ) else {
            return ReleaseProgress(total: 0, done: 0, points: 0, donePoints: 0)
        }

        return ReleaseProgress(
            total: Int(row.int("total") ?? 0),
            done: Int(row.int("done") ?? 0),
            points: row.double("points") ?? 0,
            donePoints: row.double("donePoints") ?? 0
        )
    }

    public func tasks(inVersion versionID: String) throws -> [BoardTask] {
        try database.query(
            "SELECT * FROM task WHERE version_id = ? AND trashed = 0 ORDER BY number;",
            [versionID]
        ).map(BoardTask.init(row:))
    }

    private func update(_ versionID: String, _ assignment: String, _ values: [SQLValueConvertible]) throws {
        let changed = try database.execute(
            "UPDATE version SET \(assignment) WHERE id = ?;", values + [versionID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "version \(versionID)") }
    }
}

/// How far through a release its work is.
public struct ReleaseProgress: Sendable, Equatable {
    public let total: Int
    public let done: Int
    public let points: Double
    public let donePoints: Double

    public init(total: Int, done: Int, points: Double, donePoints: Double) {
        self.total = total
        self.done = done
        self.points = points
        self.donePoints = donePoints
    }

    public var remaining: Int { total - done }
    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    public var pointsFraction: Double { points == 0 ? 0 : donePoints / points }
    public var isComplete: Bool { total > 0 && done == total }
}
