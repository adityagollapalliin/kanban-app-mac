import Foundation

/// The fixed vocabularies stored as INTEGER in schema v1.
///
/// They are integers rather than strings so that `priority >= .high` is an
/// ordinary indexed comparison rather than a string match, and so the ordering
/// is the domain's, not the alphabet's. The raw values are part of the on-disk
/// format: append to them, never renumber.

/// Where a status sits in the flow. Several statuses share a category — a
/// project may have "In Review" and "In Progress" both in `.inProgress`.
public enum StatusCategory: Int, Sendable, CaseIterable, Codable {
    case toDo = 0
    case inProgress = 1
    case done = 2

    /// Completing a task is what stamps `completed_at`, and this is the test.
    public var isComplete: Bool { self == .done }
}

public enum TaskType: Int, Sendable, CaseIterable, Codable {
    case epic = 0
    case story = 1
    case task = 2
    case bug = 3

    /// Epics collect other work; the schema's `epic_id` only ever points here.
    public var canContainOtherWork: Bool { self == .epic }
}

public enum Priority: Int, Sendable, CaseIterable, Codable, Comparable {
    case lowest = 0
    case low = 1
    case normal = 2
    case high = 3
    case highest = 4

    public static func < (lhs: Priority, rhs: Priority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What a column's work-in-progress limit counts.
///
/// Counting cards treats a one-line fix and a month of work as the same
/// weight. Counting estimates is what a team using story points actually
/// means by "no more than twenty in flight".
public enum WIPMeasure: Int, Sendable, CaseIterable, Codable {
    case cardCount = 0
    case estimate = 1

    public var label: String {
        switch self {
        case .cardCount: "Cards"
        case .estimate: "Points"
        }
    }
}

/// How a column's limit is doing. Reported, never enforced — the board says
/// what is true and lets the drop happen anyway.
public enum WIPState: Sendable, Equatable {
    /// Inside the limits, or no limits set.
    case fine
    /// Below a minimum: the column is starved, which is a real signal on a
    /// pull-based board and the reason `wip_minimum` exists at all.
    case belowMinimum
    /// One away from the maximum.
    case approaching
    /// Over the maximum.
    case breached
}

/// How the board is cut into horizontal lanes.
public enum SwimlaneMode: Int, Sendable, CaseIterable, Codable {
    case none = 0
    case epic = 1
    case assignee = 2
    case parent = 3
    case priority = 4
    /// Lanes defined by saved queries, first match wins.
    case query = 5

    public var label: String {
        switch self {
        case .none: "No Swimlanes"
        case .epic: "Epic"
        case .assignee: "Assignee"
        case .parent: "Parent Task"
        case .priority: "Priority"
        case .query: "Queries"
        }
    }
}

/// What decides a card's colour stripe.
public enum CardColorRule: Int, Sendable, CaseIterable, Codable {
    case none = 0
    case priority = 1
    case type = 2
    case assignee = 3
    /// Cards matching a chosen saved view are coloured; the rest are not.
    case query = 4

    public var label: String {
        switch self {
        case .none: "No Colour"
        case .priority: "Priority"
        case .type: "Type"
        case .assignee: "Assignee"
        case .query: "Saved View"
        }
    }
}

/// The extra rows a board chooses to show on its cards.
///
/// Stored as a comma-separated list of these raw values rather than as
/// columns, because which three a board wants is a preference, not a schema.
public enum CardField: String, Sendable, CaseIterable, Codable {
    case dueDate = "due"
    case labels
    case points
    case assignee
    case epic
    case checklist
    case daysInColumn = "days"
    case version

    public var label: String {
        switch self {
        case .dueDate: "Due Date"
        case .labels: "Labels"
        case .points: "Points"
        case .assignee: "Assignee"
        case .epic: "Epic"
        case .checklist: "Checklist"
        case .daysInColumn: "Days in Column"
        case .version: "Version"
        }
    }

    /// A board shows at most this many, so a card stays something you can read
    /// at a glance rather than a form.
    public static let maximumPerBoard = 3

    /// Parses the stored `due,labels` form, dropping anything a newer build
    /// wrote that this one does not know.
    public static func list(from stored: String) -> [CardField] {
        stored.split(separator: ",")
            .compactMap { CardField(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
    }

    public static func stored(_ fields: [CardField]) -> String {
        fields.prefix(maximumPerBoard).map(\.rawValue).joined(separator: ",")
    }
}
