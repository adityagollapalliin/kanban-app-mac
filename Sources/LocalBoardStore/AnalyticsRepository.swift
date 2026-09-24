import Foundation
import LocalBoardCore

/// The numbers behind the charts, computed from `status_change`.
///
/// Every figure here is *derived*, never stored. There is no cache to go stale
/// and no nightly job to miss a run: the history is the record, and a chart is
/// a question asked of it. That is affordable because the history of a local
/// board is small — a busy year is tens of thousands of rows, which SQLite
/// hands over in milliseconds and this replays in one pass.
///
/// The replay is the interesting part. A cumulative flow diagram asks "where
/// was every card at the end of each day", which no single row answers; it is
/// reconstructed by walking each card's moves in order and carrying its
/// position forward across the days between them.
public struct AnalyticsRepository {

    let database: Database
    private let clock: any ClockProvider
    private let calendar: Calendar

    public init(
        database: Database,
        clock: any ClockProvider = SystemClock(),
        calendar: Calendar = .current
    ) {
        self.database = database
        self.clock = clock
        self.calendar = calendar
    }

    // MARK: - Cumulative flow

    /// How many cards stood in each status category at the end of each day.
    ///
    /// Trashed cards are left out, and so is everything before `days` ago, but
    /// a card's *position* is carried in from before the window — otherwise
    /// the diagram would start empty and climb, showing a team's whole backlog
    /// as if it had been created on the first day of the chart.
    public func cumulativeFlow(inProject projectID: String, days: Int = 30) throws -> [FlowPoint] {
        let categories = try statusCategories(inProject: projectID)
        let changes = try changes(inProject: projectID)
        guard !changes.isEmpty else { return [] }

        let today = calendar.startOfDay(for: clock.now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today

        // Where each card stood, updated as the replay passes each move.
        var position: [String: StatusCategory] = [:]
        var index = 0
        var points: [FlowPoint] = []

        var day = start
        // Everything that happened before the window still decides where the
        // cards were when it opened.
        while index < changes.count, changes[index].at < start {
            position[changes[index].taskID] = categories[changes[index].toStatusID] ?? .toDo
            index += 1
        }

        while day <= today {
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            while index < changes.count, changes[index].at < endOfDay {
                position[changes[index].taskID] = categories[changes[index].toStatusID] ?? .toDo
                index += 1
            }

            var counts: [StatusCategory: Int] = [:]
            for category in position.values {
                counts[category, default: 0] += 1
            }

            points.append(FlowPoint(
                day: day,
                toDo: counts[.toDo] ?? 0,
                inProgress: counts[.inProgress] ?? 0,
                done: counts[.done] ?? 0
            ))
            day = endOfDay
        }

        return points
    }

    // MARK: - Control chart

    /// Cycle and lead time for every card finished in the window.
    ///
    /// Cycle time is measured from the first move into work, not from
    /// creation: a card that sat in the backlog for a month and then took two
    /// days took two days. Lead time measures the month as well, because that
    /// is what the person waiting for it experienced.
    public func controlChart(inProject projectID: String, days: Int = 90) throws -> [CycleTimePoint] {
        let categories = try statusCategories(inProject: projectID)
        let changes = try changes(inProject: projectID)
        let createdAt = try creationDates(inProject: projectID)

        let today = calendar.startOfDay(for: clock.now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today

        var startedWork: [String: Date] = [:]
        var finished: [String: Date] = [:]

        for change in changes {
            guard let category = categories[change.toStatusID] else { continue }

            switch category {
            case .inProgress:
                // The *first* time it started. A card sent back for rework and
                // started again did not start twice.
                if startedWork[change.taskID] == nil { startedWork[change.taskID] = change.at }
            case .done:
                if finished[change.taskID] == nil { finished[change.taskID] = change.at }
            case .toDo:
                // Moved back out of done: it was not finished after all, and
                // the eventual finish is the one that counts.
                finished[change.taskID] = nil
            }
        }

        return finished.compactMap { taskID, completedAt -> CycleTimePoint? in
            guard completedAt >= start else { return nil }
            // A card that went straight to done never entered work; its cycle
            // time is measured from creation, which is the only honest answer.
            let began = startedWork[taskID] ?? createdAt[taskID] ?? completedAt
            let created = createdAt[taskID] ?? began

            return CycleTimePoint(
                taskID: taskID,
                completedAt: completedAt,
                cycleTime: max(0, completedAt.timeIntervalSince(began)) / 86_400,
                leadTime: max(0, completedAt.timeIntervalSince(created)) / 86_400
            )
        }
        .sorted { $0.completedAt < $1.completedAt }
    }

    // MARK: - Burnup

    /// Scope and completion over time for a set of cards.
    ///
    /// Both lines move. Scope rises as work is added, which is the whole point
    /// of a burnup rather than a burndown: a release that slipped because it
    /// grew looks entirely different from one that slipped because it stalled,
    /// and only the top line tells them apart.
    public func burnup(taskIDs: Set<String>, days: Int = 60) throws -> [BurnupPoint] {
        guard !taskIDs.isEmpty else { return [] }

        let today = calendar.startOfDay(for: clock.now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today

        let tasks = try database.query(
            "SELECT id, created_at, completed_at FROM task WHERE trashed = 0;"
        ).filter { taskIDs.contains((try? $0.requiredString("id")) ?? "") }

        var created: [Date] = []
        var completed: [Date] = []
        for row in tasks {
            if let at = row.date("created_at") { created.append(at) }
            if let at = row.date("completed_at") { completed.append(at) }
        }

        var points: [BurnupPoint] = []
        var day = start
        while day <= today {
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            points.append(BurnupPoint(
                day: day,
                scope: created.count { $0 < endOfDay },
                done: completed.count { $0 < endOfDay }
            ))
            day = endOfDay
        }
        return points
    }

    // MARK: - Reading

    private func statusCategories(inProject projectID: String) throws -> [String: StatusCategory] {
        var categories: [String: StatusCategory] = [:]
        try database.forEachRow(
            "SELECT id, category FROM status WHERE project_id = ?;", [projectID]
        ) { row in
            categories[try row.requiredString("id")] = try row.requiredEnum("category", StatusCategory.self)
        }
        return categories
    }

    private func creationDates(inProject projectID: String) throws -> [String: Date] {
        var dates: [String: Date] = [:]
        try database.forEachRow(
            "SELECT id, created_at FROM task WHERE project_id = ? AND trashed = 0;", [projectID]
        ) { row in
            dates[try row.requiredString("id")] = try row.requiredDate("created_at")
        }
        return dates
    }

    /// Every move in the project, oldest first — the order the replay needs.
    private func changes(inProject projectID: String) throws -> [StatusChange] {
        try database.query(
            """
            SELECT status_change.* FROM status_change
            JOIN task ON task.id = status_change.task_id
            WHERE task.project_id = ? AND task.trashed = 0
            ORDER BY status_change.at;
            """,
            [projectID]
        ).map(StatusChange.init(row:))
    }
}

/// One day of a cumulative flow diagram.
public struct FlowPoint: Sendable, Equatable, Identifiable {
    public let day: Date
    public let toDo: Int
    public let inProgress: Int
    public let done: Int

    public var id: Date { day }
    public var total: Int { toDo + inProgress + done }

    public init(day: Date, toDo: Int, inProgress: Int, done: Int) {
        self.day = day
        self.toDo = toDo
        self.inProgress = inProgress
        self.done = done
    }

    public func count(for category: StatusCategory) -> Int {
        switch category {
        case .toDo: toDo
        case .inProgress: inProgress
        case .done: done
        }
    }
}

/// One finished card, and how long it took. Both figures in days.
public struct CycleTimePoint: Sendable, Equatable, Identifiable {
    public let taskID: String
    public let completedAt: Date
    public let cycleTime: Double
    public let leadTime: Double

    public var id: String { taskID }

    public init(taskID: String, completedAt: Date, cycleTime: Double, leadTime: Double) {
        self.taskID = taskID
        self.completedAt = completedAt
        self.cycleTime = cycleTime
        self.leadTime = leadTime
    }
}

/// One day of a burnup: how much work there was, and how much was finished.
public struct BurnupPoint: Sendable, Equatable, Identifiable {
    public let day: Date
    public let scope: Int
    public let done: Int

    public var id: Date { day }

    public init(day: Date, scope: Int, done: Int) {
        self.day = day
        self.scope = scope
        self.done = done
    }
}

extension Array where Element == CycleTimePoint {

    /// A rolling mean over the previous `window` finished cards.
    ///
    /// Rolling rather than cumulative because a control chart is asking what
    /// is happening now, and an average that includes last spring never moves.
    public func rollingAverage(window: Int = 7, using value: (CycleTimePoint) -> Double) -> [Double] {
        indices.map { index in
            let lower = Swift.max(0, index - window + 1)
            let slice = self[lower...index]
            return slice.reduce(0) { $0 + value($1) } / Double(slice.count)
        }
    }

    /// The population standard deviation of the whole series.
    ///
    /// Drawn as a band around the average, it is what turns a scatter of dots
    /// into a statement: a card outside it did not merely take longer, it took
    /// unusually long, and that is worth going and looking at.
    public func standardDeviation(using value: (CycleTimePoint) -> Double) -> Double {
        guard count > 1 else { return 0 }
        let values = map(value)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
}

// MARK: - Sprint reporting

extension AnalyticsRepository {

    /// A sprint's burndown: what was left to do at the end of each day, against
    /// the straight line it would have followed if work had gone evenly.
    ///
    /// Measured against the sprint's *commitment*, recorded on the day it
    /// started, not against its contents now. A burndown drawn against today's
    /// contents would move its own starting line every time work was added,
    /// which hides scope creep — the single thing the chart is best at showing.
    /// Work added later still appears, as a line that fails to reach zero.
    public func burndown(sprint: Sprint, points: Bool = true) throws -> [BurndownPoint] {
        guard let startsAt = sprint.startsAt, let endsAt = sprint.endsAt else { return [] }

        let sprints = SprintRepository(database: database, clock: clock)
        let committed = try sprints.commitment(ofSprint: sprint.id)
        let current = try sprints.tasks(inSprint: sprint.id)

        // Everything the sprint has ever held: what it committed to, plus
        // whatever has been added since.
        var weights: [String: Double] = [:]
        for entry in committed {
            weights[entry.taskID] = points ? (entry.estimate ?? 0) : 1
        }
        for task in current where weights[task.id] == nil {
            weights[task.id] = points ? (task.estimate ?? 0) : 1
        }

        let committedTotal = committed.reduce(0.0) { $0 + (points ? ($1.estimate ?? 0) : 1) }

        // When each card was finished, so the replay knows what had gone by
        // the end of each day.
        var finished: [String: Date] = [:]
        try database.forEachRow(
            "SELECT id, completed_at FROM task WHERE sprint_id = ? AND completed_at IS NOT NULL;",
            [sprint.id]
        ) { row in
            finished[try row.requiredString("id")] = row.date("completed_at")
        }

        // When each card joined, for scope added after the start. `created_at`
        // is the best available answer: the schema records when a card was
        // made, not when it was put in a sprint.
        var joined: [String: Date] = [:]
        for task in current { joined[task.id] = task.createdAt }

        let today = calendar.startOfDay(for: clock.now)
        let first = calendar.startOfDay(for: startsAt)
        let last = calendar.startOfDay(for: endsAt)
        let length = max(1, calendar.dateComponents([.day], from: first, to: last).day ?? 1)

        var result: [BurndownPoint] = []
        var day = first
        var index = 0

        while day <= last {
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day

            var scope = 0.0
            var done = 0.0
            for (taskID, weight) in weights {
                let arrived = joined[taskID].map { $0 < endOfDay } ?? true
                let wasCommitted = weights[taskID] != nil && committed.contains { $0.taskID == taskID }
                guard wasCommitted || arrived else { continue }

                scope += weight
                if let at = finished[taskID], at < endOfDay { done += weight }
            }

            result.append(BurndownPoint(
                day: day,
                remaining: max(0, scope - done),
                ideal: committedTotal * (1 - Double(index) / Double(length)),
                // Days that have not happened yet get no measured line, only
                // the ideal one — otherwise the chart would show the sprint
                // flat-lining into the future as though it had stalled.
                isProjected: day > today
            ))

            day = endOfDay
            index += 1
        }

        return result
    }
}

/// One day of a sprint burndown.
public struct BurndownPoint: Sendable, Equatable, Identifiable {
    public let day: Date
    public let remaining: Double
    public let ideal: Double
    /// True for days still in the future, which have an ideal but no actual.
    public let isProjected: Bool

    public var id: Date { day }

    public init(day: Date, remaining: Double, ideal: Double, isProjected: Bool) {
        self.day = day
        self.remaining = remaining
        self.ideal = ideal
        self.isProjected = isProjected
    }
}
