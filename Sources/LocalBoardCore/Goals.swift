import Foundation

/// Where a goal's current figure comes from.
public enum GoalKind: Int, Sendable, CaseIterable, Codable {
    /// A number you keep yourself.
    case number = 0
    /// The same, shown as money.
    case currency = 1
    /// Done or not done.
    case boolean = 2
    /// Counted from the cards that match the goal's query.
    case tasksCompleted = 3

    public var label: String {
        switch self {
        case .number: "Number"
        case .currency: "Money"
        case .boolean: "Done or not"
        case .tasksCompleted: "Tasks completed"
        }
    }

    public var symbol: String {
        switch self {
        case .number: "number"
        case .currency: "dollarsign.circle"
        case .boolean: "checkmark.circle"
        case .tasksCompleted: "checklist"
        }
    }

    /// Whether the app works the figure out, rather than the person typing it.
    public var isAutomatic: Bool { self == .tasksCompleted }
}

/// A folder of goals. It holds goals and nothing else.
public struct GoalFolder: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    public var sortOrder: Double
    public var createdAt: Date

    public init(id: String, projectID: String, name: String, sortOrder: Double, createdAt: Date) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// Something you are trying to reach, by a date.
public struct Goal: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var folderID: String?
    public var name: String
    public var notes: String
    public var kind: GoalKind
    /// Where the count started. A goal to cut open bugs from 40 to 10 is at no
    /// progress when it stands at 40 — not at four hundred per cent.
    public var start: Double
    public var target: Double
    /// The figure as last recorded. For a `tasksCompleted` goal this is
    /// refreshed from the cards, so the stored number is a cache of the count
    /// rather than something anyone typed.
    public var current: Double
    public var currency: String
    /// The query whose matching cards are counted, for `tasksCompleted`.
    public var query: String
    public var listID: String?
    public var ownerID: String?
    public var dueAt: Date?
    public var completedAt: Date?
    public var archived: Bool
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        projectID: String,
        folderID: String? = nil,
        name: String,
        notes: String = "",
        kind: GoalKind = .number,
        start: Double = 0,
        target: Double = 1,
        current: Double = 0,
        currency: String = "USD",
        query: String = "",
        listID: String? = nil,
        ownerID: String? = nil,
        dueAt: Date? = nil,
        completedAt: Date? = nil,
        archived: Bool = false,
        sortOrder: Double,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.folderID = folderID
        self.name = name
        self.notes = notes
        self.kind = kind
        self.start = start
        self.target = target
        self.current = current
        self.currency = currency
        self.query = query
        self.listID = listID
        self.ownerID = ownerID
        self.dueAt = dueAt
        self.completedAt = completedAt
        self.archived = archived
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// How far along, from 0 to 1.
    ///
    /// Measured from `start` rather than from zero, and clamped at both ends:
    /// a bar that runs past its own end tells you less than one that is full,
    /// and a figure that has gone backwards past the start is at no progress
    /// rather than at a negative amount of it.
    ///
    /// A target that equals the start is a goal with no distance to cover, so
    /// it is met the moment the figure reaches it.
    public var fraction: Double {
        let span = target - start
        guard span != 0 else {
            return current >= target ? 1 : 0
        }
        return min(max((current - start) / span, 0), 1)
    }

    /// Whether the figure is meant to come down rather than go up.
    public var descending: Bool { target < start }

    public var isMet: Bool {
        // Either direction: a goal to get a number *down* is met when the
        // figure is at or below the target.
        target >= start ? current >= target : current <= target
    }

    /// How it reads beside the bar.
    public var progressDescription: String {
        switch kind {
        case .boolean:
            return isMet ? "Done" : "Not yet"
        case .currency:
            return descending
                ? "\(currency) \(Self.plain(current)), down to \(currency) \(Self.plain(target))"
                : "\(currency) \(Self.plain(current)) of \(currency) \(Self.plain(target))"
        case .number, .tasksCompleted:
            // "22 of 10" reads as a count that has overshot. A goal to bring a
            // number *down* is going the other way, and has to say so.
            return descending
                ? "\(Self.plain(current)), down to \(Self.plain(target))"
                : "\(Self.plain(current)) of \(Self.plain(target))"
        }
    }

    public var percentDescription: String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Days until it is due, counted on whole days. Negative once it is late.
    public func daysRemaining(from now: Date, calendar: Calendar = .current) -> Int? {
        guard let dueAt else { return nil }
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: dueAt)
        return calendar.dateComponents([.day], from: from, to: to).day
    }

    public func isOverdue(now: Date, calendar: Calendar = .current) -> Bool {
        guard completedAt == nil, !isMet, let days = daysRemaining(from: now, calendar: calendar) else { return false }
        return days < 0
    }

    /// A figure without trailing noughts: `4`, not `4.00`.
    public static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

// MARK: - Dashboards

/// What a widget draws.
public enum DashboardWidgetKind: Int, Sendable, CaseIterable, Codable {
    case taskCount = 0
    case statusBreakdown = 1
    case priorityBreakdown = 2
    case assigneeBreakdown = 3
    case taskList = 4
    case workload = 5
    case timeTracked = 6
    case goalProgress = 7
    case note = 8
    case cumulativeFlow = 9
    case burndown = 10

    public var label: String {
        switch self {
        case .taskCount: "Number"
        case .statusBreakdown: "By status"
        case .priorityBreakdown: "By priority"
        case .assigneeBreakdown: "By assignee"
        case .taskList: "Task list"
        case .workload: "Workload"
        case .timeTracked: "Time tracked"
        case .goalProgress: "Goal"
        case .note: "Note"
        case .cumulativeFlow: "Cumulative flow"
        case .burndown: "Burndown"
        }
    }

    public var symbol: String {
        switch self {
        case .taskCount: "number.square"
        case .statusBreakdown: "chart.bar"
        case .priorityBreakdown: "chart.pie"
        case .assigneeBreakdown: "person.2"
        case .taskList: "list.bullet.rectangle"
        case .workload: "gauge.with.dots.needle.33percent"
        case .timeTracked: "clock"
        case .goalProgress: "target"
        case .note: "note.text"
        case .cumulativeFlow: "chart.line.uptrend.xyaxis"
        case .burndown: "chart.line.downtrend.xyaxis"
        }
    }

    /// Whether the widget reads the cards its query matches. A note and a goal
    /// do not, so they are not offered a query to edit.
    public var usesQuery: Bool {
        switch self {
        case .note, .goalProgress, .workload: false
        default: true
        }
    }

    /// How big it wants to be when it is first dropped on the grid, in cells.
    public var defaultSize: (width: Int, height: Int) {
        switch self {
        case .taskCount: (1, 1)
        case .note, .goalProgress: (1, 1)
        case .statusBreakdown, .priorityBreakdown, .assigneeBreakdown, .timeTracked: (2, 1)
        case .taskList, .workload: (2, 2)
        case .cumulativeFlow, .burndown: (3, 2)
        }
    }
}

/// A widget's own settings.
///
/// One struct rather than a column per setting, because they are per-kind and
/// a table with a column for each would be mostly nulls. It is stored as JSON
/// in `dashboard_widget.config`, and every property has a default so a widget
/// written by an older build still reads.
public struct DashboardWidgetConfig: Sendable, Equatable, Codable {
    /// For `goalProgress`.
    public var goalID: String?
    /// For `note`.
    public var text: String
    /// How far back a chart looks.
    public var days: Int
    /// Show the figures as a chart rather than a list, where both make sense.
    public var showsChart: Bool
    /// For `taskList`: how many rows before it stops drawing.
    public var limit: Int

    public init(goalID: String? = nil, text: String = "", days: Int = 30, showsChart: Bool = true, limit: Int = 10) {
        self.goalID = goalID
        self.text = text
        self.days = days
        self.showsChart = showsChart
        self.limit = limit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goalID = try container.decodeIfPresent(String.self, forKey: .goalID)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        days = try container.decodeIfPresent(Int.self, forKey: .days) ?? 30
        showsChart = try container.decodeIfPresent(Bool.self, forKey: .showsChart) ?? true
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 10
    }

    /// The stored form. A config that will not encode is stored as nothing,
    /// which reads back as the defaults — never as a crash.
    public var stored: String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    public static func decoded(from stored: String) -> DashboardWidgetConfig {
        guard let data = stored.data(using: .utf8),
              let config = try? JSONDecoder().decode(DashboardWidgetConfig.self, from: data) else {
            return DashboardWidgetConfig()
        }
        return config
    }
}

public struct Dashboard: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, projectID: String, name: String, sortOrder: Double, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DashboardWidget: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var dashboardID: String
    public var kind: DashboardWidgetKind
    public var title: String
    /// The saved query that decides which cards the widget is about. Empty
    /// means every card in the space.
    public var query: String
    public var column: Int
    public var row: Int
    /// How many cells across it takes.
    public var width: Int
    /// How tall the box wants to be, in units of a row's base height.
    ///
    /// A height rather than a row span: a widget cannot straddle two rows,
    /// because neither of SwiftUI's grids can draw a cell that does, and a
    /// stored layout the app cannot render is a layout that comes back wrong.
    /// Two rows' worth of height is a taller box on its own row instead.
    public var height: Int
    public var config: DashboardWidgetConfig
    public var createdAt: Date

    public init(
        id: String,
        dashboardID: String,
        kind: DashboardWidgetKind,
        title: String = "",
        query: String = "",
        column: Int = 0,
        row: Int = 0,
        width: Int = 1,
        height: Int = 1,
        config: DashboardWidgetConfig = DashboardWidgetConfig(),
        createdAt: Date
    ) {
        self.id = id
        self.dashboardID = dashboardID
        self.kind = kind
        self.title = title
        self.query = query
        self.column = column
        self.row = row
        self.width = width
        self.height = height
        self.config = config
        self.createdAt = createdAt
    }

    public var displayTitle: String {
        title.isEmpty ? kind.label : title
    }
}

/// Where the widgets sit.
///
/// The grid flows rather than letting widgets be dropped at arbitrary
/// coordinates. A free grid has to answer what happens when the window is
/// narrower than the layout — and every answer is either a horizontal scroll
/// bar or widgets that overlap. Flowing means the order is what is stored and
/// the positions are worked out for whatever width there is, so the same
/// dashboard is legible on any display.
///
/// Dragging therefore moves a widget in the order, and `pack` says where that
/// puts everything.
public enum DashboardLayout {
    /// Lay widgets out in reading order, in a grid `columns` wide.
    ///
    /// A widget wider than the grid is narrowed to fit rather than dropped:
    /// three columns of a four-column dashboard, reopened on a narrow window,
    /// is still the widget the person made.
    public static func pack(_ widgets: [DashboardWidget], columns: Int) -> [DashboardWidget] {
        let columns = max(1, columns)
        // `filled[row]` is the set of columns already taken on that row.
        // Height plays no part: a widget occupies cells on one row only, and
        // is simply drawn taller. See `DashboardWidget.height`.
        var filled: [Int: Set<Int>] = [:]
        var packed: [DashboardWidget] = []
        packed.reserveCapacity(widgets.count)

        for var widget in widgets {
            let width = min(max(1, widget.width), columns)

            var row = 0
            var column = 0
            search: while true {
                let taken = filled[row] ?? []
                for candidate in 0...(columns - width)
                where (candidate..<(candidate + width)).allSatisfy({ !taken.contains($0) }) {
                    column = candidate
                    break search
                }
                row += 1
            }

            filled[row, default: []].formUnion(column..<(column + width))

            widget.column = column
            widget.row = row
            widget.width = width
            widget.height = max(1, widget.height)
            packed.append(widget)
        }

        return packed
    }

    /// The packed widgets grouped into the rows they are drawn as.
    public static func rows(_ widgets: [DashboardWidget], columns: Int) -> [[DashboardWidget]] {
        let packed = pack(widgets, columns: columns)
        var byRow: [Int: [DashboardWidget]] = [:]
        for widget in packed { byRow[widget.row, default: []].append(widget) }
        return byRow.keys.sorted().map { byRow[$0]?.sorted { $0.column < $1.column } ?? [] }
    }

    /// The order after dragging the widget at `source` onto `destination`.
    ///
    /// `destination` is an insertion point in the *original* list, which is
    /// what SwiftUI's `onMove` hands over, so dragging something downwards has
    /// to account for the gap it leaves behind.
    public static func reorder(_ widgets: [DashboardWidget], from source: Int, to destination: Int) -> [DashboardWidget] {
        guard widgets.indices.contains(source), destination >= 0, destination <= widgets.count else { return widgets }
        var moved = widgets
        let widget = moved.remove(at: source)
        let target = destination > source ? destination - 1 : destination
        moved.insert(widget, at: min(max(target, 0), moved.count))
        return moved
    }

    /// How many rows the packed layout needs.
    public static func rowCount(_ widgets: [DashboardWidget]) -> Int {
        (widgets.map(\.row).max() ?? -1) + 1
    }
}
