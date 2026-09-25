import Foundation

/// The four vocabularies a project decides for itself.
///
/// Each of these was a fixed enumeration until schema 9. The enumerations are
/// still there and still define what the integers in the database mean — what
/// changed is that a project can now add to them, rename them and give them
/// icons, without anything else in the app having to know.
///
/// The `code` on each of these types is that integer. It is what `task.type`,
/// `task.priority` and `task_link.kind` hold, which is why none of those
/// columns had to be rewritten.

/// A kind of card: epic, story, task, bug, or whatever a project adds.
public struct IssueType: Sendable, Equatable, Identifiable, Codable {
    public var projectID: String
    /// What `task.type` holds. Fixed once allocated.
    public let code: Int
    public var name: String
    public var symbol: String
    public var color: String
    /// Where it sits in the hierarchy. 0 is ordinary work, 1 is an epic, and
    /// anything above is what a project puts over the top — an initiative, a
    /// theme.
    ///
    /// Being a *subtask* is not a level: that is a fact about a card's parent,
    /// and a card can be made a subtask without changing what kind of thing
    /// it is.
    public var level: Int
    /// Text a new card of this kind starts with. Empty means start blank.
    public var descriptionTemplate: String
    public var sortOrder: Double

    public var id: String { "\(projectID)|\(code)" }

    public init(
        projectID: String,
        code: Int,
        name: String,
        symbol: String = "",
        color: String = "",
        level: Int = 0,
        descriptionTemplate: String = "",
        sortOrder: Double
    ) {
        self.projectID = projectID
        self.code = code
        self.name = name
        self.symbol = symbol
        self.color = color
        self.level = level
        self.descriptionTemplate = descriptionTemplate
        self.sortOrder = sortOrder
    }

    /// The built-in kind this code was, for anything still switching on the
    /// enumeration. Nil for a kind the project invented.
    public var builtIn: TaskType? { TaskType(rawValue: code) }
}

/// One step of a project's priority scale.
public struct PriorityValue: Sendable, Equatable, Identifiable, Codable {
    public var projectID: String
    /// What `task.priority` holds.
    public let code: Int
    public var name: String
    /// What an ordering comparison means. Seeded equal to `code`, so
    /// `priority >= high` compiles to the integer comparison it always has.
    ///
    /// The two can diverge once a project inserts a step in the middle, and
    /// the query compiler has to read this rather than the code before that is
    /// allowed to happen.
    public var rank: Int
    public var symbol: String
    public var color: String
    public var sortOrder: Double

    public var id: String { "\(projectID)|\(code)" }

    public init(
        projectID: String,
        code: Int,
        name: String,
        rank: Int,
        symbol: String = "",
        color: String = "",
        sortOrder: Double
    ) {
        self.projectID = projectID
        self.code = code
        self.name = name
        self.rank = rank
        self.symbol = symbol
        self.color = color
        self.sortOrder = sortOrder
    }

    public var builtIn: Priority? { Priority(rawValue: code) }

    /// Whether the scale still reads the way the query compiler assumes.
    ///
    /// Every seeded scale does. A project that inserts a step in the middle
    /// breaks the assumption, which is why adding one is refused until the
    /// compiler reads ranks — see IMPACT-8.5.md.
    public static func ranksMatchCodes(_ values: [PriorityValue]) -> Bool {
        values.allSatisfy { $0.rank == $0.code }
    }
}

/// A kind of link, stored as the pair it is.
///
/// "Blocks" and "is blocked by" are one relationship read from two ends, not
/// two relationships — which is why they were never separately configurable
/// and are not now.
public struct LinkType: Sendable, Equatable, Identifiable, Codable {
    public var projectID: String
    /// What `task_link.kind` holds, for the outward reading.
    public let code: Int
    /// How it reads from the card that made the link.
    public var outward: String
    /// How it reads from the card on the other end.
    public var inward: String
    public var symbol: String
    public var sortOrder: Double

    public var id: String { "\(projectID)|\(code)" }

    public init(
        projectID: String,
        code: Int,
        outward: String,
        inward: String,
        symbol: String = "",
        sortOrder: Double
    ) {
        self.projectID = projectID
        self.code = code
        self.outward = outward
        self.inward = inward
        self.symbol = symbol
        self.sortOrder = sortOrder
    }

    /// How this link reads from one end or the other.
    public func label(outward: Bool) -> String {
        outward ? self.outward : inward
    }

    /// Whether the two ends read the same, as "relates to" does. A symmetric
    /// link has no inverse to show on the other card.
    public var isSymmetric: Bool {
        outward.caseInsensitiveCompare(inward) == .orderedSame
    }
}

/// Why a card was closed.
///
/// "Done" alone cannot say it: a card closed as a duplicate and one that was
/// finished are both out of the last column and mean entirely different
/// things. Reports that count finished work need to be able to tell them
/// apart.
public struct Resolution: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    /// The one applied when a card reaches a Done column without anybody
    /// choosing. Exactly one per project.
    public var isDefault: Bool
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String,
        projectID: String,
        name: String,
        isDefault: Bool = false,
        sortOrder: Double,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.isDefault = isDefault
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// A part of the thing being built, and who looks after it.
public struct Component: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    public var description: String
    /// Work filed against this component lands on this person without
    /// anybody choosing. Nil leaves it unassigned.
    public var defaultAssigneeID: String?
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String,
        projectID: String,
        name: String,
        description: String = "",
        defaultAssigneeID: String? = nil,
        sortOrder: Double,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.description = description
        self.defaultAssigneeID = defaultAssigneeID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// Which way a version relates to a card.
public enum VersionRole: Int, Sendable, CaseIterable, Codable {
    /// The release this card is going out in.
    case fix = 0
    /// A release this bug was found in.
    case affects = 1

    public var label: String {
        switch self {
        case .fix: "Fix Version"
        case .affects: "Affects Version"
        }
    }
}
