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

    public var label: String {
        switch self {
        case .lowest: "Lowest"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .highest: "Highest"
        }
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

    /// A project's own field, written into the same list as `cf:<id>`.
    ///
    /// One stored string rather than two settings, because the three-row cap
    /// has to be shared: two lists each capped at three would let a board show
    /// six rows between them.
    static let customPrefix = "cf:"

    /// Parses the stored `due,labels,cf:1234` form, dropping anything a newer
    /// build wrote that this one does not know.
    public static func list(from stored: String) -> [CardField] {
        parts(of: stored).compactMap(CardField.init(rawValue:))
    }

    /// The ids of the project's own fields named in the same list.
    public static func customIDs(from stored: String) -> [String] {
        parts(of: stored)
            .filter { $0.hasPrefix(customPrefix) }
            .map { String($0.dropFirst(customPrefix.count)) }
            .filter { !$0.isEmpty }
    }

    /// How many rows a stored list adds up to, counting both kinds.
    public static func count(in stored: String) -> Int {
        list(from: stored).count + customIDs(from: stored).count
    }

    public static func stored(_ fields: [CardField], custom customIDs: [String] = []) -> String {
        let all = fields.map(\.rawValue) + customIDs.map { customPrefix + $0 }
        return all.prefix(maximumPerBoard).joined(separator: ",")
    }

    private static func parts(of stored: String) -> [String] {
        stored.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// How one card relates to another.
///
/// Each kind has an inverse, and only one direction is ever stored: the link
/// is written as it was made, and the other card derives what it means from
/// the other end. Storing both would be two rows that can disagree.
public enum LinkKind: Int, Sendable, CaseIterable, Codable {
    case blocks = 0
    case blockedBy = 1
    case relatesTo = 2
    case duplicates = 3
    case duplicatedBy = 4

    public var inverse: LinkKind {
        switch self {
        case .blocks: .blockedBy
        case .blockedBy: .blocks
        case .relatesTo: .relatesTo
        case .duplicates: .duplicatedBy
        case .duplicatedBy: .duplicates
        }
    }

    public var label: String {
        switch self {
        case .blocks: "Blocks"
        case .blockedBy: "Blocked by"
        case .relatesTo: "Relates to"
        case .duplicates: "Duplicates"
        case .duplicatedBy: "Duplicated by"
        }
    }

    /// The kinds worth offering when making a link. The two inverse-only
    /// spellings are what the *other* card sees, not something you pick.
    public static var offered: [LinkKind] { [.blocks, .blockedBy, .relatesTo, .duplicates] }

    public var symbol: String {
        switch self {
        case .blocks: "hand.raised.fill"
        case .blockedBy: "hand.raised"
        case .relatesTo: "link"
        case .duplicates, .duplicatedBy: "doc.on.doc"
        }
    }
}

/// What kind of value a custom field holds.
///
/// The kind decides which column of `custom_field_value` is used, which is why
/// it is fixed at creation: changing a field from text to number afterwards
/// would leave every existing value in the wrong column.
public enum CustomFieldKind: Int, Sendable, CaseIterable, Codable {
    case text = 0
    case number = 1
    case date = 2
    /// One of a fixed list the project defines.
    case choice = 3
    case checkbox = 4
    /// A number with a currency attached to the field, not to each value.
    case money = 5
    /// One to five stars.
    case rating = 6
    /// Nought to a hundred, typed in or counted off the subtasks.
    case progress = 7
    /// Links to other cards.
    case relationship = 8
    /// Worked out from the other fields, never stored.
    case formula = 9
    /// Gathered from the cards this one is related to, never stored.
    case rollup = 10

    public var label: String {
        switch self {
        case .text: "Text"
        case .number: "Number"
        case .date: "Date"
        case .choice: "Choice"
        case .checkbox: "Checkbox"
        case .money: "Money"
        case .rating: "Rating"
        case .progress: "Progress"
        case .relationship: "Relationship"
        case .formula: "Formula"
        case .rollup: "Rollup"
        }
    }

    public var symbol: String {
        switch self {
        case .text: "textformat"
        case .number: "number"
        case .date: "calendar"
        case .choice: "list.bullet"
        case .checkbox: "checkmark.square"
        case .money: "dollarsign.circle"
        case .rating: "star"
        case .progress: "chart.bar.fill"
        case .relationship: "link"
        case .formula: "function"
        case .rollup: "sum"
        }
    }

    /// Which column of `custom_field_value` holds it.
    ///
    /// Several kinds share a column — money, rating and progress are all
    /// numbers — because the column is about how the value is stored and
    /// compared, while the kind is about how it is shown and edited. Sorting
    /// a money column has to put 9 before 10, and that is the column's job.
    public var storage: CustomFieldStorage {
        switch self {
        case .text, .choice, .relationship: .text
        case .number, .money, .rating, .progress: .number
        case .date: .date
        case .checkbox: .boolean
        case .formula, .rollup: .computed
        }
    }

    /// Whether a person types this in at all. A formula and a rollup are read
    /// from elsewhere every time they are shown, so there is nothing to edit
    /// and nothing to save.
    public var isComputed: Bool { storage == .computed }
}

/// Where a field's values live, or that they do not.
public enum CustomFieldStorage: Sendable, Equatable {
    case text
    case number
    case date
    case boolean
    /// Worked out on read. Nothing is written to `custom_field_value`.
    case computed
}

/// Where a rollup gathers its rows from.
public enum RollupSource: Int, Sendable, CaseIterable, Codable {
    /// The card's own subtasks.
    case subtasks = 0
    /// The cards named by one of this card's relationship fields.
    case relationship = 1

    public var label: String {
        switch self {
        case .subtasks: "Subtasks"
        case .relationship: "Related cards"
        }
    }
}

/// How a rollup reduces the values it gathered to one.
public enum RollupFunction: Int, Sendable, CaseIterable, Codable {
    case sum = 0
    case average = 1
    case count = 2
    case minimum = 3
    case maximum = 4

    public var label: String {
        switch self {
        case .sum: "Sum"
        case .average: "Average"
        case .count: "Count"
        case .minimum: "Minimum"
        case .maximum: "Maximum"
        }
    }

    /// Reduce the gathered rows.
    ///
    /// `values` is one entry per related card, with `nil` where that card has
    /// no value for the field. The distinction matters: `count` counts the
    /// cards, including the ones that left the field blank, while `average`
    /// divides by the ones that actually answered — averaging in a blank as
    /// zero would drag the figure down with data nobody entered.
    ///
    /// With no related cards at all the answer is `nil` rather than zero, so a
    /// card with nothing rolled up reads as blank. `count` is the exception:
    /// none is a perfectly good count of none.
    public func reduce(_ values: [Double?]) -> Double? {
        if self == .count { return Double(values.count) }
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        switch self {
        case .sum: return present.reduce(0, +)
        case .average: return present.reduce(0, +) / Double(present.count)
        case .minimum: return present.min()
        case .maximum: return present.max()
        case .count: return Double(values.count)
        }
    }
}

/// Where a progress field's percentage comes from.
public enum ProgressMode: Int, Sendable, CaseIterable, Codable {
    case manual = 0
    case subtasks = 1
    case checklist = 2

    public var label: String {
        switch self {
        case .manual: "Typed in"
        case .subtasks: "From subtasks"
        case .checklist: "From the checklist"
        }
    }

    /// The percentage, given how many of the things are done.
    ///
    /// Nothing to count is `nil`, not 100%: a card with no subtasks has not
    /// finished its subtasks, it has none.
    public static func percentage(done: Int, of total: Int) -> Double? {
        guard total > 0 else { return nil }
        return (Double(done) / Double(total)) * 100
    }
}

/// Where a sprint is in its life.
public enum SprintState: Int, Sendable, CaseIterable, Codable {
    case planned = 0
    case active = 1
    case complete = 2

    public var label: String {
        switch self {
        case .planned: "Planned"
        case .active: "Active"
        case .complete: "Complete"
        }
    }
}

/// What sets an automation off.
public enum AutomationTrigger: Int, Sendable, CaseIterable, Codable {
    /// A card arrives in a particular column.
    case statusChanged = 0
    /// The last of a card's subtasks is ticked off.
    case allSubtasksDone = 1
    /// A card is created.
    case created = 2

    public var label: String {
        switch self {
        case .statusChanged: "When a card reaches"
        case .allSubtasksDone: "When every subtask is done"
        case .created: "When a card is created"
        }
    }
}

/// What an automation does about it.
public enum AutomationAction: Int, Sendable, CaseIterable, Codable {
    case moveToStatus = 0
    case setAssignee = 1
    case setPriority = 2
    case addLabel = 3
    case setFlag = 4
    case clearFlag = 5

    public var label: String {
        switch self {
        case .moveToStatus: "Move it to"
        case .setAssignee: "Assign it to"
        case .setPriority: "Set its priority to"
        case .addLabel: "Add the label"
        case .setFlag: "Flag it"
        case .clearFlag: "Remove its flag"
        }
    }

    /// Whether the action needs something naming alongside it.
    public var needsValue: Bool { self != .clearFlag }
}

/// What a template makes.
public enum TemplateKind: Int, Sendable, CaseIterable, Codable {
    case card = 0
    case project = 1
}

/// How much room the board gives each card.
public enum Density: Int, Sendable, CaseIterable, Codable {
    case comfortable = 0
    case compact = 1

    public var label: String {
        switch self {
        case .comfortable: "Comfortable"
        case .compact: "Compact"
        }
    }

    /// Padding inside a card, and the gap between them.
    public var cardPadding: Double { self == .compact ? 6 : 10 }
    public var cardSpacing: Double { self == .compact ? 5 : 8 }
    public var showsSecondaryRows: Bool { self == .comfortable }
}

/// Which set of colours the app draws in.
///
/// `system` is the default and means "whatever the Mac is doing", including
/// following it when the user changes it mid-session. The other two are a
/// deliberate override: someone who wants a dark board on a light Mac is
/// asking for one board to disagree with the rest, and that is allowed.
public enum Appearance: Int, Sendable, CaseIterable, Codable {
    case system = 0
    case light = 1
    case dark = 2

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}
