import Foundation

/// The domain types behind schema v1.
///
/// Each mirrors one table. They are plain `Sendable` values with no database
/// awareness: the store maps rows to these, the UI renders them, and neither
/// end can reach through one to the other. Identifiers are `String` UUIDs, as
/// the schema stores them, so a record keeps its identity across export and
/// import and across the app/CLI boundary.

public struct Workspace: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var name: String
    public var sortOrder: Double
    public var createdAt: Date

    public init(id: String, name: String, sortOrder: Double, createdAt: Date) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

public struct Project: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var workspaceID: String
    public var name: String
    /// Short prefix shown on every task: WORK-14.
    public var key: String
    public var descriptionMarkdown: String
    /// The next value `number` will take. Allocated inside the insert's
    /// transaction so two concurrent adds cannot collide.
    public var nextTaskNumber: Int
    public var archived: Bool
    /// Whether the project's allowed transitions are applied. Off by default,
    /// and with no transitions defined a project allows everything — so
    /// turning this on is the only thing that can ever refuse a move.
    public var enforcesWorkflow: Bool
    /// A palette colour name and an SF Symbol, both empty until chosen. A
    /// sidebar of a dozen spaces is unreadable as a dozen lines of text.
    public var color: String
    public var icon: String
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String,
        workspaceID: String,
        name: String,
        key: String,
        descriptionMarkdown: String = "",
        nextTaskNumber: Int = 1,
        archived: Bool = false,
        enforcesWorkflow: Bool = false,
        color: String = "",
        icon: String = "",
        sortOrder: Double,
        createdAt: Date
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.key = key
        self.descriptionMarkdown = descriptionMarkdown
        self.nextTaskNumber = nextTaskNumber
        self.archived = archived
        self.enforcesWorkflow = enforcesWorkflow
        self.color = color
        self.icon = icon
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
    /// Reads a project from an archive, including one written before some of
    /// these properties existed.
    ///
    /// Hand-written for the same reason `BoardTask`'s is: a synthesised
    /// decoder demands every key, so adding one non-optional property makes
    /// every file anybody exported unreadable. `enforcesWorkflow`, `color` and
    /// `icon` all arrived after the export format did.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        name = try container.decode(String.self, forKey: .name)
        key = try container.decode(String.self, forKey: .key)
        descriptionMarkdown = try container.decodeIfPresent(String.self, forKey: .descriptionMarkdown) ?? ""
        nextTaskNumber = try container.decodeIfPresent(Int.self, forKey: .nextTaskNumber) ?? 1
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        enforcesWorkflow = try container.decodeIfPresent(Bool.self, forKey: .enforcesWorkflow) ?? false
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? ""
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? ""
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 1_000
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }

}

public struct Status: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    public var category: StatusCategory
    public var sortOrder: Double

    public init(id: String, projectID: String, name: String, category: StatusCategory, sortOrder: Double) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.category = category
        self.sortOrder = sortOrder
    }
}

public struct Board: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    public var sortOrder: Double
    public var createdAt: Date

    /// How the board is cut into lanes.
    public var swimlaneMode: SwimlaneMode
    /// The extra rows shown on every card, at most three between them.
    public var cardFields: [CardField]
    /// The project's own fields, shown on the card alongside the built-in
    /// rows and counted against the same limit.
    public var customCardFieldIDs: [String]
    public var colorRule: CardColorRule
    /// Which saved view colours the cards, when `colorRule` is `.query`.
    public var colorViewID: String?
    /// How long a card may sit in one column before the board says so.
    public var staleDays: Int
    public var backlogEnabled: Bool
    /// A board defined by a question instead of by its project. Empty for the
    /// ordinary kind; anything else and the board gathers whatever matches,
    /// wherever it lives.
    public var filterQuery: String

    /// How many rows the cards are showing, counting both kinds.
    public var cardRowCount: Int { cardFields.count + customCardFieldIDs.count }

    /// Whether this board's cards come from a query rather than one project.
    public var isQueryBoard: Bool {
        !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        id: String,
        projectID: String,
        name: String,
        sortOrder: Double,
        createdAt: Date,
        swimlaneMode: SwimlaneMode = .none,
        cardFields: [CardField] = [.dueDate, .labels],
        customCardFieldIDs: [String] = [],
        colorRule: CardColorRule = .none,
        colorViewID: String? = nil,
        staleDays: Int = 3,
        backlogEnabled: Bool = false,
        filterQuery: String = ""
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.swimlaneMode = swimlaneMode
        self.cardFields = cardFields
        self.customCardFieldIDs = customCardFieldIDs
        self.colorRule = colorRule
        self.colorViewID = colorViewID
        self.staleDays = staleDays
        self.backlogEnabled = backlogEnabled
        self.filterQuery = filterQuery
    }
}

/// A column is a board's view of one status, which is why it carries both ids:
/// two boards over the same project can show the same status in different
/// positions, with different WIP limits, under different names.
public struct BoardColumn: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var boardID: String
    public var statusID: String
    public var name: String
    /// `nil` means no limit. Exceeding it is surfaced, never enforced — the
    /// board reports what is true rather than refusing the drop.
    public var wipLimit: Int?
    /// A floor as well as a ceiling. An empty column on a pull-based board is
    /// as much a signal as a full one, and only a minimum can say so.
    public var wipMinimum: Int?
    /// Whether the limits count cards or add up estimates.
    public var wipMeasure: WIPMeasure
    /// A backlog column sits off the board proper: its cards are shown on the
    /// backlog screen and do not count against anything.
    public var isBacklog: Bool
    public var sortOrder: Double

    public init(
        id: String,
        boardID: String,
        statusID: String,
        name: String,
        wipLimit: Int? = nil,
        wipMinimum: Int? = nil,
        wipMeasure: WIPMeasure = .cardCount,
        isBacklog: Bool = false,
        sortOrder: Double
    ) {
        self.id = id
        self.boardID = boardID
        self.statusID = statusID
        self.name = name
        self.wipLimit = wipLimit
        self.wipMinimum = wipMinimum
        self.wipMeasure = wipMeasure
        self.isBacklog = isBacklog
        self.sortOrder = sortOrder
    }

    /// Where a measured amount sits against the limits.
    ///
    /// `approaching` is the last slot before the ceiling, so a column of four
    /// with a limit of five warns while there is still something to be done
    /// about it rather than only once it is too late.
    public func state(for amount: Double) -> WIPState {
        if let minimum = wipMinimum, amount < Double(minimum) { return .belowMinimum }
        guard let limit = wipLimit else { return .fine }
        if amount > Double(limit) { return .breached }
        if amount >= Double(limit) { return .approaching }
        return .fine
    }
}

public struct Person: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var name: String
    public var color: String
    /// How much this person can take on. Zero means nobody has said, which
    /// the workload view draws as a bar with no ceiling rather than as a
    /// person who can do nothing.
    public var capacityAmount: Double
    public var capacityUnit: CapacityUnit
    public var capacityPeriod: CapacityPeriod
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String,
        name: String,
        color: String = "graphite",
        capacityAmount: Double = 0,
        capacityUnit: CapacityUnit = .hours,
        capacityPeriod: CapacityPeriod = .week,
        sortOrder: Double,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.capacityAmount = capacityAmount
        self.capacityUnit = capacityUnit
        self.capacityPeriod = capacityPeriod
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    /// What this person can take in a week, whichever way it was entered —
    /// the workload view compares weeks, so a daily figure is multiplied by
    /// five rather than by seven: capacity is working days.
    public var weeklyCapacity: Double {
        capacityPeriod == .week ? capacityAmount : capacityAmount * 5
    }

    public var hasCapacity: Bool { capacityAmount > 0 }
}

public struct CardLabel: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    public var color: String

    public init(id: String, projectID: String, name: String, color: String = "slate") {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.color = color
    }
}

public struct ChecklistItem: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var taskID: String
    public var text: String
    public var done: Bool
    public var sortOrder: Double

    public init(id: String, taskID: String, text: String, done: Bool = false, sortOrder: Double) {
        self.id = id
        self.taskID = taskID
        self.text = text
        self.done = done
        self.sortOrder = sortOrder
    }
}

/// A row of the `task` table.
///
/// Named `BoardTask` rather than `Task` on purpose: a type called `Task` in
/// this module would shadow `_Concurrency.Task` in every file that imports it,
/// and the UI layer needs `Task { }` for its async work.
public struct BoardTask: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var statusID: String
    /// Per-project counter behind the WORK-14 label. Unique with `projectID`.
    public var number: Int
    /// The card's kind as one of the four the app has always known.
    ///
    /// Since schema 9 a project can define its own kinds, and one of those has
    /// a code outside this enumeration. `typeCode` is the truth; this is the
    /// nearest built-in reading of it, and falls back to `.task` for a kind
    /// the project invented — so anything switching on it keeps working and
    /// treats an unfamiliar kind as ordinary work rather than refusing to
    /// load the card.
    ///
    /// Anything *showing* the kind to somebody should look up the project's
    /// `IssueType` by `typeCode` instead, or it will call an Initiative a Task.
    public var type: TaskType
    /// What `task.type` actually holds.
    public var typeCode: Int
    /// Why it was closed, once it is. Cleared when it is reopened.
    public var resolutionID: String?
    public var resolvedAt: Date?
    /// Where the problem shows up: "Safari 18 on an M1, staging only". Free
    /// text on purpose — nobody can enumerate this in advance.
    public var environment: String
    public var title: String
    public var descriptionMarkdown: String
    public var assigneeID: String?
    public var priority: Priority
    /// Subtask parent. Deleting a parent cascades to its children.
    public var parentID: String?
    /// The epic this rolls up to. Deleting the epic only clears the link.
    public var epicID: String?
    public var startDate: Date?
    public var dueDate: Date?
    public var estimate: Double?
    public var sortOrder: Double
    /// Trashed tasks stay on disk and stay out of every board query.
    public var trashed: Bool
    /// Blocked, impeded, waiting on someone. Distinct from priority: a flag is
    /// about what is in the way, not about what matters most.
    public var flagged: Bool
    public var flagReason: String
    /// When the card last entered the column it is in. The card's own copy of
    /// what `status_change` records, so days-in-column costs no join.
    public var statusChangedAt: Date?
    public var versionID: String?
    public var sprintID: String?
    /// The list this card lives in. One home, however many other lists it is
    /// also shown in.
    public var listID: String?
    /// A date that matters rather than work with a length: drawn as a diamond
    /// on the timeline, because giving it a bar would claim a duration it
    /// does not have.
    public var isMilestone: Bool
    /// When it was thrown away, which is not when it was last edited — the
    /// trashing itself moves `updatedAt`, so that column cannot answer this.
    public var trashedAt: Date?
    /// Stop asking about this until then. Not the same as a due date: the
    /// date is a promise to other people, a snooze is five minutes' peace.
    public var snoozedUntil: Date?
    /// The day somebody decided to do this. Also not a due date — a card due
    /// next week that you are starting today belongs in today's list without
    /// its deadline moving.
    public var plannedFor: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    /// Whole days the card has sat where it is.
    public func daysInColumn(now: Date, calendar: Calendar = .current) -> Int {
        guard let since = statusChangedAt else { return 0 }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: since),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        return max(0, days)
    }

    public init(
        id: String,
        projectID: String,
        statusID: String,
        number: Int,
        type: TaskType = .task,
        typeCode: Int? = nil,
        resolutionID: String? = nil,
        resolvedAt: Date? = nil,
        environment: String = "",
        title: String,
        descriptionMarkdown: String = "",
        assigneeID: String? = nil,
        priority: Priority = .normal,
        parentID: String? = nil,
        epicID: String? = nil,
        startDate: Date? = nil,
        dueDate: Date? = nil,
        estimate: Double? = nil,
        sortOrder: Double,
        trashed: Bool = false,
        flagged: Bool = false,
        flagReason: String = "",
        statusChangedAt: Date? = nil,
        versionID: String? = nil,
        sprintID: String? = nil,
        listID: String? = nil,
        isMilestone: Bool = false,
        trashedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        plannedFor: Date? = nil,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.statusID = statusID
        self.number = number
        self.type = type
        self.typeCode = typeCode ?? type.rawValue
        self.resolutionID = resolutionID
        self.resolvedAt = resolvedAt
        self.environment = environment
        self.title = title
        self.descriptionMarkdown = descriptionMarkdown
        self.assigneeID = assigneeID
        self.priority = priority
        self.parentID = parentID
        self.epicID = epicID
        self.startDate = startDate
        self.dueDate = dueDate
        self.estimate = estimate
        self.sortOrder = sortOrder
        self.trashed = trashed
        self.flagged = flagged
        self.flagReason = flagReason
        self.statusChangedAt = statusChangedAt
        self.versionID = versionID
        self.sprintID = sprintID
        self.listID = listID
        self.isMilestone = isMilestone
        self.trashedAt = trashedAt
        self.snoozedUntil = snoozedUntil
        self.plannedFor = plannedFor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    /// Reads a card from an archive, including one written before some of
    /// these properties existed.
    ///
    /// Written by hand rather than synthesised, because a synthesised decoder
    /// demands every key: adding one non-optional property would make every
    /// file anybody had already exported unreadable, with no error anybody
    /// could act on. Every property added from here on gets a default here in
    /// the same commit.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        projectID = try container.decode(String.self, forKey: .projectID)
        statusID = try container.decode(String.self, forKey: .statusID)
        number = try container.decode(Int.self, forKey: .number)
        type = try container.decodeIfPresent(TaskType.self, forKey: .type) ?? .task
        // Schema 9: a project can define its own kinds, whose codes sit
        // outside the enumeration. An older file has only the enumeration.
        typeCode = try container.decodeIfPresent(Int.self, forKey: .typeCode) ?? type.rawValue
        resolutionID = try container.decodeIfPresent(String.self, forKey: .resolutionID)
        resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
        environment = try container.decodeIfPresent(String.self, forKey: .environment) ?? ""
        title = try container.decode(String.self, forKey: .title)
        descriptionMarkdown = try container.decodeIfPresent(String.self, forKey: .descriptionMarkdown) ?? ""
        assigneeID = try container.decodeIfPresent(String.self, forKey: .assigneeID)
        priority = try container.decodeIfPresent(Priority.self, forKey: .priority) ?? .normal
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        epicID = try container.decodeIfPresent(String.self, forKey: .epicID)
        versionID = try container.decodeIfPresent(String.self, forKey: .versionID)
        sprintID = try container.decodeIfPresent(String.self, forKey: .sprintID)
        listID = try container.decodeIfPresent(String.self, forKey: .listID)
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        estimate = try container.decodeIfPresent(Double.self, forKey: .estimate)
        sortOrder = try container.decode(Double.self, forKey: .sortOrder)
        trashed = try container.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
        trashedAt = try container.decodeIfPresent(Date.self, forKey: .trashedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        statusChangedAt = try container.decodeIfPresent(Date.self, forKey: .statusChangedAt)
        flagged = try container.decodeIfPresent(Bool.self, forKey: .flagged) ?? false
        flagReason = try container.decodeIfPresent(String.self, forKey: .flagReason) ?? ""
        isMilestone = try container.decodeIfPresent(Bool.self, forKey: .isMilestone) ?? false
        snoozedUntil = try container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        plannedFor = try container.decodeIfPresent(Date.self, forKey: .plannedFor)
    }
}

/// A query kept by name.
///
/// The query text is what is stored, never a compiled result or a list of
/// matching ids: a view is a question, and the answer is whatever is true when
/// it is next asked.
public struct SavedView: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    public var query: String
    /// Which language `query` is written in. Everything saved before schema 10
    /// is `simple` by the migration's own default, and is never re-read under
    /// any other rules.
    public var syntax: QuerySyntax
    /// Kept to hand in the sidebar.
    public var starred: Bool
    /// Which columns the navigator shows, one per line. Empty means the
    /// default set, so a filter saved before the navigator existed opens
    /// looking exactly as it always did.
    public var columns: [String]
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String,
        projectID: String,
        name: String,
        query: String,
        syntax: QuerySyntax = .simple,
        starred: Bool = false,
        columns: [String] = [],
        sortOrder: Double,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.query = query
        self.syntax = syntax
        self.starred = starred
        self.columns = columns
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    /// The stored form of the column list.
    public static func storedColumns(_ columns: [String]) -> String {
        columns.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public static func columns(from stored: String) -> [String] {
        stored.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
    /// An archive written before the syntax column has filters without one.
    /// They read as `simple`, which is what they were — so an old backup
    /// restored today behaves exactly as it did on the day it was taken.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectID = try container.decode(String.self, forKey: .projectID)
        name = try container.decode(String.self, forKey: .name)
        query = try container.decode(String.self, forKey: .query)
        syntax = try container.decodeIfPresent(QuerySyntax.self, forKey: .syntax) ?? .simple
        starred = try container.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        columns = try container.decodeIfPresent([String].self, forKey: .columns) ?? []
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 1_000
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }

}

/// How far through a card's checklist it is.
public struct ChecklistProgress: Sendable, Equatable, Codable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    public var isComplete: Bool { total > 0 && done == total }
    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

/// A release: a name to ship work under, and a date to ship it on.
public struct Version: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    public var descriptionMarkdown: String
    public var releaseDate: Date?
    /// Released versions stay: a shipped release is a record, not a to-do.
    public var released: Bool
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String,
        projectID: String,
        name: String,
        descriptionMarkdown: String = "",
        releaseDate: Date? = nil,
        released: Bool = false,
        sortOrder: Double,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.descriptionMarkdown = descriptionMarkdown
        self.releaseDate = releaseDate
        self.released = released
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// A horizontal lane defined by a query.
///
/// Pinned lanes are matched before the board's grouping is applied, which is
/// how "Expedite" stays at the top whether the board is grouped by epic, by
/// assignee or not at all.
public struct Swimlane: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var boardID: String
    public var name: String
    public var query: String
    public var pinned: Bool
    public var sortOrder: Double

    public init(
        id: String,
        boardID: String,
        name: String,
        query: String,
        pinned: Bool = false,
        sortOrder: Double
    ) {
        self.id = id
        self.boardID = boardID
        self.name = name
        self.query = query
        self.pinned = pinned
        self.sortOrder = sortOrder
    }
}

/// A toggle above the board, backed by a query. Several on at once mean all of
/// them, so they narrow rather than compete.
public struct QuickFilter: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var boardID: String
    public var name: String
    public var query: String
    public var sortOrder: Double

    public init(id: String, boardID: String, name: String, query: String, sortOrder: Double) {
        self.id = id
        self.boardID = boardID
        self.name = name
        self.query = query
        self.sortOrder = sortOrder
    }
}

/// One entry in a card's journey across the board.
///
/// Append-only. This is the only record of *when* work moved, and every
/// number the analytics screen shows is derived from it — which is why
/// nothing edits or deletes these rows.
public struct StatusChange: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var taskID: String
    /// `nil` for the entry a card is created with.
    public var fromStatusID: String?
    public var toStatusID: String
    public var at: Date

    public init(id: String, taskID: String, fromStatusID: String?, toStatusID: String, at: Date) {
        self.id = id
        self.taskID = taskID
        self.fromStatusID = fromStatusID
        self.toStatusID = toStatusID
        self.at = at
    }
}

/// A project's link to a folder on this Mac.
///
/// The bookmark is the sandbox's record that the user once chose this folder;
/// without it the path is just a string the app is not allowed to open. Read
/// only, local only, and absent unless someone asked for it.
public struct RepositoryLink: Sendable, Equatable, Identifiable, Codable {
    public var projectID: String
    public var path: String
    public var bookmark: Data?
    public var linkedAt: Date

    public var id: String { projectID }

    public init(projectID: String, path: String, bookmark: Data?, linkedAt: Date) {
        self.projectID = projectID
        self.path = path
        self.bookmark = bookmark
        self.linkedAt = linkedAt
    }
}

/// A remark on a card.
public struct Comment: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var taskID: String
    /// `nil` when nobody was chosen, or when the author has since been removed.
    public var authorID: String?
    public var bodyMarkdown: String
    public var createdAt: Date
    /// Set when a comment is changed, so an edited remark says it was edited
    /// rather than quietly appearing always to have said this.
    public var editedAt: Date?
    /// A remark and a request look the same in a thread until somebody has to
    /// act on one. These are what tell them apart — and they are part of the
    /// comment because an action item *is* the comment, not a thing pinned to
    /// it.
    public var isActionItem: Bool
    public var actionAssigneeID: String?
    public var actionDone: Bool
    public var actionDoneAt: Date?

    public init(
        id: String,
        taskID: String,
        authorID: String?,
        bodyMarkdown: String,
        createdAt: Date,
        editedAt: Date? = nil,
        isActionItem: Bool = false,
        actionAssigneeID: String? = nil,
        actionDone: Bool = false,
        actionDoneAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.authorID = authorID
        self.bodyMarkdown = bodyMarkdown
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.isActionItem = isActionItem
        self.actionAssigneeID = actionAssigneeID
        self.actionDone = actionDone
        self.actionDoneAt = actionDoneAt
    }
}

/// A file kept with a card.
///
/// The path is relative to the app's attachments folder, never absolute: the
/// container's real path differs between machines and between the sandboxed
/// app and the command-line tool, and only a relative path survives all three.
public struct Attachment: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var taskID: String
    public var filename: String
    public var relativePath: String
    public var byteSize: Int
    public var addedAt: Date

    public init(
        id: String,
        taskID: String,
        filename: String,
        relativePath: String,
        byteSize: Int,
        addedAt: Date
    ) {
        self.id = id
        self.taskID = taskID
        self.filename = filename
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.addedAt = addedAt
    }
}

/// One card's relationship to another.
public struct TaskLink: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var taskID: String
    public var otherTaskID: String
    public var kind: LinkKind
    public var createdAt: Date

    public init(id: String, taskID: String, otherTaskID: String, kind: LinkKind, createdAt: Date) {
        self.id = id
        self.taskID = taskID
        self.otherTaskID = otherTaskID
        self.kind = kind
        self.createdAt = createdAt
    }
}

/// Time spent on a card.
public struct WorkLogEntry: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var taskID: String
    public var personID: String?
    public var minutes: Int
    public var note: String
    /// The day the work happened, which is often not the day it was written
    /// down — and only the first of those is any use in a report.
    public var workedOn: Date
    /// Whether these minutes go on an invoice. Hours logged before anybody was
    /// asked the question are not billable: guessing yes would put figures on
    /// a timesheet nobody stands behind.
    public var billable: Bool
    public var createdAt: Date

    public init(
        id: String,
        taskID: String,
        personID: String?,
        minutes: Int,
        note: String = "",
        workedOn: Date,
        billable: Bool = false,
        createdAt: Date
    ) {
        self.id = id
        self.taskID = taskID
        self.personID = personID
        self.minutes = minutes
        self.note = note
        self.workedOn = workedOn
        self.billable = billable
        self.createdAt = createdAt
    }

    /// `1h 30m`, and `45m` when there is no hour to speak of.
    public var duration: String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)m" }
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}

/// A field a project defines for itself.
public struct CustomField: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    /// Fixed at creation: the kind decides which column the values live in,
    /// and changing it later would strand every value already written.
    public let kind: CustomFieldKind
    /// The choices, for a `.choice` field. One per line.
    public var options: [String]
    /// For `.money`: which currency the figures are in. It belongs to the
    /// field rather than to each value, because a column of amounts in mixed
    /// currencies cannot be summed.
    public var currency: String
    /// For `.progress`: whether the percentage is typed in or counted.
    public var progressMode: ProgressMode
    /// For `.relationship`: which list the other cards must come from. Nil
    /// means anywhere in the space.
    public var targetListID: String?
    /// For `.formula`: the expression, as it was typed.
    public var formula: String
    /// For `.rollup`: where the rows come from, which relationship field
    /// names them, which of their fields to read, and how to reduce it.
    public var rollupSource: RollupSource
    public var rollupLinkID: String?
    public var rollupFieldID: String?
    public var rollupFunction: RollupFunction
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String,
        projectID: String,
        name: String,
        kind: CustomFieldKind,
        options: [String] = [],
        currency: String = "USD",
        progressMode: ProgressMode = .manual,
        targetListID: String? = nil,
        formula: String = "",
        rollupSource: RollupSource = .subtasks,
        rollupLinkID: String? = nil,
        rollupFieldID: String? = nil,
        rollupFunction: RollupFunction = .sum,
        sortOrder: Double,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.kind = kind
        self.options = options
        self.currency = currency
        self.progressMode = progressMode
        self.targetListID = targetListID
        self.formula = formula
        self.rollupSource = rollupSource
        self.rollupLinkID = rollupLinkID
        self.rollupFieldID = rollupFieldID
        self.rollupFunction = rollupFunction
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    /// The stored form: one choice per line, blanks dropped.
    public static func stored(_ options: [String]) -> String {
        options.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public static func options(from stored: String) -> [String] {
        stored.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

/// One card's answer for one custom field.
///
/// A single case rather than four optional properties, so "this field is not
/// set" and "this field is set to nothing" cannot both be true at once.
public enum CustomFieldValue: Sendable, Equatable, Hashable {
    case text(String)
    case number(Double)
    case date(Date)
    case choice(String)
    case checkbox(Bool)

    /// The kind whose column this value lives in.
    ///
    /// Several field kinds share one of these — money, a rating and a
    /// percentage are all `.number` — so this answers "which column" rather
    /// than "which field kind": see `CustomFieldKind.storage`.
    public var kind: CustomFieldKind {
        switch self {
        case .text: .text
        case .number: .number
        case .date: .date
        case .choice: .choice
        case .checkbox: .checkbox
        }
    }

    /// The column this value belongs in.
    public var storage: CustomFieldStorage { kind.storage }

    /// How it reads on a card, where there is only room for a few words.
    public func display(formatter: DateFormatter? = nil) -> String {
        switch self {
        case .text(let value), .choice(let value):
            return value
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case .date(let value):
            return value.formatted(date: .abbreviated, time: .omitted)
        case .checkbox(let value):
            return value ? "Yes" : "No"
        }
    }

    /// Whether this is worth showing at all. An unticked checkbox and an empty
    /// string are both "nothing to say".
    public var isEmpty: Bool {
        switch self {
        case .text(let value), .choice(let value): value.trimmingCharacters(in: .whitespaces).isEmpty
        case .checkbox(let value): !value
        default: false
        }
    }
}

/// A fixed stretch of work with a start, an end and a commitment.
public struct Sprint: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    public var goal: String
    public var state: SprintState
    public var startsAt: Date?
    public var endsAt: Date?
    public var completedAt: Date?
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String,
        projectID: String,
        name: String,
        goal: String = "",
        state: SprintState = .planned,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        completedAt: Date? = nil,
        sortOrder: Double,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.goal = goal
        self.state = state
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.completedAt = completedAt
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    /// Whole days from start to end, at least one.
    public func length(calendar: Calendar = .current) -> Int {
        guard let startsAt, let endsAt else { return 0 }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: startsAt), to: calendar.startOfDay(for: endsAt)
        ).day ?? 0
        return max(1, days)
    }

    /// Whether the sprint has run past the day it said it would end.
    public func isOverrunning(now: Date) -> Bool {
        guard state == .active, let endsAt else { return false }
        return now > endsAt
    }
}

/// One allowed move between two columns.
public struct WorkflowTransition: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var fromStatusID: String
    public var toStatusID: String

    public init(id: String, projectID: String, fromStatusID: String, toStatusID: String) {
        self.id = id
        self.projectID = projectID
        self.fromStatusID = fromStatusID
        self.toStatusID = toStatusID
    }
}

/// A rule the project applies to itself.
public struct Automation: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String
    public var name: String
    public var trigger: AutomationTrigger
    /// Which column, for `.statusChanged`.
    public var triggerStatusID: String?
    public var action: AutomationAction
    /// What the action needs: an id, or a priority's raw value.
    public var actionValue: String
    public var enabled: Bool
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String,
        projectID: String,
        name: String,
        trigger: AutomationTrigger,
        triggerStatusID: String? = nil,
        action: AutomationAction,
        actionValue: String = "",
        enabled: Bool = true,
        sortOrder: Double,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.trigger = trigger
        self.triggerStatusID = triggerStatusID
        self.action = action
        self.actionValue = actionValue
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// A saved shape for a new card or a new project.
public struct Template: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    /// `nil` for a project template, which belongs to no project.
    public var projectID: String?
    public var kind: TemplateKind
    public var name: String
    public var payload: String
    public var createdAt: Date

    public init(
        id: String,
        projectID: String?,
        kind: TemplateKind,
        name: String,
        payload: String,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.name = name
        self.payload = payload
        self.createdAt = createdAt
    }
}

/// What a card template writes onto a new card.
///
/// Every field is optional: a template says what it has an opinion about and
/// stays silent on the rest, so "Bug report" can set the type and a checklist
/// without also deciding the assignee.
public struct CardTemplatePayload: Sendable, Equatable, Codable {
    public var titlePrefix: String?
    public var type: TaskType?
    public var priority: Priority?
    public var descriptionMarkdown: String?
    public var labelNames: [String]
    public var checklist: [String]
    public var estimate: Double?
    public var dueInDays: Int?

    public init(
        titlePrefix: String? = nil,
        type: TaskType? = nil,
        priority: Priority? = nil,
        descriptionMarkdown: String? = nil,
        labelNames: [String] = [],
        checklist: [String] = [],
        estimate: Double? = nil,
        dueInDays: Int? = nil
    ) {
        self.titlePrefix = titlePrefix
        self.type = type
        self.priority = priority
        self.descriptionMarkdown = descriptionMarkdown
        self.labelNames = labelNames
        self.checklist = checklist
        self.estimate = estimate
        self.dueInDays = dueInDays
    }
}

/// What a project template lays out.
public struct ProjectTemplatePayload: Sendable, Equatable, Codable {
    public struct Column: Sendable, Equatable, Codable {
        public var name: String
        public var category: StatusCategory
        public var wipLimit: Int?

        public init(name: String, category: StatusCategory, wipLimit: Int? = nil) {
            self.name = name
            self.category = category
            self.wipLimit = wipLimit
        }
    }

    public struct Label: Sendable, Equatable, Codable {
        public var name: String
        public var color: String

        public init(name: String, color: String) {
            self.name = name
            self.color = color
        }
    }

    public var columns: [Column]
    public var labels: [Label]
    public var starterCards: [String]

    public init(columns: [Column], labels: [Label] = [], starterCards: [String] = []) {
        self.columns = columns
        self.labels = labels
        self.starterCards = starterCards
    }
}

/// A timer that is running right now.
public struct RunningTimer: Sendable, Equatable {
    public var taskID: String
    public var personID: String?
    public var startedAt: Date

    public init(taskID: String, personID: String?, startedAt: Date) {
        self.taskID = taskID
        self.personID = personID
        self.startedAt = startedAt
    }

    /// Whole minutes so far, rounded to the nearest.
    public func minutes(now: Date) -> Int {
        max(0, Int((now.timeIntervalSince(startedAt) / 60).rounded()))
    }

    public func elapsed(now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
