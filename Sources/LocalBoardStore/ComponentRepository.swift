import Foundation
import LocalBoardCore

/// Components, the versions a card affects or is fixed in, and the resolution
/// it was closed with.
///
/// Three small things that share one idea: they are all facts about a card
/// that a *project* defines the vocabulary for, and all three are set and
/// cleared together when work is finished.
public struct ComponentRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - Components

    public func components(inProject projectID: String) throws -> [Component] {
        try database.query(
            "SELECT * FROM component WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ).map(Component.init(row:))
    }

    @discardableResult
    public func create(
        inProject projectID: String,
        name: String,
        description: String = "",
        defaultAssigneeID: String? = nil
    ) throws -> Component {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A component needs a name.")
        }

        let id = UUID().uuidString
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM component WHERE project_id = ?;", [projectID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO component (id, project_id, name, description, default_assignee_id,
                                   sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [id, projectID, trimmed, description, defaultAssigneeID.sqlValue,
             SortOrder.between(last, nil), clock.now]
        )

        guard let row = try database.queryOne("SELECT * FROM component WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The component was not written.")
        }
        return try Component(row: row)
    }

    public func update(_ component: Component) throws {
        let trimmed = component.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A component needs a name.")
        }
        let changed = try database.execute(
            """
            UPDATE component SET name = ?, description = ?, default_assignee_id = ?, sort_order = ?
            WHERE id = ?;
            """,
            [trimmed, component.description, component.defaultAssigneeID.sqlValue,
             component.sortOrder, component.id]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "component \(component.id)") }
    }

    /// Removes a component. Cards lose the tag; nothing else about them moves.
    public func delete(_ componentID: String) throws {
        let changed = try database.execute("DELETE FROM component WHERE id = ?;", [componentID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "component \(componentID)") }
    }

    // MARK: Components on a card

    public func components(forTask taskID: String) throws -> [Component] {
        try database.query(
            """
            SELECT component.* FROM component
            JOIN task_component ON task_component.component_id = component.id
            WHERE task_component.task_id = ?
            ORDER BY component.sort_order;
            """,
            [taskID]
        ).map(Component.init(row:))
    }

    /// Every card's components in one project, for the board's rows.
    public func componentsByTask(inProject projectID: String) throws -> [String: [Component]] {
        var found: [String: [Component]] = [:]
        try database.forEachRow(
            """
            SELECT task_component.task_id AS holder, component.* FROM component
            JOIN task_component ON task_component.component_id = component.id
            WHERE component.project_id = ?
            ORDER BY component.sort_order;
            """,
            [projectID]
        ) { row in
            found[try row.requiredString("holder"), default: []].append(try Component(row: row))
        }
        return found
    }

    /// Adds a card to a component.
    ///
    /// - Parameter assigningDefault: when the card has nobody on it and the
    ///   component has a default assignee, the card is assigned. That is the
    ///   point of a component's default — work filed against it lands on the
    ///   right person without anybody choosing. A card that *is* assigned is
    ///   left alone, because somebody already chose.
    public func add(_ componentID: String, toTask taskID: String, assigningDefault: Bool = true) throws {
        try database.transaction {
            try database.execute(
                """
                INSERT INTO task_component (task_id, component_id) VALUES (?, ?)
                ON CONFLICT (task_id, component_id) DO NOTHING;
                """,
                [taskID, componentID]
            )

            guard assigningDefault else { return }
            guard let component = try database.queryOne(
                "SELECT default_assignee_id FROM component WHERE id = ?;", [componentID]
            )?.string("default_assignee_id") else { return }

            let assigned = try database.queryOne(
                "SELECT assignee_id FROM task WHERE id = ?;", [taskID]
            )?.string("assignee_id")
            guard assigned == nil else { return }

            try database.execute(
                "UPDATE task SET assignee_id = ?, updated_at = ? WHERE id = ?;",
                [component, clock.now, taskID]
            )
            try database.execute(
                """
                INSERT INTO task_assignee (task_id, person_id, estimate, sort_order)
                VALUES (?, ?, NULL, 1000.0)
                ON CONFLICT (task_id, person_id) DO NOTHING;
                """,
                [taskID, component]
            )
        }
    }

    public func remove(_ componentID: String, fromTask taskID: String) throws {
        try database.execute(
            "DELETE FROM task_component WHERE task_id = ? AND component_id = ?;",
            [taskID, componentID]
        )
    }

    // MARK: - Versions on a card

    public func versions(forTask taskID: String, role: VersionRole) throws -> [Version] {
        try database.query(
            """
            SELECT version.* FROM version
            JOIN task_version ON task_version.version_id = version.id
            WHERE task_version.task_id = ? AND task_version.kind = ?
            ORDER BY version.sort_order;
            """,
            [taskID, role.rawValue]
        ).map(Version.init(row:))
    }

    /// Adds a version to a card in one role or the other.
    ///
    /// `task.version_id` keeps meaning the *first* fix version, exactly as
    /// `assignee_id` has meant the first assignee since v6 — so every query,
    /// badge and report that reads it carries on working.
    public func add(_ versionID: String, toTask taskID: String, as role: VersionRole) throws {
        try database.transaction {
            try database.execute(
                """
                INSERT INTO task_version (task_id, version_id, kind) VALUES (?, ?, ?)
                ON CONFLICT (task_id, version_id, kind) DO NOTHING;
                """,
                [taskID, versionID, role.rawValue]
            )
            if role == .fix { try syncFirstFixVersion(taskID) }
        }
    }

    public func remove(_ versionID: String, fromTask taskID: String, as role: VersionRole) throws {
        try database.transaction {
            try database.execute(
                "DELETE FROM task_version WHERE task_id = ? AND version_id = ? AND kind = ?;",
                [taskID, versionID, role.rawValue]
            )
            if role == .fix { try syncFirstFixVersion(taskID) }
        }
    }

    private func syncFirstFixVersion(_ taskID: String) throws {
        let first = try database.queryOne(
            """
            SELECT version.id AS id FROM version
            JOIN task_version ON task_version.version_id = version.id
            WHERE task_version.task_id = ? AND task_version.kind = 0
            ORDER BY version.sort_order LIMIT 1;
            """,
            [taskID]
        )?.string("id")

        try database.execute(
            "UPDATE task SET version_id = ?, updated_at = ? WHERE id = ?;",
            [first.sqlValue, clock.now, taskID]
        )
    }

    // MARK: - Resolution

    /// Sets why a card was closed, and when.
    ///
    /// Passing nil clears both, which is what reopening means.
    public func setResolution(_ resolutionID: String?, forTask taskID: String) throws {
        let now = clock.now
        let changed = try database.execute(
            "UPDATE task SET resolution_id = ?, resolved_at = ?, updated_at = ? WHERE id = ?;",
            [resolutionID.sqlValue, resolutionID == nil ? SQLValue.null : .real(now.timeIntervalSince1970),
             now, taskID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "task \(taskID)") }
    }

    public func resolution(forTask taskID: String) throws -> Resolution? {
        try database.queryOne(
            """
            SELECT resolution.* FROM resolution
            JOIN task ON task.resolution_id = resolution.id
            WHERE task.id = ?;
            """,
            [taskID]
        ).map(Resolution.init(row:))
    }

    /// Keeps the resolution in step with the card's column.
    ///
    /// A card arriving in a Done column with no resolution is given the
    /// project's default; a card leaving one has its resolution cleared,
    /// because "why it was closed" is not a fact about a card that is open.
    ///
    /// Category, never the column's name: a project whose last column is
    /// called "Shipped" works exactly the same.
    public func reconcileResolution(forTask taskID: String) throws {
        guard let row = try database.queryOne(
            """
            SELECT task.project_id AS project_id, task.resolution_id AS resolution_id,
                   status.category AS category
            FROM task JOIN status ON status.id = task.status_id
            WHERE task.id = ?;
            """,
            [taskID]
        ) else { return }

        let isDone = (row.int("category") ?? 0) == Int64(StatusCategory.done.rawValue)
        let current = row.string("resolution_id")

        if isDone, current == nil {
            let projectID = try row.requiredString("project_id")
            guard let fallback = try VocabularyRepository(database: database, clock: clock)
                .defaultResolution(inProject: projectID) else { return }
            try setResolution(fallback.id, forTask: taskID)
        } else if !isDone, current != nil {
            try setResolution(nil, forTask: taskID)
        }
    }
}
