import Foundation

/// A folder inside a space. Optional, and it owns nothing: a folder is a way
/// of tidying a sidebar, not a level anything has to consult to find a card.
public struct Folder: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    public var color: String
    public var icon: String
    public var archived: Bool
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String, projectID: String, name: String,
        color: String = "", icon: String = "", archived: Bool = false,
        sortOrder: Double, createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.color = color
        self.icon = icon
        self.archived = archived
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// A list of cards.
///
/// Named `TaskList` rather than `List` because `List` is SwiftUI's, and every
/// view file in the app would have to spell out which one it meant.
public struct TaskList: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    /// `nil` for a list sitting straight in the space. Both are ordinary
    /// places for a list to be; neither is a fallback for the other.
    public var folderID: String?
    public var name: String
    public var color: String
    public var icon: String
    public var archived: Bool
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String, projectID: String, folderID: String? = nil, name: String,
        color: String = "", icon: String = "", archived: Bool = false,
        sortOrder: Double, createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.folderID = folderID
        self.name = name
        self.color = color
        self.icon = icon
        self.archived = archived
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// Someone on a card, and how much of the work is theirs.
public struct TaskAssignee: Sendable, Equatable, Codable {
    public var taskID: String
    public var personID: String
    /// This person's share of the estimate. `nil` means they have one but
    /// nobody has said how much — which the workload view counts as an equal
    /// share rather than as zero.
    public var estimate: Double?
    public var sortOrder: Double

    public init(taskID: String, personID: String, estimate: Double? = nil, sortOrder: Double) {
        self.taskID = taskID
        self.personID = personID
        self.estimate = estimate
        self.sortOrder = sortOrder
    }
}

/// What a person can take on, and over what.
public enum CapacityUnit: Int, Sendable, CaseIterable, Codable {
    case hours = 0
    case points = 1

    public var label: String { self == .hours ? "Hours" : "Points" }
    public var short: String { self == .hours ? "h" : "pts" }
}

public enum CapacityPeriod: Int, Sendable, CaseIterable, Codable {
    case day = 0
    case week = 1

    public var label: String { self == .day ? "A day" : "A week" }
}

/// A card's recurrence as it is stored: the rule, plus when it last produced
/// one. Kept apart from `RecurrenceRule` so the rule stays pure arithmetic
/// with no identity and nothing to persist.
public struct Recurrence: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var taskID: String
    public var rule: RecurrenceRule
    public var lastSpawnedAt: Date?
    public var createdAt: Date

    public init(
        id: String, taskID: String, rule: RecurrenceRule,
        lastSpawnedAt: Date? = nil, createdAt: Date
    ) {
        self.id = id
        self.taskID = taskID
        self.rule = rule
        self.lastSpawnedAt = lastSpawnedAt
        self.createdAt = createdAt
    }
}

// MARK: - What each view remembers

/// The kind of thing a view's settings belong to.
public enum ViewScopeKind: Int, Sendable, CaseIterable, Codable {
    case space = 0
    case folder = 1
    case list = 2
    /// Everything, everywhere — the one scope with no id.
    case everything = 3
}

public enum ViewKind: Int, Sendable, CaseIterable, Codable {
    case table = 0
    case workload = 1
    case box = 2
    case activity = 3
    case mindMap = 4
    case everything = 5

    public var label: String {
        switch self {
        case .table: "Table"
        case .workload: "Workload"
        case .box: "Box"
        case .activity: "Activity"
        case .mindMap: "Mind Map"
        case .everything: "Everything"
        }
    }

    public var symbol: String {
        switch self {
        case .table: "tablecells"
        case .workload: "gauge.with.dots.needle.67percent"
        case .box: "square.grid.2x2"
        case .activity: "clock.arrow.circlepath"
        case .mindMap: "point.3.connected.trianglepath.dotted"
        case .everything: "globe"
        }
    }
}

/// One view's sort, grouping, filter and visible columns.
///
/// Per view *and* per place: the table you set up on one list should not
/// rearrange the table on another, because they are showing different work
/// and the columns that matter differ with it.
public struct ViewConfig: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var scopeKind: ViewScopeKind
    public var scopeID: String
    public var viewKind: ViewKind
    public var groupBy: String
    public var sortField: String
    public var sortAscending: Bool
    public var filterQuery: String
    /// Column identifiers, in the order shown. Stored as a comma-separated
    /// list: a column somebody can read in `sqlite3` beats a packed blob.
    public var columns: [String]
    public var updatedAt: Date

    public init(
        id: String,
        scopeKind: ViewScopeKind,
        scopeID: String,
        viewKind: ViewKind,
        groupBy: String = "",
        sortField: String = "",
        sortAscending: Bool = true,
        filterQuery: String = "",
        columns: [String] = [],
        updatedAt: Date
    ) {
        self.id = id
        self.scopeKind = scopeKind
        self.scopeID = scopeID
        self.viewKind = viewKind
        self.groupBy = groupBy
        self.sortField = sortField
        self.sortAscending = sortAscending
        self.filterQuery = filterQuery
        self.columns = columns
        self.updatedAt = updatedAt
    }

    public var columnList: String { columns.joined(separator: ",") }

    public static func columns(from list: String) -> [String] {
        list.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
}

// MARK: - Shortcuts

/// Favourites, pinned views and what you were just looking at.
///
/// One idea — a shortcut to something — differing only in whether the user put
/// it there and whether it expires. Three tables would be three sets of the
/// same bug.
public enum ShortcutKind: Int, Sendable, CaseIterable, Codable {
    case favorite = 0
    case pinnedView = 1
    case recent = 2

    public var label: String {
        switch self {
        case .favorite: "Favourites"
        case .pinnedView: "Pinned Views"
        case .recent: "Recent"
        }
    }

    public var symbol: String {
        switch self {
        case .favorite: "star"
        case .pinnedView: "pin"
        case .recent: "clock"
        }
    }
}

public enum ShortcutTarget: Int, Sendable, CaseIterable, Codable {
    case space = 0
    case folder = 1
    case list = 2
    case board = 3
    case savedView = 4
    case task = 5

    public var symbol: String {
        switch self {
        case .space: "square.stack.3d.up"
        case .folder: "folder"
        case .list: "list.bullet"
        case .board: "rectangle.split.3x1"
        case .savedView: "line.3.horizontal.decrease.circle"
        case .task: "square.text.square"
        }
    }
}

public struct Shortcut: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var kind: ShortcutKind
    public var target: ShortcutTarget
    public var targetID: String
    /// What to call it, copied at the time. A shortcut to something that has
    /// since been deleted can then still say what it pointed at, instead of
    /// showing an id or vanishing without explanation.
    public var label: String
    public var sortOrder: Double
    public var at: Date

    public init(
        id: String, kind: ShortcutKind, target: ShortcutTarget, targetID: String,
        label: String = "", sortOrder: Double, at: Date
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.targetID = targetID
        self.label = label
        self.sortOrder = sortOrder
        self.at = at
    }
}

/// How long something sits in the trash before the app removes it.
///
/// Thirty days from when it was thrown away. The purge is arithmetic on a
/// stored date rather than a scheduled job: there is nothing to miss a run,
/// and a Mac that was asleep for a month catches up the moment it opens.
public enum TrashPolicy {
    public static let keepFor: TimeInterval = 30 * 24 * 60 * 60

    public static func isExpired(_ trashedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(trashedAt) >= keepFor
    }

    /// Days left, for the line that warns before it happens.
    ///
    /// Rounded up, not down: a card thrown away a moment ago has thirty days
    /// left, and a part-day still counts as a day you can change your mind in.
    /// Truncating would say 29 the instant it was trashed, and 0 for the
    /// whole of the last day it can still be recovered.
    public static func daysLeft(_ trashedAt: Date, now: Date) -> Int {
        let remaining = keepFor - now.timeIntervalSince(trashedAt)
        guard remaining > 0 else { return 0 }
        return Int((remaining / 86_400).rounded(.up))
    }
}
