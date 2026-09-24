import Foundation
import LocalBoardCore

/// Sprints: planning one, starting it, and closing it out.
///
/// The interesting moment is *starting*, because that is when a commitment is
/// made. What the sprint contained on its first day is written down rather
/// than derived, since a burndown drawn against today's contents would move
/// its own starting line every time work was added — hiding the exact thing
/// the chart exists to show.
public struct SprintRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    public func sprints(inProject projectID: String) throws -> [Sprint] {
        try database.query(
            "SELECT * FROM sprint WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ).map(Sprint.init(row:))
    }

    public func sprint(id: String) throws -> Sprint {
        guard let row = try database.queryOne("SELECT * FROM sprint WHERE id = ?;", [id]) else {
            throw LocalBoardError.notFound(entity: "sprint \(id)")
        }
        return try Sprint(row: row)
    }

    public func activeSprint(inProject projectID: String) throws -> Sprint? {
        try database.queryOne(
            "SELECT * FROM sprint WHERE project_id = ? AND state = ? LIMIT 1;",
            [projectID, SprintState.active.rawValue]
        ).map(Sprint.init(row:))
    }

    @discardableResult
    public func create(
        inProject projectID: String,
        name: String,
        goal: String = "",
        startsAt: Date? = nil,
        endsAt: Date? = nil
    ) throws -> Sprint {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A sprint needs a name.")
        }
        if let startsAt, let endsAt, endsAt < startsAt {
            throw LocalBoardError.invalidInput(
                field: "dates", detail: "A sprint cannot end before it starts."
            )
        }

        let id = UUID().uuidString
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM sprint WHERE project_id = ?;", [projectID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO sprint (id, project_id, name, goal, starts_at, ends_at, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [id, projectID, trimmed, goal, startsAt.sqlValue, endsAt.sqlValue,
             SortOrder.between(last, nil), clock.now]
        )
        return try sprint(id: id)
    }

    public func update(_ sprintID: String, name: String, goal: String, startsAt: Date?, endsAt: Date?) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A sprint needs a name.")
        }
        let changed = try database.execute(
            "UPDATE sprint SET name = ?, goal = ?, starts_at = ?, ends_at = ? WHERE id = ?;",
            [trimmed, goal, startsAt.sqlValue, endsAt.sqlValue, sprintID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "sprint \(sprintID)") }
    }

    public func delete(_ sprintID: String) throws {
        let changed = try database.execute("DELETE FROM sprint WHERE id = ?;", [sprintID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "sprint \(sprintID)") }
    }

    // MARK: - Membership

    public func tasks(inSprint sprintID: String) throws -> [BoardTask] {
        try database.query(
            "SELECT * FROM task WHERE sprint_id = ? AND trashed = 0 ORDER BY sort_order;",
            [sprintID]
        ).map(BoardTask.init(row:))
    }

    public func setSprint(_ sprintID: String?, for taskID: String) throws {
        try TaskRepository(database: database, clock: clock)
            .update(taskID, "sprint_id = ?", [sprintID.sqlValue])
    }

    // MARK: - Starting and finishing

    /// Starts a sprint and records what it committed to.
    ///
    /// One sprint runs at a time per project: two would each claim to be what
    /// the team is doing now, and every report that says "this sprint" would
    /// have to pick one.
    public func start(_ sprintID: String) throws {
        try database.transaction {
            let sprint = try sprint(id: sprintID)
            guard sprint.state == .planned else {
                throw LocalBoardError.invalidInput(
                    field: "sprint",
                    detail: "\(sprint.name) has already been started."
                )
            }
            if let running = try activeSprint(inProject: sprint.projectID) {
                throw LocalBoardError.invalidInput(
                    field: "sprint",
                    detail: "\(running.name) is still running. Complete it first."
                )
            }

            let now = clock.now
            let starts = sprint.startsAt ?? now
            // A sprint with no end date gets a fortnight, which is a guess —
            // but a burndown needs a finish line, and no line at all is worse
            // than one the user can move.
            let ends = sprint.endsAt ?? Calendar.current.date(byAdding: .day, value: 14, to: starts) ?? starts

            try database.execute(
                "UPDATE sprint SET state = ?, starts_at = ?, ends_at = ? WHERE id = ?;",
                [SprintState.active.rawValue, starts, ends, sprintID]
            )

            // The commitment, frozen. Estimates are copied too: re-sizing a
            // card mid-sprint changes what is left to do, not what was agreed.
            try database.execute(
                """
                INSERT INTO sprint_commitment (sprint_id, task_id, estimate)
                SELECT ?, id, estimate FROM task WHERE sprint_id = ? AND trashed = 0;
                """,
                [sprintID, sprintID]
            )
        }
    }

    /// Finishes a sprint, moving whatever is unfinished somewhere else.
    ///
    /// Unfinished work does not evaporate and is not quietly marked done. It
    /// goes to the next sprint if one is named, or back to no sprint at all,
    /// and either way the team can see what did not fit.
    @discardableResult
    public func complete(_ sprintID: String, carryingOverTo nextSprintID: String? = nil) throws -> Int {
        try database.transaction {
            let sprint = try sprint(id: sprintID)
            guard sprint.state == .active else {
                throw LocalBoardError.invalidInput(
                    field: "sprint", detail: "\(sprint.name) is not running."
                )
            }
            if let nextSprintID {
                let next = try self.sprint(id: nextSprintID)
                guard next.state != .complete else {
                    throw LocalBoardError.invalidInput(
                        field: "sprint", detail: "\(next.name) is already finished."
                    )
                }
                guard next.id != sprintID else {
                    throw LocalBoardError.invalidInput(
                        field: "sprint", detail: "A sprint cannot carry over into itself."
                    )
                }
            }

            let unfinished = try database.query(
                "SELECT id FROM task WHERE sprint_id = ? AND trashed = 0 AND completed_at IS NULL;",
                [sprintID]
            ).compactMap { $0.string("id") }

            let now = clock.now
            for taskID in unfinished {
                try database.execute(
                    "UPDATE task SET sprint_id = ?, updated_at = ? WHERE id = ?;",
                    [nextSprintID.sqlValue, now, taskID]
                )
            }

            try database.execute(
                "UPDATE sprint SET state = ?, completed_at = ? WHERE id = ?;",
                [SprintState.complete.rawValue, now, sprintID]
            )
            return unfinished.count
        }
    }

    // MARK: - Reporting

    /// What the sprint said it would do, as it stood on its first day.
    public func commitment(ofSprint sprintID: String) throws -> [(taskID: String, estimate: Double?)] {
        try database.query(
            "SELECT * FROM sprint_commitment WHERE sprint_id = ?;", [sprintID]
        ).map { row in
            (try row.requiredString("task_id"), row.double("estimate"))
        }
    }

    /// Cards and points completed, for the velocity chart.
    ///
    /// Only finished sprints count. A sprint still running has not yet
    /// achieved a velocity, and including it would drag the average down by
    /// however much of it has not happened yet.
    public func velocity(inProject projectID: String) throws -> [SprintVelocity] {
        let finished = try sprints(inProject: projectID).filter { $0.state == .complete }

        return try finished.map { sprint in
            let committed = try commitment(ofSprint: sprint.id)
            let committedPoints = committed.reduce(0.0) { $0 + ($1.estimate ?? 0) }

            guard let row = try database.queryOne(
                """
                SELECT COUNT(*) AS cards, COALESCE(SUM(estimate), 0) AS points
                FROM task WHERE sprint_id = ? AND trashed = 0 AND completed_at IS NOT NULL;
                """,
                [sprint.id]
            ) else {
                return SprintVelocity(sprint: sprint, committedCards: committed.count,
                                      committedPoints: committedPoints, completedCards: 0,
                                      completedPoints: 0)
            }

            return SprintVelocity(
                sprint: sprint,
                committedCards: committed.count,
                committedPoints: committedPoints,
                completedCards: Int(row.int("cards") ?? 0),
                completedPoints: row.double("points") ?? 0
            )
        }
    }
}

/// One sprint's committed and delivered work.
public struct SprintVelocity: Sendable, Equatable, Identifiable {
    public let sprint: Sprint
    public let committedCards: Int
    public let committedPoints: Double
    public let completedCards: Int
    public let completedPoints: Double

    public var id: String { sprint.id }

    public init(
        sprint: Sprint,
        committedCards: Int,
        committedPoints: Double,
        completedCards: Int,
        completedPoints: Double
    ) {
        self.sprint = sprint
        self.committedCards = committedCards
        self.committedPoints = committedPoints
        self.completedCards = completedCards
        self.completedPoints = completedPoints
    }
}
