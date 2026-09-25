import CoreGraphics
import Foundation

/// A reminder: a thing to be reminded about, deliberately not a card.
///
/// It has no column, no assignee, no estimate and no place on a board. Making
/// it a task would put "ring the dentist" into a project's cycle-time
/// statistics and onto somebody's workload bar.
public struct Reminder: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var title: String
    public var notes: String
    public var dueAt: Date?
    /// Set by a snooze. While it is in the future the reminder stays quiet,
    /// without its due date moving — the date is when it was meant to happen,
    /// and losing that loses how late it now is.
    public var snoozedUntil: Date?
    public var completedAt: Date?
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String, title: String, notes: String = "", dueAt: Date? = nil,
        snoozedUntil: Date? = nil, completedAt: Date? = nil,
        sortOrder: Double, createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.snoozedUntil = snoozedUntil
        self.completedAt = completedAt
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    public var isDone: Bool { completedAt != nil }

    public func isSnoozed(now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > now
    }
}

/// How long something is put off for.
///
/// Fixed choices rather than a date picker for the common cases, because the
/// point of a snooze is to get rid of something in one click. "Custom" is
/// there for the time somebody genuinely means the 14th.
public enum SnoozeOption: Int, Sendable, CaseIterable, Codable {
    case laterToday = 0
    case tomorrow = 1
    case nextWeek = 2

    public var label: String {
        switch self {
        case .laterToday: "Later today"
        case .tomorrow: "Tomorrow"
        case .nextWeek: "Next week"
        }
    }

    /// When it comes back.
    ///
    /// "Later today" is three hours on, not a fixed hour: snoozing at nine in
    /// the morning and at four in the afternoon mean different things by
    /// "later", and a fixed 5pm would mean "never" for the second one.
    /// Tomorrow and next week land at nine in the morning, which is when a
    /// working day starts asking.
    public func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .laterToday:
            return now.addingTimeInterval(3 * 60 * 60)

        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow

        case .nextWeek:
            let week = calendar.date(byAdding: .day, value: 7, to: now) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: week) ?? week
        }
    }
}

/// Which part of "my work" something belongs to.
public enum WorkSection: Int, Sendable, CaseIterable, Codable {
    case overdue = 0
    case today = 1
    case next = 2
    case unscheduled = 3

    public var label: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .next: "Next 7 days"
        case .unscheduled: "Unscheduled"
        }
    }

    public var symbol: String {
        switch self {
        case .overdue: "exclamationmark.triangle"
        case .today: "sun.max"
        case .next: "calendar"
        case .unscheduled: "tray"
        }
    }
}

/// Which section a piece of work falls into.
///
/// A rule rather than four queries, so the four sections cannot disagree about
/// a card that sits on a boundary. Three decisions are worth stating:
///
///   * **Overdue wins over today.** Something due yesterday is not part of
///     today's plan; it is a thing that has already gone wrong, and burying it
///     among today's work is how it stays wrong.
///   * **Planning a card for today puts it in Today whatever its due date.**
///     "I am doing this today" and "this is due today" are different
///     statements, and the day's list is made of the first.
///   * **A snoozed card is in no section at all.** That is what a snooze is.
public enum WorkPlanner {

    public static func section(
        due: Date?,
        plannedFor: Date? = nil,
        snoozedUntil: Date? = nil,
        isDone: Bool = false,
        now: Date,
        calendar: Calendar = .current
    ) -> WorkSection? {
        if isDone { return nil }
        if let snoozedUntil, snoozedUntil > now { return nil }

        let today = calendar.startOfDay(for: now)

        if let plannedFor, calendar.isDate(plannedFor, inSameDayAs: now) {
            // Still overdue if it is: choosing to do it today does not undo
            // the fact that it was due last week.
            if let due, calendar.startOfDay(for: due) < today { return .overdue }
            return .today
        }

        guard let due else { return .unscheduled }
        let day = calendar.startOfDay(for: due)

        if day < today { return .overdue }
        if day == today { return .today }

        guard let horizon = calendar.date(byAdding: .day, value: 7, to: today) else { return .next }
        return day <= horizon ? .next : nil
    }

    /// What dragging something into a section means.
    ///
    /// Moving work between the sections of a day is rescheduling it, so it
    /// writes a due date — except Unscheduled, which takes the date away, and
    /// Overdue, which nothing can be dragged into: you cannot decide to have
    /// been late.
    public static func dueDate(
        forDropInto section: WorkSection, now: Date, calendar: Calendar = .current
    ) -> Date?? {
        switch section {
        case .today:
            return .some(calendar.startOfDay(for: now))
        case .next:
            let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            return .some(day ?? now)
        case .unscheduled:
            return .some(nil)
        case .overdue:
            return .none
        }
    }
}

// MARK: - Documents

/// A document. Pages nest through `parentID`, and a document with no project
/// belongs to nobody in particular — forcing every note into a space is how
/// people stop writing them.
public struct Doc: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String?
    public var parentID: String?
    public var title: String
    public var icon: String
    public var bodyMarkdown: String
    public var archived: Bool
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, projectID: String? = nil, parentID: String? = nil,
        title: String, icon: String = "", bodyMarkdown: String = "",
        archived: Bool = false, sortOrder: Double, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.parentID = parentID
        self.title = title
        self.icon = icon
        self.bodyMarkdown = bodyMarkdown
        self.archived = archived
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// What a document's slash menu offers.
///
/// Each is a piece of Markdown, because the document *is* Markdown: a slash
/// command that produced anything else would make the file unreadable outside
/// this app, which is the one thing a local-first document must not be.
public enum SlashCommand: String, Sendable, CaseIterable, Identifiable {
    case heading1, heading2, heading3
    case bulleted, numbered, checklist
    case table, code, quote, callout, divider

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bulleted: "Bulleted list"
        case .numbered: "Numbered list"
        case .checklist: "Checklist"
        case .table: "Table"
        case .code: "Code block"
        case .quote: "Quote"
        case .callout: "Callout"
        case .divider: "Divider"
        }
    }

    public var symbol: String {
        switch self {
        case .heading1, .heading2, .heading3: "textformat.size"
        case .bulleted: "list.bullet"
        case .numbered: "list.number"
        case .checklist: "checklist"
        case .table: "tablecells"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .quote: "text.quote"
        case .callout: "exclamationmark.bubble"
        case .divider: "minus"
        }
    }

    /// The Markdown it inserts, and where the cursor should end up within it.
    public var snippet: String {
        switch self {
        case .heading1: "# "
        case .heading2: "## "
        case .heading3: "### "
        case .bulleted: "- "
        case .numbered: "1. "
        case .checklist: "- [ ] "
        case .table: "| Column | Column |\n| --- | --- |\n|  |  |\n"
        case .code: "```\n\n```\n"
        case .quote: "> "
        case .callout: "> [!note]\n> "
        case .divider: "\n---\n"
        }
    }
}

// MARK: - Whiteboards

public enum WhiteboardItemKind: Int, Sendable, CaseIterable, Codable {
    case sticky = 0
    case shape = 1
    case text = 2
    case ink = 3
    case connector = 4

    public var label: String {
        switch self {
        case .sticky: "Sticky note"
        case .shape: "Shape"
        case .text: "Text"
        case .ink: "Drawing"
        case .connector: "Connector"
        }
    }

    public var symbol: String {
        switch self {
        case .sticky: "note.text"
        case .shape: "square.on.circle"
        case .text: "textformat"
        case .ink: "scribble"
        case .connector: "arrow.right"
        }
    }
}

public enum WhiteboardShape: Int, Sendable, CaseIterable, Codable {
    case rectangle = 0
    case ellipse = 1
    case diamond = 2

    public var label: String {
        switch self {
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .diamond: "Diamond"
        }
    }
}

public struct Whiteboard: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var projectID: String?
    public var name: String
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, projectID: String? = nil, name: String,
        sortOrder: Double, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One thing on a canvas.
///
/// Stickies, shapes, text, ink and connectors share a type because they differ
/// in what they draw, not in what they are: a thing at a position. Five types
/// would be five places for selection, z-order and deletion to drift apart.
public struct WhiteboardItem: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var boardID: String
    public var kind: WhiteboardItemKind
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var text: String
    public var color: String
    public var shape: WhiteboardShape
    /// A freehand stroke, as "x,y x,y x,y". Text rather than a blob so the
    /// file stays readable in `sqlite3`. Held as flat numbers rather than
    /// points so the whole type stays `Codable` without a hand-written coder
    /// for a field only the canvas ever reads.
    public var strokeValues: [Double]
    public var fromItem: String?
    public var toItem: String?
    /// Set once a sticky has become a card, so the canvas can say so instead
    /// of offering to make a second one.
    public var taskID: String?
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String, boardID: String, kind: WhiteboardItemKind,
        x: Double = 0, y: Double = 0, width: Double = 140, height: Double = 100,
        text: String = "", color: String = "yellow", shape: WhiteboardShape = .rectangle,
        strokeValues: [Double] = [], fromItem: String? = nil, toItem: String? = nil,
        taskID: String? = nil, sortOrder: Double, createdAt: Date
    ) {
        self.id = id
        self.boardID = boardID
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
        self.color = color
        self.shape = shape
        self.strokeValues = strokeValues
        self.fromItem = fromItem
        self.toItem = toItem
        self.taskID = taskID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    /// The stroke as points, for drawing.
    public var points: [CGPoint] {
        stride(from: 0, to: strokeValues.count - 1, by: 2).map {
            CGPoint(x: strokeValues[$0], y: strokeValues[$0 + 1])
        }
    }

    public var encodedPoints: String {
        stride(from: 0, to: strokeValues.count - 1, by: 2)
            .map { "\(strokeValues[$0]),\(strokeValues[$0 + 1])" }
            .joined(separator: " ")
    }

    public static func strokeValues(from text: String) -> [Double] {
        text.split(separator: " ").flatMap { pair -> [Double] in
            let parts = pair.split(separator: ",").compactMap { Double($0) }
            return parts.count == 2 ? parts : []
        }
    }

    public static func strokeValues(from points: [CGPoint]) -> [Double] {
        points.flatMap { [Double($0.x), Double($0.y)] }
    }
}
