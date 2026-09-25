import Foundation

/// Which language a stored query is written in.
///
/// This exists because "extend the grammar towards JQL" and "every filter
/// anybody has already saved keeps working" cannot both be true of one
/// grammar. Six JQL-shaped strings already compile in the original language —
/// as full-text searches, because an unrecognised word is a search term there.
/// `ORDER BY due` means "find cards mentioning order, by and due". Giving
/// those words their JQL meanings would change what that saved filter returns.
///
/// So a stored query carries the language it was written in, every column
/// defaults to `simple`, and nothing is ever re-parsed under new rules. The
/// promise then holds by construction rather than by care.
public enum QuerySyntax: String, Sendable, CaseIterable, Codable {
    /// The original language. Frozen: `ORDER BY`, `IN`, `~`, `WAS` and
    /// `CHANGED` are ordinary words to search for.
    case simple
    /// The JQL-shaped language, where those words are operators.
    case jql

    public var label: String {
        switch self {
        case .simple: "Basic"
        case .jql: "Advanced"
        }
    }

    /// What an archive written before this column existed reads as.
    public static let `default`: QuerySyntax = .simple

    public static func named(_ raw: String?) -> QuerySyntax {
        guard let raw, let parsed = QuerySyntax(rawValue: raw.lowercased()) else { return .default }
        return parsed
    }
}

/// What a query names on the left of an operator.
public enum QueryTarget: Sendable, Equatable {
    case field(QueryField)
    /// A field the project invented.
    case custom(String)

    public var described: String {
        switch self {
        case .field(let field): field.rawValue
        case .custom(let name): "cf:\(name)"
        }
    }
}

/// A function a JQL query can call in place of a value.
///
/// Deliberately a closed set. Each resolves against the clock, the settings or
/// the database at compile time — none of them can reach anything else, and
/// there is no syntax for calling something that is not on this list.
public enum QueryFunction: Sendable, Equatable {
    /// Whoever is chosen in Settings. Matches nothing when nobody is, because
    /// an unanswered question has no answers.
    case currentUser
    case now
    /// Offsets are in the unit named: `startOfWeek(-1)` is last week.
    case startOfDay(Int), endOfDay(Int)
    case startOfWeek(Int), endOfWeek(Int)
    case startOfMonth(Int), endOfMonth(Int)
    case openSprints, closedSprints
    case releasedVersions, unreleasedVersions
    /// Cards linked to the one with this key.
    case linkedIssues(String)

    /// Whether it stands for a date, a set of things, or a person.
    public var isDate: Bool {
        switch self {
        case .now, .startOfDay, .endOfDay, .startOfWeek, .endOfWeek, .startOfMonth, .endOfMonth:
            true
        default:
            false
        }
    }

    public var described: String {
        switch self {
        case .currentUser: "currentUser()"
        case .now: "now()"
        case .startOfDay(let n): "startOfDay(\(n))"
        case .endOfDay(let n): "endOfDay(\(n))"
        case .startOfWeek(let n): "startOfWeek(\(n))"
        case .endOfWeek(let n): "endOfWeek(\(n))"
        case .startOfMonth(let n): "startOfMonth(\(n))"
        case .endOfMonth(let n): "endOfMonth(\(n))"
        case .openSprints: "openSprints()"
        case .closedSprints: "closedSprints()"
        case .releasedVersions: "releasedVersions()"
        case .unreleasedVersions: "unreleasedVersions()"
        case .linkedIssues(let key): "linkedIssues(\(key))"
        }
    }
}

/// A question about a card's past rather than its present.
///
/// Only `status` can be asked, and only because `status_change` has recorded
/// every move since schema 3 and was backfilled to each card's creation. No
/// other field has ever been recorded, so no other field can be asked about —
/// and a query that asked would be answered with silence, which is worse than
/// being told.
public struct HistoryClause: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Was in this state at some point.
        case was
        /// Moved, optionally from something and optionally to something.
        case changed
    }

    public var target: QueryTarget
    public var kind: Kind
    /// For `WAS`.
    public var value: QueryValue?
    public var from: QueryValue?
    public var to: QueryValue?
    /// `DURING (start, end)`. Both ends, or neither.
    public var duringStart: RelativeDate?
    public var duringEnd: RelativeDate?
    public var negated: Bool

    public init(
        target: QueryTarget,
        kind: Kind,
        value: QueryValue? = nil,
        from: QueryValue? = nil,
        to: QueryValue? = nil,
        duringStart: RelativeDate? = nil,
        duringEnd: RelativeDate? = nil,
        negated: Bool = false
    ) {
        self.target = target
        self.kind = kind
        self.value = value
        self.from = from
        self.to = to
        self.duringStart = duringStart
        self.duringEnd = duringEnd
        self.negated = negated
    }
}

/// One clause of `ORDER BY`.
public struct QueryOrder: Sendable, Equatable {
    public var field: QueryField
    public var ascending: Bool

    public init(field: QueryField, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }
}

/// A query, once read: what to match, and how to order what matched.
///
/// The simple language has no ordering, so `order` is always empty for it and
/// callers fall back to the ordering they have always used.
public struct ParsedQuery: Sendable, Equatable {
    public var filter: TaskFilter
    public var order: [QueryOrder]

    public init(filter: TaskFilter, order: [QueryOrder] = []) {
        self.filter = filter
        self.order = order
    }
}
