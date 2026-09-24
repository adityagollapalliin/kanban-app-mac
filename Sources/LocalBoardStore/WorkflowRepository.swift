import Foundation
import LocalBoardCore

/// Which moves a project allows, and the rules it applies to itself.
///
/// Note the asymmetry with WIP limits, which is deliberate. A WIP limit
/// *reports*: the board says a column is over its limit and lets the drop
/// happen, because the limit is a agreement between people and the board is
/// not a party to it. A workflow rule *refuses*: it exists precisely because
/// somebody wanted certain moves to be impossible, and a rule that only
/// tutted would not be that.
///
/// So it is off by default, and a project with enforcement on but no
/// transitions defined still allows everything — you have to say what is
/// allowed before anything can be forbidden.
public struct WorkflowRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - Transitions

    public func transitions(inProject projectID: String) throws -> [WorkflowTransition] {
        try database.query(
            "SELECT * FROM workflow_transition WHERE project_id = ?;", [projectID]
        ).map(WorkflowTransition.init(row:))
    }

    public func allow(from fromStatusID: String, to toStatusID: String, inProject projectID: String) throws {
        guard fromStatusID != toStatusID else { return }
        try database.execute(
            """
            INSERT INTO workflow_transition (id, project_id, from_status_id, to_status_id)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (project_id, from_status_id, to_status_id) DO NOTHING;
            """,
            [UUID().uuidString, projectID, fromStatusID, toStatusID]
        )
    }

    public func forbid(from fromStatusID: String, to toStatusID: String, inProject projectID: String) throws {
        try database.execute(
            """
            DELETE FROM workflow_transition
            WHERE project_id = ? AND from_status_id = ? AND to_status_id = ?;
            """,
            [projectID, fromStatusID, toStatusID]
        )
    }

    public func setEnforced(_ enforced: Bool, inProject projectID: String) throws {
        let changed = try database.execute(
            "UPDATE project SET enforce_workflow = ? WHERE id = ?;", [enforced, projectID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "project \(projectID)") }
    }

    /// Turns the project's current columns into "anything may go forwards one
    /// step, and anything may go back".
    ///
    /// A starting point, because an empty rule set that forbids nothing and a
    /// full one that forbids everything are both useless, and writing every
    /// pair by hand is how people give up on the feature.
    public func seedSequentialTransitions(inProject projectID: String) throws {
        let statuses = try BoardRepository(database: database, clock: clock).statuses(inProject: projectID)
        guard statuses.count > 1 else { return }

        try database.transaction {
            for (index, status) in statuses.enumerated() {
                if index + 1 < statuses.count {
                    try allow(from: status.id, to: statuses[index + 1].id, inProject: projectID)
                }
                if index > 0 {
                    try allow(from: status.id, to: statuses[index - 1].id, inProject: projectID)
                }
            }
        }
    }

    // MARK: - Asking

    /// Whether a card may move from one column to another.
    ///
    /// Everything is allowed unless the project has both turned enforcement on
    /// *and* said what is allowed. That keeps the failure mode on the side of
    /// letting work move: a half-configured project does not trap its cards.
    public func permits(from fromStatusID: String, to toStatusID: String, inProject projectID: String) throws -> Bool {
        guard fromStatusID != toStatusID else { return true }

        guard let row = try database.queryOne(
            "SELECT enforce_workflow FROM project WHERE id = ?;", [projectID]
        ), row.bool("enforce_workflow") == true else { return true }

        let defined = try database.count(
            "SELECT COUNT(*) FROM workflow_transition WHERE project_id = ?;", [projectID]
        )
        guard defined > 0 else { return true }

        return try database.count(
            """
            SELECT COUNT(*) FROM workflow_transition
            WHERE project_id = ? AND from_status_id = ? AND to_status_id = ?;
            """,
            [projectID, fromStatusID, toStatusID]
        ) > 0
    }

    /// The columns a card in this one may be moved to. Used to grey out the
    /// rest rather than let someone try and be told no.
    public func allowedDestinations(from fromStatusID: String, inProject projectID: String) throws -> Set<String>? {
        guard let row = try database.queryOne(
            "SELECT enforce_workflow FROM project WHERE id = ?;", [projectID]
        ), row.bool("enforce_workflow") == true else { return nil }

        let all = try transitions(inProject: projectID)
        guard !all.isEmpty else { return nil }

        var allowed = Set(all.filter { $0.fromStatusID == fromStatusID }.map(\.toStatusID))
        allowed.insert(fromStatusID)
        return allowed
    }
}
