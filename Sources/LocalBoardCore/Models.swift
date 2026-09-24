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
        self.sortOrder = sortOrder
        self.createdAt = createdAt
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
    /// The extra rows shown on every card, at most three.
    public var cardFields: [CardField]
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
    public var sortOrder: Double
    public var createdAt: Date

    public init(id: String, name: String, color: String = "graphite", sortOrder: Double, createdAt: Date) {
        self.id = id
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
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
    public var type: TaskType
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
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.statusID = statusID
        self.number = number
        self.type = type
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
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
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String,
        projectID: String,
        name: String,
        query: String,
        sortOrder: Double,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.query = query
        self.sortOrder = sortOrder
        self.createdAt = createdAt
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

    public init(
        id: String,
        taskID: String,
        authorID: String?,
        bodyMarkdown: String,
        createdAt: Date,
        editedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.authorID = authorID
        self.bodyMarkdown = bodyMarkdown
        self.createdAt = createdAt
        self.editedAt = editedAt
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
    public var createdAt: Date

    public init(
        id: String,
        taskID: String,
        personID: String?,
        minutes: Int,
        note: String = "",
        workedOn: Date,
        createdAt: Date
    ) {
        self.id = id
        self.taskID = taskID
        self.personID = personID
        self.minutes = minutes
        self.note = note
        self.workedOn = workedOn
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
