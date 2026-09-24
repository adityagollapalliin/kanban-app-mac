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

    public init(id: String, projectID: String, name: String, sortOrder: Double, createdAt: Date) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
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
    public var sortOrder: Double

    public init(
        id: String,
        boardID: String,
        statusID: String,
        name: String,
        wipLimit: Int? = nil,
        sortOrder: Double
    ) {
        self.id = id
        self.boardID = boardID
        self.statusID = statusID
        self.name = name
        self.wipLimit = wipLimit
        self.sortOrder = sortOrder
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

public struct Label: Sendable, Equatable, Identifiable, Codable {
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
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}
