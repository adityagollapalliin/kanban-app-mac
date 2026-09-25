import Foundation
import LocalBoardCore

/// What each view remembers about how it was left.
///
/// Per view *and* per place. The table you set up on one list should not
/// rearrange the table on another: they show different work, and the columns
/// that matter differ with it. One row per (place, view), so there is no way
/// for two settings to describe the same screen.
public struct ViewConfigRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    /// The saved settings, or a fresh set. Never `nil`: a view that has never
    /// been configured still has to open, and "the defaults" is a perfectly
    /// good answer to how it was left.
    public func config(
        _ viewKind: ViewKind, scope: ViewScopeKind, id scopeID: String = ""
    ) throws -> ViewConfig {
        if let row = try database.queryOne(
            "SELECT * FROM view_config WHERE scope_kind = ? AND scope_id = ? AND view_kind = ?;",
            [scope.rawValue, scopeID, viewKind.rawValue]
        ) {
            return try ViewConfig(row: row)
        }
        return ViewConfig(
            id: UUID().uuidString,
            scopeKind: scope,
            scopeID: scopeID,
            viewKind: viewKind,
            updatedAt: clock.now
        )
    }

    public func save(_ config: ViewConfig) throws {
        try database.execute(
            """
            INSERT INTO view_config (id, scope_kind, scope_id, view_kind, group_by, sort_field,
                                     sort_ascending, filter_query, columns, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (scope_kind, scope_id, view_kind) DO UPDATE SET
                group_by = ?, sort_field = ?, sort_ascending = ?, filter_query = ?,
                columns = ?, updated_at = ?;
            """,
            [
                config.id, config.scopeKind.rawValue, config.scopeID, config.viewKind.rawValue,
                config.groupBy, config.sortField, config.sortAscending, config.filterQuery,
                config.columnList, clock.now,
                config.groupBy, config.sortField, config.sortAscending, config.filterQuery,
                config.columnList, clock.now,
            ]
        )
    }

    /// Forgets the settings for a place that no longer exists, so a new list
    /// reusing an id cannot inherit a dead one's columns.
    public func forget(scope: ViewScopeKind, id scopeID: String) throws {
        try database.execute(
            "DELETE FROM view_config WHERE scope_kind = ? AND scope_id = ?;", [scope.rawValue, scopeID]
        )
    }
}
