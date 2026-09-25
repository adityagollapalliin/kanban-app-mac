import Foundation
import LocalBoardCore

/// Dashboards and the widgets on them.
///
/// Position is stored as grid cells and worked out by `DashboardLayout` from
/// the order the widgets are in, so a dashboard laid out on a large display
/// still reads on a small one. What is saved is therefore the order; the
/// coordinates are saved alongside it so that anything reading the table
/// directly sees the same arrangement the app draws.
public struct DashboardRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    public func dashboards(inProject projectID: String) throws -> [Dashboard] {
        try database.query(
            "SELECT * FROM dashboard WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ).map(Dashboard.init(row:))
    }

    @discardableResult
    public func create(inProject projectID: String, named name: String) throws -> Dashboard {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A dashboard needs a name.")
        }
        let id = UUID().uuidString
        let now = clock.now
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM dashboard WHERE project_id = ?;", [projectID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO dashboard (id, project_id, name, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [id, projectID, trimmed, SortOrder.between(last, nil), now, now]
        )
        guard let row = try database.queryOne("SELECT * FROM dashboard WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The dashboard was not written.")
        }
        return try Dashboard(row: row)
    }

    public func rename(_ dashboardID: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A dashboard needs a name.")
        }
        let changed = try database.execute(
            "UPDATE dashboard SET name = ?, updated_at = ? WHERE id = ?;", [trimmed, clock.now, dashboardID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "dashboard \(dashboardID)") }
    }

    public func delete(_ dashboardID: String) throws {
        let changed = try database.execute("DELETE FROM dashboard WHERE id = ?;", [dashboardID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "dashboard \(dashboardID)") }
    }

    // MARK: - Widgets

    /// In the order they are laid out: down the rows, then across.
    public func widgets(on dashboardID: String) throws -> [DashboardWidget] {
        try database.query(
            """
            SELECT * FROM dashboard_widget WHERE dashboard_id = ?
            ORDER BY grid_row, grid_column, created_at;
            """,
            [dashboardID]
        ).map(DashboardWidget.init(row:))
    }

    @discardableResult
    public func addWidget(
        to dashboardID: String,
        kind: DashboardWidgetKind,
        title: String = "",
        query: String = "",
        config: DashboardWidgetConfig = DashboardWidgetConfig()
    ) throws -> DashboardWidget {
        let id = UUID().uuidString
        let size = kind.defaultSize
        let existing = try widgets(on: dashboardID)
        // It goes on the end, which after packing is the first gap that fits.
        let row = DashboardLayout.rowCount(existing)

        try database.execute(
            """
            INSERT INTO dashboard_widget (
                id, dashboard_id, kind, title, query, grid_column, grid_row, width, height, config, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [id, dashboardID, kind.rawValue, title, query, 0, row, size.width, size.height,
             config.stored, clock.now]
        )

        guard let stored = try database.queryOne("SELECT * FROM dashboard_widget WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The widget was not written.")
        }
        return try DashboardWidget(row: stored)
    }

    public func update(_ widget: DashboardWidget) throws {
        let changed = try database.execute(
            """
            UPDATE dashboard_widget SET
                kind = ?, title = ?, query = ?, grid_column = ?, grid_row = ?,
                width = ?, height = ?, config = ?
            WHERE id = ?;
            """,
            [widget.kind.rawValue, widget.title, widget.query, widget.column, widget.row,
             widget.width, widget.height, widget.config.stored, widget.id]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "widget \(widget.id)") }
    }

    public func removeWidget(_ widgetID: String) throws {
        let changed = try database.execute("DELETE FROM dashboard_widget WHERE id = ?;", [widgetID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "widget \(widgetID)") }
    }

    /// Writes down where the widgets ended up after a drag.
    ///
    /// The caller passes them in the order they should read; this packs them
    /// into `columns` and saves the resulting cells, so what is on screen and
    /// what is in the file agree.
    @discardableResult
    public func saveLayout(_ widgets: [DashboardWidget], columns: Int) throws -> [DashboardWidget] {
        let packed = DashboardLayout.pack(widgets, columns: columns)
        try database.transaction {
            for widget in packed {
                try database.execute(
                    """
                    UPDATE dashboard_widget SET grid_column = ?, grid_row = ?, width = ?, height = ?
                    WHERE id = ?;
                    """,
                    [widget.column, widget.row, widget.width, widget.height, widget.id]
                )
            }
        }
        return packed
    }

    /// A dashboard worth opening on the day it is made.
    ///
    /// An empty grid with an "Add widget" button teaches nothing about what a
    /// widget is. Four that already say something about this project do.
    @discardableResult
    public func createStarter(inProject projectID: String, named name: String = "Overview") throws -> Dashboard {
        let dashboard = try create(inProject: projectID, named: name)
        try addWidget(to: dashboard.id, kind: .taskCount, title: "Open", query: "is:open")
        try addWidget(to: dashboard.id, kind: .statusBreakdown, title: "By status")
        try addWidget(to: dashboard.id, kind: .taskList, title: "Overdue", query: "is:overdue")
        try addWidget(to: dashboard.id, kind: .timeTracked, title: "Time this month")
        return dashboard
    }
}
