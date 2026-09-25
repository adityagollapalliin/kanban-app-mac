import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 1
    return calendar
}()

private func day(_ text: String) -> Date {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
}

@Suite("A card that comes back")
struct RecurrenceRepositoryTests {

    /// A finished card stays finished. Resetting it in place would lose the
    /// record that the work was ever done, and a weekly job with no history
    /// cannot be reported on.
    @Test("Completing one produces the next and leaves the old one done")
    func recursOnCompletion() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-05"))
        let tasks = TaskRepository(database: database, clock: clock)
        let recurrences = RecurrenceRepository(database: database, clock: clock, calendar: utc)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Water the plants")
        try tasks.setDueDate(day("2026-01-05"), for: task.id)
        try recurrences.setRule(
            RecurrenceRule(frequency: .weekly, mode: .completion), forTask: task.id
        )

        try tasks.move(task.id, toStatus: ids.done)

        let all = try database.query("SELECT * FROM task ORDER BY number;").map(BoardTask.init(row:))
        #expect(all.count == 2)
        #expect(all[0].completedAt != nil)
        #expect(all[1].title == "Water the plants")
        #expect(all[1].completedAt == nil)
        #expect(all[1].statusID == ids.toDo)
        // A week on. Compared in whole days rather than against a fixed
        // instant: the completion path deliberately uses the user's own
        // calendar, so a card finished in Kolkata recurs onto Kolkata's next
        // Monday rather than onto UTC's.
        let local = Calendar.current
        let gap = local.dateComponents(
            [.day],
            from: local.startOfDay(for: day("2026-01-05")),
            to: local.startOfDay(for: try #require(all[1].dueDate))
        ).day
        #expect(gap == 7)

        // The rule moved to the new card, so the chain continues from it.
        #expect(try recurrences.recurrence(ofTask: task.id) == nil)
        #expect(try recurrences.recurrence(ofTask: all[1].id) != nil)
    }

    /// Finishing early must not pull a scheduled rule's date forward: the
    /// cleaner still comes on Tuesday.
    @Test("A scheduled rule ignores when the card was finished")
    func scheduleDoesNotFollowCompletion() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-05"))
        let tasks = TaskRepository(database: database, clock: clock)
        let recurrences = RecurrenceRepository(database: database, clock: clock, calendar: utc)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Weekly report")
        try tasks.setDueDate(day("2026-01-09"), for: task.id)
        try recurrences.setRule(RecurrenceRule(frequency: .weekly, mode: .schedule), forTask: task.id)

        try tasks.move(task.id, toStatus: ids.done)
        #expect(try database.count("SELECT COUNT(*) FROM task;") == 1)

        // It arrives when its own date comes round, not when the last was done.
        clock.now = day("2026-01-17")
        let made = try recurrences.spawnDue(inProject: ids.project)
        #expect(made.count == 1)
        #expect(made[0].dueDate == day("2026-01-16"))
    }

    /// Coming back from a fortnight away to fourteen identical cleaning cards
    /// helps nobody: the rule catches up to one card, not to every occurrence
    /// it slept through.
    @Test("A missed fortnight produces one card, not fourteen")
    func catchesUpOnce() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-01"))
        let tasks = TaskRepository(database: database, clock: clock)
        let recurrences = RecurrenceRepository(database: database, clock: clock, calendar: utc)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Daily standup")
        try tasks.setDueDate(day("2026-01-01"), for: task.id)
        try recurrences.setRule(RecurrenceRule(frequency: .daily, mode: .schedule), forTask: task.id)

        clock.now = day("2026-01-15")
        #expect(try recurrences.spawnDue(inProject: ids.project).count == 1)
        #expect(try database.count("SELECT COUNT(*) FROM task;") == 2)

        // And opening the board again does not produce the same one twice.
        #expect(try recurrences.spawnDue(inProject: ids.project).count == 1)
        #expect(try database.count("SELECT COUNT(*) FROM task;") == 3)
    }

    @Test("The checklist comes back, unticked")
    func checklistResets() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-05"))
        let tasks = TaskRepository(database: database, clock: clock)
        let checklists = ChecklistRepository(database: database)
        let recurrences = RecurrenceRepository(database: database, clock: clock, calendar: utc)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Close the books")
        let step = try checklists.add(toTask: task.id, text: "Reconcile")
        try checklists.setDone(true, for: step.id)
        try recurrences.setRule(
            RecurrenceRule(frequency: .monthly, monthDay: 1, mode: .completion, resetChecklist: true),
            forTask: task.id
        )

        try tasks.move(task.id, toStatus: ids.done)

        let next = try #require(try database.query("SELECT * FROM task ORDER BY number;")
            .map(BoardTask.init(row:)).last)
        let copied = try checklists.items(forTask: next.id)
        #expect(copied.map(\.text) == ["Reconcile"])
        #expect(copied.allSatisfy { !$0.done })
    }

    @Test("A rule that has ended stops rather than lingering")
    func endedRuleIsRemoved() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-05"))
        let tasks = TaskRepository(database: database, clock: clock)
        let recurrences = RecurrenceRepository(database: database, clock: clock, calendar: utc)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Finishing soon")
        try recurrences.setRule(
            RecurrenceRule(frequency: .weekly, mode: .completion, endsAt: day("2026-01-06")),
            forTask: task.id
        )

        try tasks.move(task.id, toStatus: ids.done)
        #expect(try database.count("SELECT COUNT(*) FROM task;") == 1)
        #expect(try recurrences.recurrence(ofTask: task.id) == nil)
    }

    @Test("A card recurs with the people who were on it")
    func peopleCarryOver() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-05"))
        let tasks = TaskRepository(database: database, clock: clock)
        let people = PersonRepository(database: database)
        let membership = MembershipRepository(database: database, clock: clock)
        let recurrences = RecurrenceRepository(database: database, clock: clock, calendar: utc)

        let ada = try people.create(name: "Ada")
        let grace = try people.create(name: "Grace")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Pair on it")
        try membership.addAssignee(ada.id, to: task.id)
        try membership.addAssignee(grace.id, to: task.id)
        try recurrences.setRule(RecurrenceRule(frequency: .weekly, mode: .completion), forTask: task.id)

        try tasks.move(task.id, toStatus: ids.done)

        let next = try #require(try database.query("SELECT * FROM task ORDER BY number;")
            .map(BoardTask.init(row:)).last)
        #expect(try membership.assignees(ofTask: next.id).count == 2)
    }

    /// One rule per card, so a card cannot half-recur.
    @Test("Setting a rule twice replaces it")
    func rulesAreReplaced() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let recurrences = RecurrenceRepository(database: database, calendar: utc)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Changing my mind")
        try recurrences.setRule(RecurrenceRule(frequency: .daily), forTask: task.id)
        try recurrences.setRule(RecurrenceRule(frequency: .monthly, monthDay: 3), forTask: task.id)

        #expect(try database.count("SELECT COUNT(*) FROM recurrence WHERE task_id = ?;", [task.id]) == 1)
        #expect(try recurrences.recurrence(ofTask: task.id)?.rule.frequency == .monthly)
    }
}

@Suite("The trash empties itself")
struct TrashTests {

    @Test("Thirty days is when it goes")
    func purgesAfterThirtyDays() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-01"))
        let tasks = TaskRepository(database: database, clock: clock)
        let sidebar = SidebarRepository(database: database, clock: clock)

        let old = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Long gone")
        try tasks.setTrashed(true, for: old.id)

        clock.advance(days: 29)
        let recent = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Just thrown")
        try tasks.setTrashed(true, for: recent.id)

        clock.advance(days: 1)
        #expect(try sidebar.purgeExpiredTrash() == 1)
        #expect(try sidebar.trashed().map(\.title) == ["Just thrown"])
    }

    /// The date it was thrown away is not the date it was last edited: the
    /// trashing itself moves `updated_at`, so it cannot answer this.
    @Test("Taking something back out clears its clock")
    func restoringClearsTheClock() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-01"))
        let tasks = TaskRepository(database: database, clock: clock)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Second thoughts")
        try tasks.setTrashed(true, for: task.id)
        #expect(try tasks.task(id: task.id).trashedAt != nil)

        try tasks.setTrashed(false, for: task.id)
        #expect(try tasks.task(id: task.id).trashedAt == nil)

        clock.advance(days: 40)
        #expect(try SidebarRepository(database: database, clock: clock).purgeExpiredTrash() == 0)
    }

    /// A card trashed by a build that never recorded the date is left alone
    /// rather than guessed at and deleted.
    @Test("Something with no date is never purged")
    func undatedTrashSurvives() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-01"))
        let tasks = TaskRepository(database: database, clock: clock)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "From an older build")
        try database.execute("UPDATE task SET trashed = 1, trashed_at = NULL WHERE id = ?;", [task.id])

        clock.advance(days: 400)
        #expect(try SidebarRepository(database: database, clock: clock).purgeExpiredTrash() == 0)
    }

    @Test("Emptying it is a verb of its own")
    func emptying() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let sidebar = SidebarRepository(database: database)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Gone")
        let kept = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Kept")
        try tasks.setTrashed(true, for: task.id)

        #expect(try sidebar.emptyTrash() == 1)
        #expect(try database.count("SELECT COUNT(*) FROM task;") == 1)
        #expect(try tasks.task(id: kept.id).title == "Kept")
    }
}

@Suite("Who is carrying how much")
struct WorkloadTests {

    /// Counting a shared card's whole estimate against each person would show
    /// three people at capacity for one day's work.
    @Test("A shared card is split between the people on it")
    func sharedCardsAreSplit() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-05"))
        let tasks = TaskRepository(database: database, clock: clock)
        let people = PersonRepository(database: database)
        let membership = MembershipRepository(database: database, clock: clock)

        let ada = try people.create(name: "Ada")
        let grace = try people.create(name: "Grace")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Together")
        try tasks.setEstimate(8, for: task.id)
        try tasks.setDueDate(day("2026-01-07"), for: task.id)
        try membership.addAssignee(ada.id, to: task.id)
        try membership.addAssignee(grace.id, to: task.id)

        let loads = try WorkloadRepository(database: database, calendar: utc)
            .loads(inProject: ids.project, from: day("2026-01-05"), days: 7)

        #expect(loads.first { $0.person.id == ada.id }?.total == 4)
        #expect(loads.first { $0.person.id == grace.id }?.total == 4)
    }

    @Test("A stated share beats an equal split")
    func statedSharesAreUsed() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-05"))
        let tasks = TaskRepository(database: database, clock: clock)
        let people = PersonRepository(database: database)
        let membership = MembershipRepository(database: database, clock: clock)

        let ada = try people.create(name: "Ada")
        let grace = try people.create(name: "Grace")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Uneven")
        try tasks.setEstimate(10, for: task.id)
        try tasks.setDueDate(day("2026-01-07"), for: task.id)
        try membership.addAssignee(ada.id, to: task.id, estimate: 8)
        try membership.addAssignee(grace.id, to: task.id, estimate: 2)

        let loads = try WorkloadRepository(database: database, calendar: utc)
            .loads(inProject: ids.project, from: day("2026-01-05"), days: 7)

        #expect(loads.first { $0.person.id == ada.id }?.total == 8)
        #expect(loads.first { $0.person.id == grace.id }?.total == 2)
    }

    /// A week of unestimated work is not an empty week. Counting it as zero
    /// would say somebody is free when nobody knows.
    @Test("Unestimated cards are reported, not counted as nothing")
    func unestimatedIsReported() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-05"))
        let tasks = TaskRepository(database: database, clock: clock)
        let people = PersonRepository(database: database)
        let membership = MembershipRepository(database: database, clock: clock)

        let ada = try people.create(name: "Ada")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Who knows")
        try tasks.setDueDate(day("2026-01-07"), for: task.id)
        try membership.addAssignee(ada.id, to: task.id)

        let load = try #require(try WorkloadRepository(database: database, calendar: utc)
            .loads(inProject: ids.project, from: day("2026-01-05"), days: 7)
            .first { $0.person.id == ada.id })

        #expect(load.total == 0)
        #expect(load.unestimatedCount == 1)
    }

    /// Somebody who has never set a capacity is drawn without a ceiling
    /// rather than as permanently overloaded.
    @Test("Over capacity needs a capacity")
    func overCapacityNeedsALimit() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-05"))
        let tasks = TaskRepository(database: database, clock: clock)
        let people = PersonRepository(database: database)
        let membership = MembershipRepository(database: database, clock: clock)
        let workload = WorkloadRepository(database: database, calendar: utc)

        let ada = try people.create(name: "Ada")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Far too much")
        try tasks.setEstimate(60, for: task.id)
        try tasks.setDueDate(day("2026-01-07"), for: task.id)
        try membership.addAssignee(ada.id, to: task.id)

        func load() throws -> WorkloadRepository.Load {
            try #require(try workload.loads(inProject: ids.project, from: day("2026-01-05"), days: 7)
                .first { $0.person.id == ada.id })
        }

        #expect(try load().isOver(days: 7) == false)

        try workload.setCapacity(40, unit: .hours, period: .week, for: ada.id)
        #expect(try load().isOver(days: 7))
    }

    /// A daily figure is multiplied by five rather than seven: capacity is
    /// working days, and a week-long window is five of them.
    @Test("A daily capacity is five days, not seven")
    func dailyCapacityIsWorkingDays() {
        let person = Person(
            id: "p", name: "Ada", capacityAmount: 6, capacityUnit: .hours,
            capacityPeriod: .day, sortOrder: 1, createdAt: .now
        )
        #expect(person.weeklyCapacity == 30)
    }
}
