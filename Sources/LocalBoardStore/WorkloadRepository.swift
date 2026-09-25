import Foundation
import LocalBoardCore

/// Who is carrying how much, against what they can carry.
///
/// Two decisions worth stating, because both change the numbers:
///
///   * **A card with several people is split between them.** Counting its
///     whole estimate against each would show three people at capacity for one
///     day's work. Where somebody has been given their own share, that share
///     is used; where nobody has, the estimate is divided equally.
///   * **A card counts on the day it is due.** Spreading it across the days
///     between start and due would be a guess about how the work is paced, and
///     a wrong guess moves the red bar to the wrong week.
public struct WorkloadRepository {

    /// One person's load over one window.
    public struct Load: Sendable, Equatable, Identifiable {
        public let person: Person
        /// The amount landing on each day of the window, by start of day.
        public let byDay: [Date: Double]
        public let tasks: [BoardTask]
        /// Cards with no estimate at all. Reported rather than counted as
        /// zero, because a week of unestimated work is not an empty week —
        /// the bar would otherwise say someone is free when nobody knows.
        public let unestimatedCount: Int

        public var id: String { person.id }

        public var total: Double { byDay.values.reduce(0, +) }

        /// What the person can take over the whole window.
        public func capacity(days: Int) -> Double {
            guard person.hasCapacity else { return 0 }
            return person.weeklyCapacity * (Double(days) / 7.0)
        }

        /// Over capacity is the only state the view colours red, and it needs
        /// a capacity to be over: somebody who has never set one is drawn
        /// without a ceiling rather than as permanently overloaded.
        public func isOver(days: Int) -> Bool {
            person.hasCapacity && total > capacity(days: days)
        }

        public func fraction(days: Int) -> Double {
            let limit = capacity(days: days)
            guard limit > 0 else { return 0 }
            return total / limit
        }
    }

    let database: Database
    private let calendar: Calendar

    public init(database: Database, calendar: Calendar = .current) {
        self.database = database
        self.calendar = calendar
    }

    // MARK: - Capacity

    public func setCapacity(
        _ amount: Double, unit: CapacityUnit, period: CapacityPeriod, for personID: String
    ) throws {
        let changed = try database.execute(
            """
            UPDATE person SET capacity_amount = ?, capacity_unit = ?, capacity_period = ?
            WHERE id = ?;
            """,
            [max(0, amount), unit.rawValue, period.rawValue, personID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "person \(personID)") }
    }

    // MARK: - The load

    /// Everyone's load across a window of days starting at `from`.
    ///
    /// Everyone, including people carrying nothing: a workload view that
    /// silently omitted the person with a free week would be answering a
    /// different question from the one it is asked.
    public func loads(
        inProject projectID: String, from start: Date, days: Int
    ) throws -> [Load] {
        let firstDay = calendar.startOfDay(for: start)
        guard let lastDay = calendar.date(byAdding: .day, value: days, to: firstDay) else { return [] }

        let people = try database.query("SELECT * FROM person ORDER BY sort_order;").map(Person.init(row:))

        // Every card in the window, with everyone on it, in one pass.
        let rows = try database.query(
            """
            SELECT task.*, task_assignee.person_id AS who, task_assignee.estimate AS share
            FROM task
            JOIN task_assignee ON task_assignee.task_id = task.id
            WHERE task.project_id = ? AND task.trashed = 0 AND task.completed_at IS NULL
              AND task.due_date >= ? AND task.due_date < ?;
            """,
            [projectID, firstDay, lastDay]
        )

        var byPerson: [String: [Date: Double]] = [:]
        var tasksByPerson: [String: [BoardTask]] = [:]
        var unestimated: [String: Int] = [:]
        var peopleOnTask: [String: Int] = [:]

        // How many people share each card, so an equal split knows what it is
        // splitting between.
        for row in rows {
            guard let taskID = row.string("id") else { continue }
            peopleOnTask[taskID, default: 0] += 1
        }

        for row in rows {
            guard let who = row.string("who") else { continue }
            let task = try BoardTask(row: row)
            guard let due = task.dueDate else { continue }
            let day = calendar.startOfDay(for: due)

            tasksByPerson[who, default: []].append(task)

            guard let estimate = task.estimate else {
                unestimated[who, default: 0] += 1
                continue
            }

            // Their own share if they have one; an equal cut of the card if
            // not. Both beat counting the whole card against everybody.
            let share = row.double("share") ?? (estimate / Double(max(1, peopleOnTask[task.id] ?? 1)))
            byPerson[who, default: [:]][day, default: 0] += share
        }

        return people.map { person in
            Load(
                person: person,
                byDay: byPerson[person.id] ?? [:],
                tasks: tasksByPerson[person.id] ?? [],
                unestimatedCount: unestimated[person.id] ?? 0
            )
        }
    }

    /// Moving a card in the workload view means changing when it is due and
    /// who it is for — the two things the view is arranged by. One call,
    /// because doing half of it leaves the card where it was not dropped.
    public func reassign(
        _ taskID: String, to personID: String?, on day: Date?, clock: any ClockProvider = SystemClock()
    ) throws {
        try database.transaction {
            if let personID {
                let membership = MembershipRepository(database: database, clock: clock)
                for existing in try membership.assignees(ofTask: taskID) {
                    try membership.removeAssignee(existing.personID, from: taskID)
                }
                try membership.addAssignee(personID, to: taskID)
            }
            if let day {
                try TaskRepository(database: database, clock: clock)
                    .setDueDate(calendar.startOfDay(for: day), for: taskID)
            }
        }
    }
}
