import Foundation
import LocalBoardCore

/// Favourites, pinned views, what you were just looking at, and the trash.
///
/// The first three are one idea — a shortcut to something — so they share a
/// table and differ only in whether the user put it there and whether it ages
/// out. The trash is here too because it belongs to the same part of the
/// screen and answers the same question: what can I get back to.
public struct SidebarRepository {

    /// How many recently-viewed entries are kept. A list long enough to scroll
    /// is not a shortcut any more; it is a second history nobody asked for.
    public static let recentLimit = 10

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - Shortcuts

    public func shortcuts(_ kind: ShortcutKind) throws -> [Shortcut] {
        let order = kind == .recent ? "at DESC" : "sort_order"
        return try database.query(
            "SELECT * FROM shortcut WHERE kind = ? ORDER BY \(order);", [kind.rawValue]
        ).map(Shortcut.init(row:))
    }

    public func isFavorite(_ target: ShortcutTarget, id targetID: String) throws -> Bool {
        try database.count(
            "SELECT COUNT(*) FROM shortcut WHERE kind = ? AND target = ? AND target_id = ?;",
            [ShortcutKind.favorite.rawValue, target.rawValue, targetID]
        ) > 0
    }

    /// Adds a shortcut, or leaves the one that is already there alone —
    /// favouriting something twice is the same wish, not two.
    public func add(
        _ kind: ShortcutKind, target: ShortcutTarget, id targetID: String, label: String
    ) throws {
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM shortcut WHERE kind = ?;", [kind.rawValue]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO shortcut (id, kind, target, target_id, label, sort_order, at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (kind, target, target_id) DO UPDATE SET label = ?, at = ?;
            """,
            [
                UUID().uuidString, kind.rawValue, target.rawValue, targetID, label,
                SortOrder.between(last, nil), clock.now, label, clock.now,
            ]
        )
    }

    public func remove(_ kind: ShortcutKind, target: ShortcutTarget, id targetID: String) throws {
        try database.execute(
            "DELETE FROM shortcut WHERE kind = ? AND target = ? AND target_id = ?;",
            [kind.rawValue, target.rawValue, targetID]
        )
    }

    public func toggleFavorite(_ target: ShortcutTarget, id targetID: String, label: String) throws {
        if try isFavorite(target, id: targetID) {
            try remove(.favorite, target: target, id: targetID)
        } else {
            try add(.favorite, target: target, id: targetID, label: label)
        }
    }

    /// Records a visit, and trims the tail.
    ///
    /// Recents are a trail, so re-visiting moves an entry rather than adding
    /// one: ten rows for the same list would push everything else out.
    public func recordVisit(_ target: ShortcutTarget, id targetID: String, label: String) throws {
        try database.transaction {
            try add(.recent, target: target, id: targetID, label: label)

            let stale = try database.query(
                "SELECT id FROM shortcut WHERE kind = ? ORDER BY at DESC LIMIT -1 OFFSET ?;",
                [ShortcutKind.recent.rawValue, Self.recentLimit]
            ).compactMap { $0.string("id") }

            for id in stale {
                try database.execute("DELETE FROM shortcut WHERE id = ?;", [id])
            }
        }
    }

    /// Forgets a shortcut to something that no longer exists. Called when a
    /// list, folder or space is deleted, so the sidebar cannot offer a door
    /// into nothing.
    public func forget(target: ShortcutTarget, id targetID: String) throws {
        try database.execute(
            "DELETE FROM shortcut WHERE target = ? AND target_id = ?;", [target.rawValue, targetID]
        )
    }

    // MARK: - Archive

    /// Everything that has been put away: archived spaces, folders and lists,
    /// in one answer, because the sidebar shows them in one place.
    public func archived() throws -> (spaces: [Project], folders: [Folder], lists: [TaskList]) {
        let spaces = try database.query("SELECT * FROM project WHERE archived = 1 ORDER BY name;")
            .map(Project.init(row:))
        let folders = try database.query("SELECT * FROM folder WHERE archived = 1 ORDER BY name;")
            .map(Folder.init(row:))
        let lists = try database.query("SELECT * FROM list WHERE archived = 1 ORDER BY name;")
            .map(TaskList.init(row:))
        return (spaces, folders, lists)
    }

    // MARK: - Trash

    public func trashed(inProject projectID: String? = nil) throws -> [BoardTask] {
        if let projectID {
            return try database.query(
                "SELECT * FROM task WHERE trashed = 1 AND project_id = ? ORDER BY trashed_at DESC;",
                [projectID]
            ).map(BoardTask.init(row:))
        }
        return try database.query(
            "SELECT * FROM task WHERE trashed = 1 ORDER BY trashed_at DESC;"
        ).map(BoardTask.init(row:))
    }

    /// Empties the trash. The one genuinely destructive action in the app, so
    /// it is a verb of its own rather than something that happens as a side
    /// effect of anything else.
    @discardableResult
    public func emptyTrash(inProject projectID: String? = nil) throws -> Int {
        if let projectID {
            return try database.execute(
                "DELETE FROM task WHERE trashed = 1 AND project_id = ?;", [projectID]
            )
        }
        return try database.execute("DELETE FROM task WHERE trashed = 1;")
    }

    /// Removes what has been in the trash past its thirty days.
    ///
    /// Run on open rather than on a timer: a Mac asleep for a month catches up
    /// the moment the file is opened, and there is no scheduled job to miss a
    /// run. Anything with no `trashed_at` — trashed by a build that did not
    /// record one — is left alone rather than guessed at.
    @discardableResult
    public func purgeExpiredTrash(now: Date? = nil) throws -> Int {
        let moment = now ?? clock.now
        let cutoff = moment.addingTimeInterval(-TrashPolicy.keepFor)

        let count = try database.execute(
            "DELETE FROM task WHERE trashed = 1 AND trashed_at IS NOT NULL AND trashed_at <= ?;",
            [cutoff]
        )
        if count > 0 {
            Log.store.info("Removed \(count, privacy: .public) cards that had been in the trash for thirty days.")
        }
        return count
    }
}
