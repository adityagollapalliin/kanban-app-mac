import Foundation
import LocalBoardCore

/// The day in front of you: what is due, what slipped, what you have chosen to
/// do today, and what has been put off.
public struct PersonalRepository {

    /// One person's work, in the four sections of a day.
    public struct MyWork: Sendable, Equatable {
        public var overdue: [BoardTask] = []
        public var today: [BoardTask] = []
        public var next: [BoardTask] = []
        public var unscheduled: [BoardTask] = []
        /// Put off, with when each comes back. Shown as a line rather than a
        /// section, because the point of snoozing is not to see it.
        public var snoozed: [BoardTask] = []

        public init() {}

        public func tasks(in section: WorkSection) -> [BoardTask] {
            switch section {
            case .overdue: overdue
            case .today: today
            case .next: next
            case .unscheduled: unscheduled
            }
        }

        public var count: Int { overdue.count + today.count + next.count + unscheduled.count }
    }

    let database: Database
    private let clock: any ClockProvider
    private let calendar: Calendar

    public init(
        database: Database, clock: any ClockProvider = SystemClock(), calendar: Calendar = .current
    ) {
        self.database = database
        self.clock = clock
        self.calendar = calendar
    }

    // MARK: - My work

    /// Everything assigned to one person, sorted into the day's sections.
    ///
    /// One query and a pure rule, rather than four queries: four queries can
    /// disagree about a card on a boundary, and this way `WorkPlanner` is the
    /// only thing that decides where anything goes.
    public func myWork(for personID: String?, now: Date? = nil) throws -> MyWork {
        let moment = now ?? clock.now

        let tasks: [BoardTask]
        if let personID {
            tasks = try database.query(
                """
                SELECT DISTINCT task.* FROM task
                LEFT JOIN task_assignee ON task_assignee.task_id = task.id
                WHERE task.trashed = 0 AND task.completed_at IS NULL
                  AND (task.assignee_id = ? OR task_assignee.person_id = ?)
                ORDER BY task.due_date, task.priority DESC;
                """,
                [personID, personID]
            ).map(BoardTask.init(row:))
        } else {
            // Nobody is set as "me" yet. Showing everything is more useful
            // than showing nothing, and the screen says which it is doing.
            tasks = try database.query(
                """
                SELECT * FROM task WHERE trashed = 0 AND completed_at IS NULL
                ORDER BY due_date, priority DESC;
                """
            ).map(BoardTask.init(row:))
        }

        var work = MyWork()
        for task in tasks {
            if let until = task.snoozedUntil, until > moment {
                work.snoozed.append(task)
                continue
            }

            switch WorkPlanner.section(
                due: task.dueDate, plannedFor: task.plannedFor,
                snoozedUntil: task.snoozedUntil, isDone: task.completedAt != nil,
                now: moment, calendar: calendar
            ) {
            case .overdue: work.overdue.append(task)
            case .today: work.today.append(task)
            case .next: work.next.append(task)
            case .unscheduled: work.unscheduled.append(task)
            case nil: break
            }
        }
        return work
    }

    /// Marks a card as chosen for today — which is not the same as changing
    /// its due date, and deliberately does not.
    public func planForToday(_ taskID: String, on day: Date? = nil) throws {
        let moment = calendar.startOfDay(for: day ?? clock.now)
        try update(taskID, "planned_for = ?", [moment])
    }

    public func unplan(_ taskID: String) throws {
        try update(taskID, "planned_for = NULL", [])
    }

    /// What is worth offering when planning a day: everything due soon or
    /// overdue that has not already been picked.
    public func candidatesForToday(personID: String?, now: Date? = nil) throws -> [BoardTask] {
        let work = try myWork(for: personID, now: now)
        let moment = now ?? clock.now
        return (work.overdue + work.today + work.next).filter { task in
            guard let planned = task.plannedFor else { return true }
            return !calendar.isDate(planned, inSameDayAs: moment)
        }
    }

    // MARK: - Snoozing

    /// Puts something off without moving its due date.
    ///
    /// The date is a promise to other people; a snooze is "stop asking me
    /// until Thursday". Rewriting the date every time somebody wants five
    /// minutes' peace quietly rewrites the plan.
    public func snooze(_ taskID: String, until: Date) throws {
        try update(taskID, "snoozed_until = ?", [until])
    }

    public func wake(_ taskID: String) throws {
        try update(taskID, "snoozed_until = NULL", [])
    }

    private func update(_ taskID: String, _ assignment: String, _ values: [SQLValueConvertible]) throws {
        let changed = try database.execute(
            "UPDATE task SET \(assignment), updated_at = ? WHERE id = ?;",
            values + [clock.now, taskID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "task \(taskID)") }
    }

    // MARK: - Reminders

    public func reminders(includeDone: Bool = false) throws -> [Reminder] {
        let clause = includeDone ? "" : "WHERE completed_at IS NULL"
        return try database.query(
            "SELECT * FROM reminder \(clause) ORDER BY (due_at IS NULL), due_at, sort_order;"
        ).map(Reminder.init(row:))
    }

    @discardableResult
    public func createReminder(title: String, notes: String = "", dueAt: Date? = nil) throws -> Reminder {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "title", detail: "A reminder needs a few words.")
        }

        let id = UUID().uuidString
        let last = try database.queryOne("SELECT MAX(sort_order) AS last FROM reminder;")?.double("last")
        try database.execute(
            """
            INSERT INTO reminder (id, title, notes, due_at, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [id, trimmed, notes, dueAt.sqlValue, SortOrder.between(last, nil), clock.now]
        )
        return try reminder(id: id)
    }

    public func reminder(id: String) throws -> Reminder {
        guard let row = try database.queryOne("SELECT * FROM reminder WHERE id = ?;", [id]) else {
            throw LocalBoardError.notFound(entity: "reminder \(id)")
        }
        return try Reminder(row: row)
    }

    public func updateReminder(_ id: String, title: String, notes: String, dueAt: Date?) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "title", detail: "A reminder needs a few words.")
        }
        let changed = try database.execute(
            "UPDATE reminder SET title = ?, notes = ?, due_at = ? WHERE id = ?;",
            [trimmed, notes, dueAt.sqlValue, id]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "reminder \(id)") }
    }

    /// Finishing a reminder clears its snooze: a thing that is done has
    /// nothing left to come back for.
    public func setReminderDone(_ done: Bool, for id: String) throws {
        try database.execute(
            "UPDATE reminder SET completed_at = ?, snoozed_until = NULL WHERE id = ?;",
            [done ? clock.now.sqlValue : SQLValue.null, id]
        )
    }

    public func snoozeReminder(_ id: String, until: Date) throws {
        try database.execute("UPDATE reminder SET snoozed_until = ? WHERE id = ?;", [until, id])
    }

    public func deleteReminder(_ id: String) throws {
        try database.execute("DELETE FROM reminder WHERE id = ?;", [id])
    }

    /// The reminders that should ring: due, not done, not snoozed past now.
    public func dueReminders(now: Date? = nil) throws -> [Reminder] {
        let moment = now ?? clock.now
        return try reminders().filter { reminder in
            guard let due = reminder.dueAt, due <= moment else { return false }
            return !reminder.isSnoozed(now: moment)
        }
    }

    // MARK: - The notepad

    /// The pad, which always exists. A scratch pad you have to create before
    /// you can write in it is not a scratch pad.
    public func notepad() throws -> String {
        try database.queryOne("SELECT body_md FROM notepad WHERE id = 1;")?.string("body_md") ?? ""
    }

    public func setNotepad(_ body: String) throws {
        try database.execute(
            """
            INSERT INTO notepad (id, body_md, updated_at) VALUES (1, ?, ?)
            ON CONFLICT (id) DO UPDATE SET body_md = ?, updated_at = ?;
            """,
            [body, clock.now, body, clock.now]
        )
    }
}
