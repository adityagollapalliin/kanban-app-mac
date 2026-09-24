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
