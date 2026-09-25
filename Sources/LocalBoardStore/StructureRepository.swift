import Foundation
import LocalBoardCore

/// The hierarchy underneath a space: folders and lists.
///
/// A space is still a `project` row — it owns the statuses, fields, rules and
/// sprints, which is exactly what a space owns. What is new is what sits under
/// it, and the rule that keeps it honest: **a list always has a space, and a
/// card always has a list.** A folder is optional at every turn, because a
/// folder tidies a sidebar and nothing else consults it.
public struct StructureRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - Spaces

    /// A space's colour and icon. Both may be empty, which draws as the app's
    /// accent and no icon rather than as a colour nobody picked.
    public func setAppearance(color: String?, icon: String?, forSpace spaceID: String) throws {
        var assignments: [String] = []
        var values: [SQLValueConvertible] = []
        if let color { assignments.append("color = ?"); values.append(color) }
        if let icon { assignments.append("icon = ?"); values.append(icon) }
        guard !assignments.isEmpty else { return }

        values.append(spaceID)
        let changed = try database.execute(
            "UPDATE project SET \(assignments.joined(separator: ", ")) WHERE id = ?;", values
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "space \(spaceID)") }
    }

    // MARK: - Folders

    public func folders(inSpace spaceID: String, includeArchived: Bool = false) throws -> [Folder] {
        let sql = """
            SELECT * FROM folder WHERE project_id = ?\(includeArchived ? "" : " AND archived = 0")
            ORDER BY sort_order;
            """
        return try database.query(sql, [spaceID]).map(Folder.init(row:))
    }

    @discardableResult
    public func createFolder(inSpace spaceID: String, name: String) throws -> Folder {
        let trimmed = try require(name, field: "name", detail: "A folder needs a name.")
        let id = UUID().uuidString
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM folder WHERE project_id = ?;", [spaceID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO folder (id, project_id, name, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?);
            """,
            [id, spaceID, trimmed, SortOrder.between(last, nil), clock.now]
        )
        return try folder(id: id)
    }

    public func folder(id: String) throws -> Folder {
        guard let row = try database.queryOne("SELECT * FROM folder WHERE id = ?;", [id]) else {
            throw LocalBoardError.notFound(entity: "folder \(id)")
        }
        return try Folder(row: row)
    }

    public func renameFolder(_ folderID: String, to name: String) throws {
        let trimmed = try require(name, field: "name", detail: "A folder needs a name.")
        try update("folder", id: folderID, "name = ?", [trimmed])
    }

    public func setFolderArchived(_ archived: Bool, for folderID: String) throws {
        try update("folder", id: folderID, "archived = ?", [archived])
    }

    /// Deleting a folder keeps its lists: they fall back into the space,
    /// which is where a list with no folder belongs. Taking the cards with it
    /// would make tidying the sidebar a destructive act.
    public func deleteFolder(_ folderID: String) throws {
        try database.transaction {
            try database.execute("UPDATE list SET folder_id = NULL WHERE folder_id = ?;", [folderID])
            let changed = try database.execute("DELETE FROM folder WHERE id = ?;", [folderID])
            guard changed > 0 else { throw LocalBoardError.notFound(entity: "folder \(folderID)") }
        }
    }

    // MARK: - Lists

    public func lists(inSpace spaceID: String, includeArchived: Bool = false) throws -> [TaskList] {
        let sql = """
            SELECT * FROM list WHERE project_id = ?\(includeArchived ? "" : " AND archived = 0")
            ORDER BY sort_order;
            """
        return try database.query(sql, [spaceID]).map(TaskList.init(row:))
    }

    public func lists(inFolder folderID: String) throws -> [TaskList] {
        try database.query(
            "SELECT * FROM list WHERE folder_id = ? AND archived = 0 ORDER BY sort_order;", [folderID]
        ).map(TaskList.init(row:))
    }

    public func list(id: String) throws -> TaskList {
        guard let row = try database.queryOne("SELECT * FROM list WHERE id = ?;", [id]) else {
            throw LocalBoardError.notFound(entity: "list \(id)")
        }
        return try TaskList(row: row)
    }

    @discardableResult
    public func createList(inSpace spaceID: String, folderID: String? = nil, name: String) throws -> TaskList {
        let trimmed = try require(name, field: "name", detail: "A list needs a name.")
        let id = UUID().uuidString
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM list WHERE project_id = ?;", [spaceID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO list (id, project_id, folder_id, name, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [id, spaceID, folderID.sqlValue, trimmed, SortOrder.between(last, nil), clock.now]
        )
        return try list(id: id)
    }

    public func renameList(_ listID: String, to name: String) throws {
        let trimmed = try require(name, field: "name", detail: "A list needs a name.")
        try update("list", id: listID, "name = ?", [trimmed])
    }

    public func setListAppearance(color: String, icon: String, for listID: String) throws {
        try update("list", id: listID, "color = ?, icon = ?", [color, icon])
    }

    public func moveList(_ listID: String, toFolder folderID: String?) throws {
        try update("list", id: listID, "folder_id = ?", [folderID.sqlValue])
    }

    public func setListArchived(_ archived: Bool, for listID: String) throws {
        try update("list", id: listID, "archived = ?", [archived])
    }

    /// A list cannot simply be deleted out from under its cards, so deleting
    /// one asks where they go. Passing `nil` trashes them, which is
    /// recoverable; nothing here destroys work outright.
    public func deleteList(_ listID: String, movingCardsTo destination: String?) throws {
        try database.transaction {
            if let destination {
                try database.execute("UPDATE task SET list_id = ? WHERE list_id = ?;", [destination, listID])
            } else {
                try database.execute(
                    "UPDATE task SET trashed = 1, trashed_at = ? WHERE list_id = ? AND trashed = 0;",
                    [clock.now, listID]
                )
            }
            let changed = try database.execute("DELETE FROM list WHERE id = ?;", [listID])
            guard changed > 0 else { throw LocalBoardError.notFound(entity: "list \(listID)") }
        }
    }

    /// Where a space's lists are, keyed by folder id, with `nil` for the ones
    /// sitting straight in the space. One query for a whole sidebar.
    public func listsByFolder(inSpace spaceID: String) throws -> (loose: [TaskList], foldered: [String: [TaskList]]) {
        let all = try lists(inSpace: spaceID)
        var loose: [TaskList] = []
        var foldered: [String: [TaskList]] = [:]

        for list in all {
            if let folderID = list.folderID {
                foldered[folderID, default: []].append(list)
            } else {
                loose.append(list)
            }
        }
        return (loose, foldered)
    }

    // MARK: - Statuses, per space or per list

    /// The statuses a list uses: its own if it has said, otherwise its
    /// space's.
    ///
    /// Inheritance is the *absence* of rows rather than a flag, so there is no
    /// state where a list claims to override and overrides nothing.
    public func statuses(forList listID: String) throws -> [Status] {
        let overridden = try database.query(
            """
            SELECT status.* FROM list_status
            JOIN status ON status.id = list_status.status_id
            WHERE list_status.list_id = ?
            ORDER BY list_status.sort_order;
            """,
            [listID]
        ).map(Status.init(row:))

        guard overridden.isEmpty else { return overridden }

        let list = try list(id: listID)
        return try database.query(
            "SELECT * FROM status WHERE project_id = ? ORDER BY sort_order;", [list.projectID]
        ).map(Status.init(row:))
    }

    public func overridesStatuses(_ listID: String) throws -> Bool {
        try database.count("SELECT COUNT(*) FROM list_status WHERE list_id = ?;", [listID]) > 0
    }

    /// Replaces a list's override wholesale. An empty set removes the
    /// override entirely, which is how a list goes back to its space's
    /// statuses — the same action, not a separate "stop overriding" verb.
    public func setStatuses(_ statusIDs: [String], forList listID: String) throws {
        try database.transaction {
            try database.execute("DELETE FROM list_status WHERE list_id = ?;", [listID])
            for (index, statusID) in statusIDs.enumerated() {
                try database.execute(
                    "INSERT INTO list_status (list_id, status_id, sort_order) VALUES (?, ?, ?);",
                    [listID, statusID, Double(index + 1) * SortOrder.step]
                )
            }
        }
    }

    // MARK: - Helpers

    private func require(_ text: String, field: String, detail: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: field, detail: detail)
        }
        return trimmed
    }

    private func update(_ table: String, id: String, _ assignment: String, _ values: [SQLValueConvertible]) throws {
        let changed = try database.execute(
            "UPDATE \(table) SET \(assignment) WHERE id = ?;", values + [id]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "\(table) \(id)") }
    }
}
