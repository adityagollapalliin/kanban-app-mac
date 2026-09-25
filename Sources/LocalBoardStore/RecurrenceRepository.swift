import Foundation
import LocalBoardCore

/// Cards that come back.
///
/// Recurrence here produces a *new* card and leaves the finished one alone.
/// The alternative — resetting the card in place — loses the record that the
/// work was ever done, and a weekly job with no history cannot be reported on,
/// charted, or argued about. The rule moves to the new card so the chain
/// continues from it.
public struct RecurrenceRepository {

    let database: Database
    private let clock: any ClockProvider
    private let calendar: Calendar

    public init(
        database: Database,
        clock: any ClockProvider = SystemClock(),
        calendar: Calendar = .current
    ) {
        self.database = database
        self.clock = clock
        self.calendar = calendar
    }

    // MARK: - Reading and writing rules

    public func recurrence(ofTask taskID: String) throws -> Recurrence? {
        guard let row = try database.queryOne("SELECT * FROM recurrence WHERE task_id = ?;", [taskID])
        else { return nil }
        return try Recurrence(row: row)
    }

    public func recurrences(inProject projectID: String) throws -> [Recurrence] {
        try database.query(
            """
            SELECT recurrence.* FROM recurrence
            JOIN task ON task.id = recurrence.task_id
            WHERE task.project_id = ? AND task.trashed = 0;
            """,
            [projectID]
        ).map(Recurrence.init(row:))
    }

    /// Sets or replaces a card's rule. One rule per card, so this is an
    /// upsert rather than an insert: a card cannot half-recur.
    @discardableResult
    public func setRule(_ rule: RecurrenceRule, forTask taskID: String) throws -> Recurrence {
        let existing = try recurrence(ofTask: taskID)
        let id = existing?.id ?? UUID().uuidString

        try database.execute(
            """
            INSERT INTO recurrence (id, task_id, frequency, interval, weekdays, week_of_month,
                                    month_day, mode, reset_checklist, reset_subtasks, reset_status,
                                    ends_at, last_spawned_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (task_id) DO UPDATE SET
                frequency = ?, interval = ?, weekdays = ?, week_of_month = ?, month_day = ?,
                mode = ?, reset_checklist = ?, reset_subtasks = ?, reset_status = ?, ends_at = ?;
            """,
            [
                id, taskID, rule.frequency.rawValue, rule.interval, rule.weekdayList,
                rule.weekOfMonth.sqlValue, rule.monthDay.sqlValue, rule.mode.rawValue,
                rule.resetChecklist, rule.resetSubtasks, rule.resetStatus, rule.endsAt.sqlValue,
                existing?.lastSpawnedAt.sqlValue ?? SQLValue.null, existing?.createdAt ?? clock.now,
                rule.frequency.rawValue, rule.interval, rule.weekdayList,
                rule.weekOfMonth.sqlValue, rule.monthDay.sqlValue, rule.mode.rawValue,
                rule.resetChecklist, rule.resetSubtasks, rule.resetStatus, rule.endsAt.sqlValue,
            ]
        )
        guard let saved = try recurrence(ofTask: taskID) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The recurrence rule was not written.")
        }
        return saved
    }

    public func removeRule(fromTask taskID: String) throws {
        try database.execute("DELETE FROM recurrence WHERE task_id = ?;", [taskID])
    }

    // MARK: - Producing the next one

    /// Called when a card is finished. Produces the next occurrence for a
    /// rule that recurs on completion; a rule that recurs on a schedule is
    /// left to `spawnDue`, because finishing early must not pull its date
    /// forward.
    @discardableResult
    func completed(_ taskID: String, at when: Date) throws -> BoardTask? {
        guard let recurrence = try recurrence(ofTask: taskID), recurrence.rule.mode == .completion
        else { return nil }

        guard let next = recurrence.rule.next(after: when, calendar: calendar) else {
            // The rule has ended. Removing it stops the card being reported as
            // recurring when it no longer will.
            try removeRule(fromTask: taskID)
            return nil
        }
        return try spawn(from: recurrence, due: next)
    }

    /// Produces whatever the scheduled rules owe.
    ///
    /// Arithmetic over stored dates rather than a timer: a Mac that was asleep
    /// for a fortnight catches up the moment the board opens, and there is no
    /// scheduled job to miss a run. It produces **one** card per rule per
    /// call, not one per missed occurrence — coming back from holiday to a
    /// fortnight of identical cleaning cards helps nobody.
    @discardableResult
    public func spawnDue(inProject projectID: String, now: Date? = nil) throws -> [BoardTask] {
        let moment = now ?? clock.now
        var made: [BoardTask] = []

        for recurrence in try recurrences(inProject: projectID)
        where recurrence.rule.mode == .schedule {
            let task = try TaskRepository(database: database, clock: clock).task(id: recurrence.taskID)

            // Count from the card's own due date when it has one, so a weekly
            // card stays on its weekday instead of drifting to whenever the
            // app was last opened.
            let anchor = recurrence.lastSpawnedAt ?? task.dueDate ?? task.createdAt
            guard let next = recurrence.rule.next(after: anchor, calendar: calendar) else {
                try removeRule(fromTask: recurrence.taskID)
                continue
            }
            guard next <= moment else { continue }

            if let spawned = try spawn(from: recurrence, due: next) { made.append(spawned) }
        }
        return made
    }

    /// Writes the next card and moves the rule onto it.
    private func spawn(from recurrence: Recurrence, due: Date) throws -> BoardTask? {
        let tasks = TaskRepository(database: database, clock: clock)
        let original = try tasks.task(id: recurrence.taskID)

        return try database.transaction {
            // Back to the first column when the rule says to reset the status,
            // otherwise wherever the card already was: a card that recurs
            // mid-review may be meant to come back mid-review.
            let statusID = recurrence.rule.resetStatus
                ? try firstStatusID(projectID: original.projectID) ?? original.statusID
                : original.statusID

            let copy = try tasks.create(
                inProject: original.projectID,
                statusID: statusID,
                title: original.title,
                type: original.type,
                priority: original.priority,
                descriptionMarkdown: original.descriptionMarkdown,
                assigneeID: original.assigneeID,
                dueDate: due,
                listID: original.listID
            )

            // The dates move together: a card due on the 8th that starts on
            // the 6th recurs as one due on the 15th that starts on the 13th.
            if let start = original.startDate, let originalDue = original.dueDate {
                let offset = originalDue.timeIntervalSince(start)
                try tasks.setStartDate(due.addingTimeInterval(-offset), for: copy.id)
            }
            if let estimate = original.estimate {
                try tasks.setEstimate(estimate, for: copy.id)
            }
            if original.isMilestone {
                try database.execute("UPDATE task SET is_milestone = 1 WHERE id = ?;", [copy.id])
            }

            try copyPeople(from: original.id, to: copy.id)
            try copyLabels(from: original.id, to: copy.id)
            if recurrence.rule.resetChecklist { try copyChecklist(from: original.id, to: copy.id) }
            if recurrence.rule.resetSubtasks { try copySubtasks(from: original.id, to: copy.id) }

            // The rule follows the card it now describes, and records that it
            // has produced this one — so reopening the board does not produce
            // it again.
            try database.execute(
                "UPDATE recurrence SET task_id = ?, last_spawned_at = ? WHERE id = ?;",
                [copy.id, due, recurrence.id]
            )
            return try tasks.task(id: copy.id)
        }
    }

    private func firstStatusID(projectID: String) throws -> String? {
        try database.queryOne(
            "SELECT id FROM status WHERE project_id = ? ORDER BY sort_order LIMIT 1;", [projectID]
        )?.string("id")
    }

    private func copyPeople(from source: String, to destination: String) throws {
        try database.execute(
            """
            INSERT OR IGNORE INTO task_assignee (task_id, person_id, estimate, sort_order)
            SELECT ?, person_id, estimate, sort_order FROM task_assignee WHERE task_id = ?;
            """,
            [destination, source]
        )
    }

    private func copyLabels(from source: String, to destination: String) throws {
        try database.execute(
            """
            INSERT OR IGNORE INTO task_label (task_id, label_id)
            SELECT ?, label_id FROM task_label WHERE task_id = ?;
            """,
            [destination, source]
        )
    }

    /// The checklist comes back unticked. That is what "reset the checklist"
    /// means on a card that recurs: the steps are the same, and none of them
    /// has been done this time.
    private func copyChecklist(from source: String, to destination: String) throws {
        let items = try database.query(
            "SELECT * FROM checklist_item WHERE task_id = ? ORDER BY sort_order;", [source]
        ).map(ChecklistItem.init(row:))

        for item in items {
            try database.execute(
                "INSERT INTO checklist_item (id, task_id, text, done, sort_order) VALUES (?, ?, ?, 0, ?);",
                [UUID().uuidString, destination, item.text, item.sortOrder]
            )
        }
    }

    private func copySubtasks(from source: String, to destination: String) throws {
        let tasks = TaskRepository(database: database, clock: clock)
        let children = try database.query(
            "SELECT * FROM task WHERE parent_id = ? AND trashed = 0 ORDER BY sort_order;", [source]
        ).map(BoardTask.init(row:))

        for child in children {
            let copy = try tasks.create(
                inProject: child.projectID,
                statusID: try firstStatusID(projectID: child.projectID) ?? child.statusID,
                title: child.title,
                type: child.type,
                priority: child.priority,
                descriptionMarkdown: child.descriptionMarkdown,
                assigneeID: child.assigneeID,
                listID: child.listID
            )
            try tasks.setParent(destination, for: copy.id)
        }
    }
}
