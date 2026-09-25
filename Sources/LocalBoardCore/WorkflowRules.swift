import Foundation

/// When a rule on a transition is consulted.
///
/// The three moments are genuinely different questions, and conflating them is
/// how workflow engines become impossible to reason about:
///
/// * a **condition** decides whether the move is offered at all. It is about
///   the card, so a move that fails one simply is not there;
/// * a **validator** decides whether it may complete. It is about what is
///   missing, so a move that fails one is offered, attempted, and refused with
///   a reason;
/// * a **post-function** happens afterwards and cannot refuse anything.
public enum TransitionRulePhase: Int, Sendable, CaseIterable, Codable {
    case condition = 0
    case validator = 1
    case postFunction = 2

    public var label: String {
        switch self {
        case .condition: "Only offer when"
        case .validator: "Don't allow until"
        case .postFunction: "Afterwards"
        }
    }

    public var symbol: String {
        switch self {
        case .condition: "eye"
        case .validator: "checkmark.shield"
        case .postFunction: "wand.and.stars"
        }
    }
}

/// What a rule actually checks or does.
///
/// One enumeration across all three phases, with `phase` deciding which values
/// are meaningful. A separate enumeration per phase would need a separate
/// column, a separate table and three code paths to load one transition.
public enum TransitionRuleKind: Int, Sendable, CaseIterable, Codable {

    // MARK: Conditions

    /// Every subtask is finished.
    case allSubtasksDone = 0
    /// The card matches a query.
    case matchesQuery = 1
    /// The card is assigned to whoever this copy of the app belongs to.
    case assignedToMe = 2

    // MARK: Validators

    /// A named field is not empty. `target` is the field reference.
    case fieldRequired = 10
    /// The card has a resolution.
    case resolutionRequired = 11
    /// Some time has been logged against it.
    case timeLoggedRequired = 12
    /// At least one comment.
    case commentRequired = 13

    // MARK: Post-functions

    /// Set a field. `target` is the field reference, `value` what to set.
    case setField = 20
    /// Assign it to somebody. `target` is the person's id; empty unassigns.
    case assign = 21
    /// Take the flag off, which a card moving on has usually earned.
    case clearFlag = 22
    /// Leave a comment saying what happened.
    case addComment = 23
    /// Give it a resolution. `target` is the resolution's id.
    case setResolution = 24

    public var phase: TransitionRulePhase {
        switch rawValue {
        case 0..<10: .condition
        case 10..<20: .validator
        default: .postFunction
        }
    }

    public var label: String {
        switch self {
        case .allSubtasksDone: "every subtask is done"
        case .matchesQuery: "the card matches a query"
        case .assignedToMe: "the card is assigned to me"
        case .fieldRequired: "a field is filled in"
        case .resolutionRequired: "a resolution is chosen"
        case .timeLoggedRequired: "some time has been logged"
        case .commentRequired: "there is at least one comment"
        case .setField: "Set a field"
        case .assign: "Assign it to somebody"
        case .clearFlag: "Clear the flag"
        case .addComment: "Add a comment"
        case .setResolution: "Set the resolution"
        }
    }

    /// Whether the rule needs a field, a person or a resolution named.
    public var needsTarget: Bool {
        switch self {
        case .fieldRequired, .setField, .assign, .setResolution: true
        default: false
        }
    }

    public var needsValue: Bool {
        switch self {
        case .setField, .addComment: true
        default: false
        }
    }

    public var needsQuery: Bool { self == .matchesQuery }

    public static func kinds(in phase: TransitionRulePhase) -> [TransitionRuleKind] {
        allCases.filter { $0.phase == phase }
    }
}

/// One rule on one transition.
public struct TransitionRule: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var transitionID: String
    public var kind: TransitionRuleKind
    /// A field reference, a person's id, a resolution's id — per kind.
    public var target: String
    public var value: String
    public var query: String
    public var syntax: QuerySyntax
    public var sortOrder: Double
    public var createdAt: Date

    public var phase: TransitionRulePhase { kind.phase }

    public init(
        id: String,
        transitionID: String,
        kind: TransitionRuleKind,
        target: String = "",
        value: String = "",
        query: String = "",
        syntax: QuerySyntax = .simple,
        sortOrder: Double,
        createdAt: Date
    ) {
        self.id = id
        self.transitionID = transitionID
        self.kind = kind
        self.target = target
        self.value = value
        self.query = query
        self.syntax = syntax
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// A field, named the same way wherever one is referred to.
///
/// Built-in fields are their query-language name; a field the project invented
/// is `cf:` and its id — the id rather than the name, because a field can be
/// renamed and a rule that stopped applying because somebody fixed a typo
/// would be a bad surprise.
public enum FieldReference: Sendable, Equatable, Hashable {
    case builtIn(String)
    case custom(String)

    public var stored: String {
        switch self {
        case .builtIn(let name): name
        case .custom(let id): "cf:\(id)"
        }
    }

    public init(stored: String) {
        if stored.hasPrefix("cf:") {
            self = .custom(String(stored.dropFirst(3)))
        } else {
            self = .builtIn(stored)
        }
    }

    /// The built-in fields a transition screen or a field configuration can
    /// name. Deliberately the ones somebody might be *required* to fill in.
    public static let builtInNames = [
        "assignee", "due", "start", "priority", "estimate",
        "description", "resolution", "environment", "version", "sprint", "epic",
    ]

    public var label: String {
        switch self {
        case .builtIn(let name): name.prefix(1).uppercased() + name.dropFirst()
        case .custom: "Field"
        }
    }
}

/// Which fields a kind of card shows, insists on, and starts with.
///
/// A row is a *departure* from the default. No rows means every field shows
/// and none is required, which is how the app behaved before this existed.
public struct FieldConfiguration: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    /// The `issue_type.code` this applies to.
    public var issueTypeCode: Int
    public var field: FieldReference
    public var shown: Bool
    public var required: Bool
    /// What a new card of this kind starts with. Read the same way a query
    /// value is, so `+7d` in a date field means a week out.
    public var defaultValue: String
    public var sortOrder: Double

    public init(
        id: String,
        projectID: String,
        issueTypeCode: Int,
        field: FieldReference,
        shown: Bool = true,
        required: Bool = false,
        defaultValue: String = "",
        sortOrder: Double
    ) {
        self.id = id
        self.projectID = projectID
        self.issueTypeCode = issueTypeCode
        self.field = field
        self.shown = shown
        self.required = required
        self.defaultValue = defaultValue
        self.sortOrder = sortOrder
    }
}

extension FieldReference: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(stored: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueEncoder()
        try container.encode(stored)
    }
}

extension Encoder {
    fileprivate func singleValueEncoder() -> SingleValueEncodingContainer {
        singleValueContainer()
    }
}

/// Why a move was refused.
///
/// Carried rather than thrown as a string so the UI can show the failing
/// validators together — "this needs a resolution and an estimate" in one
/// message rather than one at a time as each is satisfied.
public struct TransitionRefusal: Error, Sendable, Equatable {
    public var transitionName: String
    public var reasons: [String]

    public init(transitionName: String, reasons: [String]) {
        self.transitionName = transitionName
        self.reasons = reasons
    }

    public var message: String {
        guard !reasons.isEmpty else { return "That move is not allowed." }
        if reasons.count == 1 { return "This card needs \(reasons[0]) first." }
        let head = reasons.dropLast().joined(separator: ", ")
        return "This card needs \(head) and \(reasons[reasons.count - 1]) first."
    }
}
