import Foundation
import LocalBoardCore

/// The week's hours, and where a card's time actually went.
///
/// Two reports that look unrelated and are not: both are about time already
/// recorded rather than time being recorded now. The timer lives on the card;
/// this is what you read afterwards.
public struct TimeRepository {

    let database: Database
    private let clock: any ClockProvider
    private let calendar: Calendar

    public init(database: Database, clock: any ClockProvider = SystemClock(), calendar: Calendar = .current) {
        self.database = database
        self.clock = clock
        self.calendar = calendar
    }

    // MARK: - Billable

    public func setBillable(_ billable: Bool, for entryID: String) throws {
        let changed = try database.execute(
            "UPDATE work_log SET billable = ? WHERE id = ?;", [billable ? 1 : 0, entryID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "work log entry \(entryID)") }
    }

    /// Marks every entry on a card, for when a whole card turns out to be
    /// billable after the fact.
    public func setBillable(_ billable: Bool, forTask taskID: String) throws {
        try database.execute(
            "UPDATE work_log SET billable = ? WHERE task_id = ?;", [billable ? 1 : 0, taskID]
        )
    }

    // MARK: - The timesheet

    /// Every entry in one week, across a project.
    public func entries(inProject projectID: String, week: TimesheetWeek, personID: String? = nil) throws -> [WorkLogEntry] {
        var clauses = ["task.project_id = ?", "work_log.worked_on >= ?", "work_log.worked_on < ?"]
        var parameters: [SQLValue] = [
            .text(projectID),
            .real(week.start.timeIntervalSince1970),
            .real(week.end.timeIntervalSince1970),
        ]
        if let personID {
            clauses.append("work_log.person_id = ?")
            parameters.append(.text(personID))
        }

        return try database.query(
            """
            SELECT work_log.* FROM work_log
            JOIN task ON task.id = work_log.task_id
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY work_log.worked_on, work_log.created_at;
            """,
            parameters
        ).map(WorkLogEntry.init(row:))
    }

    /// The week as a grid: one line per card, seven columns of minutes.
    public func timesheet(inProject projectID: String, week: TimesheetWeek, personID: String? = nil) throws -> Timesheet {
        let entries = try entries(inProject: projectID, week: week, personID: personID)

        var titles: [String: String] = [:]
        var keys: [String: String] = [:]
        if !entries.isEmpty {
            // One query for the cards mentioned, rather than one per row.
            let ids = Array(Set(entries.map(\.taskID)))
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            try database.forEachRow(
                """
                SELECT task.id, task.title, task.number, project.key AS project_key
                FROM task JOIN project ON project.id = task.project_id
                WHERE task.id IN (\(placeholders));
                """,
                ids.map(SQLValue.text)
            ) { row in
                let id = try row.requiredString("id")
                titles[id] = row.string("title") ?? "Untitled"
                if let key = row.string("project_key"), let number = row.int("number") {
                    keys[id] = "\(key)-\(number)"
                }
            }
        }

        return Timesheet.build(week: week, entries: entries, titles: titles, keys: keys)
    }

    /// Sets what one cell of the timesheet says.
    ///
    /// A cell holds the total for a card on a day, which may be several
    /// entries written at different moments. Typing a new total therefore
    /// cannot simply overwrite one of them, so:
    ///
    ///  * more time than the cell held is added as one new entry, leaving the
    ///    notes on the existing ones alone;
    ///  * less is taken off the most recent entries first, which is the one
    ///    most likely to be the mistake being corrected;
    ///  * nothing at all removes the day's entries for that card.
    ///
    /// The alternative — replacing the day with a single entry — would throw
    /// away every note anybody wrote, which is the part of a timesheet that
    /// makes it worth anything a month later.
    public func setMinutes(
        _ minutes: Int,
        onTask taskID: String,
        day: Date,
        personID: String?,
        billable: Bool = false
    ) throws {
        guard minutes >= 0 else {
            throw LocalBoardError.invalidInput(field: "minutes", detail: "Time can't be negative.")
        }

        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw LocalBoardError.invalidInput(field: "day", detail: "That day can't be worked out.")
        }

        var clauses = ["task_id = ?", "worked_on >= ?", "worked_on < ?"]
        var parameters: [SQLValue] = [
            .text(taskID), .real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970),
        ]
        if let personID {
            clauses.append("person_id = ?")
            parameters.append(.text(personID))
        } else {
            clauses.append("person_id IS NULL")
        }
        let filter = clauses.joined(separator: " AND ")

        try database.transaction {
            // `rowid` breaks the tie, because two entries logged in the same
            // second are perfectly ordinary — a timer stopped and a correction
            // typed straight after — and without it which one gives way is
            // whatever order SQLite happens to return.
            let existing = try database.query(
                "SELECT * FROM work_log WHERE \(filter) ORDER BY created_at DESC, rowid DESC;", parameters
            ).map(WorkLogEntry.init(row:))

            let current = existing.reduce(0) { $0 + $1.minutes }

            if minutes == 0 {
                for entry in existing {
                    try database.execute("DELETE FROM work_log WHERE id = ?;", [entry.id])
                }
                return
            }

            if minutes > current {
                try database.execute(
                    """
                    INSERT INTO work_log (id, task_id, person_id, minutes, note, worked_on, billable, created_at)
                    VALUES (?, ?, ?, ?, '', ?, ?, ?);
                    """,
                    [UUID().uuidString, taskID, personID.sqlValue, minutes - current,
                     // Noon rather than midnight: a day's entry that sits on
                     // the boundary lands on the wrong side of it in a
                     // timezone an hour away.
                     calendar.date(byAdding: .hour, value: 12, to: start) ?? start,
                     billable ? 1 : 0, clock.now]
                )
                return
            }

            var toRemove = current - minutes
            for entry in existing where toRemove > 0 {
                if entry.minutes <= toRemove {
                    toRemove -= entry.minutes
                    try database.execute("DELETE FROM work_log WHERE id = ?;", [entry.id])
                } else {
                    try database.execute(
                        "UPDATE work_log SET minutes = ? WHERE id = ?;",
                        [entry.minutes - toRemove, entry.id]
                    )
                    toRemove = 0
                }
            }
        }
    }

    /// Total minutes logged in a project over a period, billable or all.
    public func totalMinutes(
        inProject projectID: String,
        from start: Date,
        to end: Date,
        billableOnly: Bool = false
    ) throws -> Int {
        let clause = billableOnly ? " AND work_log.billable = 1" : ""
        return try database.count(
            """
            SELECT COALESCE(SUM(work_log.minutes), 0) FROM work_log
            JOIN task ON task.id = work_log.task_id
            WHERE task.project_id = ? AND work_log.worked_on >= ? AND work_log.worked_on < ?\(clause);
            """,
            [projectID, start, end]
        )
    }

    /// Minutes per day over a period, for a dashboard's chart.
    public func minutesByDay(inProject projectID: String, from start: Date, to end: Date) throws -> [(day: Date, minutes: Int)] {
        var totals: [Date: Int] = [:]
        try database.forEachRow(
            """
            SELECT work_log.worked_on, work_log.minutes FROM work_log
            JOIN task ON task.id = work_log.task_id
            WHERE task.project_id = ? AND work_log.worked_on >= ? AND work_log.worked_on < ?;
            """,
            [projectID, start, end]
        ) { row in
            guard let workedOn = row.date("worked_on") else { return }
            let day = calendar.startOfDay(for: workedOn)
            totals[day, default: 0] += Int(row.int("minutes") ?? 0)
        }
        return totals.sorted { $0.key < $1.key }.map { (day: $0.key, minutes: $0.value) }
    }

    // MARK: - Time in status

    /// One card's history, turned into how long it sat in each column.
    public func timeInStatus(forTask taskID: String) throws -> [TimeInStatus] {
        let changes = try database.query(
            "SELECT * FROM status_change WHERE task_id = ? ORDER BY at;", [taskID]
        ).map { row in
            StatusChangeRecord(
                taskID: try row.requiredString("task_id"),
                fromStatusID: row.string("from_status_id"),
                toStatusID: try row.requiredString("to_status_id"),
                at: try row.requiredDate("at")
            )
        }
        return TimeInStatusReport.forTask(changes, now: clock.now)
    }

    /// The same across a project, added up per column.
    ///
    /// Trashed cards are left out: a report on how long review takes should
    /// not be moved by work somebody threw away.
    public func timeInStatus(inProject projectID: String, since: Date? = nil) throws -> [TimeInStatusSummary] {
        var clauses = ["task.project_id = ?", "task.trashed = 0"]
        var parameters: [SQLValue] = [.text(projectID)]
        if let since {
            clauses.append("task.created_at >= ?")
            parameters.append(.real(since.timeIntervalSince1970))
        }

        var changes: [StatusChangeRecord] = []
        try database.forEachRow(
            """
            SELECT status_change.* FROM status_change
            JOIN task ON task.id = status_change.task_id
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY status_change.at;
            """,
            parameters
        ) { row in
            changes.append(
                StatusChangeRecord(
                    taskID: try row.requiredString("task_id"),
                    fromStatusID: row.string("from_status_id"),
                    toStatusID: try row.requiredString("to_status_id"),
                    at: try row.requiredDate("at")
                )
            )
        }

        let summaries = TimeInStatusReport.across(changes, now: clock.now)

        // Reported in the board's own column order, so the report reads left
        // to right the way the board does.
        var ordered: [TimeInStatusSummary] = []
        try database.forEachRow(
            "SELECT id FROM status WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ) { row in
            let id = try row.requiredString("id")
            if let summary = summaries[id] { ordered.append(summary) }
        }
        // Anything from a column that has since been deleted still happened.
        for (id, summary) in summaries where !ordered.contains(where: { $0.statusID == id }) {
            ordered.append(summary)
        }
        return ordered
    }
}
