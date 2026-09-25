import Foundation
import LocalBoardCore

/// What one widget has to say.
///
/// A single enumeration rather than a protocol with a case per widget: the
/// view has to switch on the kind to draw it anyway, and this way a widget
/// that fails to read does so as `.unavailable` with a reason on it instead of
/// as an empty box the user has to guess about.
public enum WidgetData: Sendable, Equatable {
    case count(Int, of: Int)
    case breakdown([WidgetSlice])
    case tasks([BoardTask], total: Int)
    case workload([WidgetSlice], unit: String)
    case time(total: Int, billable: Int, byDay: [WidgetTimePoint])
    case goal(Goal)
    case note(String)
    case flow([FlowPoint])
    case burndown([BurndownPoint])
    case unavailable(String)
}

/// One bar, slice or row of a breakdown.
public struct WidgetSlice: Sendable, Equatable, Identifiable {
    public let id: String
    public var label: String
    public var value: Double
    /// The colour the thing already has on the board — a status's colour, a
    /// priority's. Empty where it has none.
    public var colorName: String

    public init(id: String, label: String, value: Double, colorName: String = "") {
        self.id = id
        self.label = label
        self.value = value
        self.colorName = colorName
    }
}

public struct WidgetTimePoint: Sendable, Equatable, Identifiable {
    public let day: Date
    public var minutes: Int

    public var id: Date { day }

    public init(day: Date, minutes: Int) {
        self.day = day
        self.minutes = minutes
    }
}

/// Fills the widgets in.
///
/// Every widget is a saved query plus a way of drawing what it matches, so
/// most of the work here is handing the query to the compiler the search bar
/// already uses and counting what comes back.
public struct DashboardDataRepository {

    let database: Database
    private let clock: any ClockProvider
    private let calendar: Calendar

    public init(database: Database, clock: any ClockProvider = SystemClock(), calendar: Calendar = .current) {
        self.database = database
        self.clock = clock
        self.calendar = calendar
    }

    public func data(for widget: DashboardWidget, inProject projectID: String) throws -> WidgetData {
        // A widget's query is the user's own text. A mistake in it is the
        // widget's problem to report, not the dashboard's to crash on, so
        // every failure here becomes something the box can say out loud.
        do {
            return try compute(widget, projectID)
        } catch let error as LocalBoardError {
            return .unavailable(error.failureReason ?? error.localizedDescription)
        } catch let error as QueryError {
            return .unavailable(error.message)
        }
    }

    private func compute(_ widget: DashboardWidget, _ projectID: String) throws -> WidgetData {
        switch widget.kind {
        case .note:
            return .note(widget.config.text)

        case .goalProgress:
            guard let goalID = widget.config.goalID else {
                return .unavailable("No goal chosen yet.")
            }
            let goals = GoalRepository(database: database, clock: clock)
            try? goals.refresh(goalID)
            return .goal(try goals.goal(id: goalID))

        case .taskCount:
            let matching = try tasks(widget.query, projectID)
            let total = try database.count(
                "SELECT COUNT(*) FROM task WHERE project_id = ? AND trashed = 0;", [projectID]
            )
            return .count(matching.count, of: total)

        case .taskList:
            let matching = try tasks(widget.query, projectID)
            // Capped, because a widget is a box on a grid: a thousand rows in
            // it would be a thousand rows nobody can see and a scroll view
            // inside a scroll view that cannot be lazy.
            return .tasks(Array(matching.prefix(max(1, widget.config.limit))), total: matching.count)

        case .statusBreakdown:
            let matching = try tasks(widget.query, projectID)
            var names: [String: (name: String, category: StatusCategory, order: Double)] = [:]
            try database.forEachRow(
                "SELECT id, name, category, sort_order FROM status WHERE project_id = ?;", [projectID]
            ) { row in
                names[try row.requiredString("id")] = (
                    row.string("name") ?? "",
                    // A status carries no colour of its own, so the bar takes
                    // its cue from the category — which is the distinction the
                    // chart is actually about.
                    row.enumValue("category", StatusCategory.self) ?? .toDo,
                    row.double("sort_order") ?? 0
                )
            }
            var counts: [String: Int] = [:]
            for task in matching { counts[task.statusID, default: 0] += 1 }
            // Every column, including the empty ones: a board with nothing in
            // Review is telling you something, and leaving the bar out hides it.
            return .breakdown(
                names.sorted { $0.value.order < $1.value.order }.map { id, status in
                    WidgetSlice(
                        id: id,
                        label: status.name,
                        value: Double(counts[id] ?? 0),
                        colorName: Self.colorName(for: status.category)
                    )
                }
            )

        case .priorityBreakdown:
            let matching = try tasks(widget.query, projectID)
            var counts: [Priority: Int] = [:]
            for task in matching { counts[task.priority, default: 0] += 1 }
            return .breakdown(
                Priority.allCases.reversed().map { priority in
                    WidgetSlice(
                        id: String(priority.rawValue),
                        label: priority.label,
                        value: Double(counts[priority] ?? 0)
                    )
                }
            )

        case .assigneeBreakdown:
            let matching = try tasks(widget.query, projectID)
            var names: [String: String] = [:]
            try database.forEachRow("SELECT id, name FROM person;", []) { row in
                names[try row.requiredString("id")] = row.string("name") ?? ""
            }
            var counts: [String: Int] = [:]
            for task in matching { counts[task.assigneeID ?? "", default: 0] += 1 }
            let slices = counts.map { id, count in
                WidgetSlice(
                    id: id.isEmpty ? "unassigned" : id,
                    label: id.isEmpty ? "Unassigned" : (names[id] ?? "Someone who has left"),
                    value: Double(count)
                )
            }
            return .breakdown(slices.sorted { $0.value > $1.value })

        case .workload:
            let days = max(1, widget.config.days)
            let loads = try WorkloadRepository(database: database, calendar: calendar)
                .loads(inProject: projectID, from: clock.now, days: days)
            return .workload(
                loads.map {
                    WidgetSlice(id: $0.person.id, label: $0.person.name, value: $0.total)
                },
                unit: loads.first?.person.capacityUnit == .points ? "points" : "hours"
            )

        case .timeTracked:
            let days = max(1, widget.config.days)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: clock.now)) ?? clock.now
            let start = calendar.date(byAdding: .day, value: -days, to: end) ?? end
            let time = TimeRepository(database: database, clock: clock, calendar: calendar)
            return .time(
                total: try time.totalMinutes(inProject: projectID, from: start, to: end),
                billable: try time.totalMinutes(inProject: projectID, from: start, to: end, billableOnly: true),
                byDay: try time.minutesByDay(inProject: projectID, from: start, to: end)
                    .map { WidgetTimePoint(day: $0.day, minutes: $0.minutes) }
            )

        case .cumulativeFlow:
            return .flow(
                try AnalyticsRepository(database: database, clock: clock, calendar: calendar)
                    .cumulativeFlow(inProject: projectID, days: max(2, widget.config.days))
            )

        case .burndown:
            let sprints = SprintRepository(database: database, clock: clock)
            guard let active = try sprints.sprints(inProject: projectID).first(where: { $0.state == .active }) else {
                return .unavailable("No sprint is running.")
            }
            return .burndown(
                try AnalyticsRepository(database: database, clock: clock, calendar: calendar)
                    .burndown(sprint: active)
            )
        }
    }

    /// The colour a category's bar takes.
    static func colorName(for category: StatusCategory) -> String {
        switch category {
        case .toDo: "secondary"
        case .inProgress: "blue"
        case .done: "green"
        }
    }

    /// The cards a widget's query matches. An empty query is the whole space,
    /// which is what a widget with no filter on it should be about.
    private func tasks(_ query: String, _ projectID: String) throws -> [BoardTask] {
        let repository = TaskRepository(database: database, clock: clock)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // "Everything" is spelled as a query rather than as a special
            // case, so one code path answers every widget.
            return try repository.tasks(matching: "not is:trashed", inProject: projectID)
        }
        return try repository.tasks(matching: trimmed, inProject: projectID)
    }
}
