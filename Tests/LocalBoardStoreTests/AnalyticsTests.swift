import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("Analytics from the history")
struct AnalyticsTests {

    /// A board with one card walked across it, a day at a time.
    private func walkedBoard() throws -> (
        database: Database, clock: StoppedClock,
        ids: (workspace: String, project: String, board: String, toDo: String, inProgress: String, done: String),
        task: BoardTask
    ) {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Walked")
        clock.advance(days: 2)
        try tasks.move(task.id, toStatus: ids.inProgress)
        clock.advance(days: 3)
        try tasks.move(task.id, toStatus: ids.done)

        return (database, clock, ids, task)
    }

    @Test("Cumulative flow says where every card stood at the end of each day")
    func cumulativeFlow() throws {
        let board = try walkedBoard()
        let analytics = AnalyticsRepository(database: board.database, clock: board.clock)

        // Six days: the day it was made, through to today.
        let points = try analytics.cumulativeFlow(inProject: board.ids.project, days: 6)
        #expect(points.count == 6)

        // The card is somewhere on every single day — it never disappears
        // between columns, which is the failure mode a replay invites.
        #expect(points.allSatisfy { $0.total == 1 })
        #expect(points[0].toDo == 1)
        #expect(points[3].inProgress == 1)
        #expect(points.last?.done == 1)
    }

    /// The bug this guards against: starting the replay at the window's edge
    /// would show a team's whole backlog as created on the chart's first day.
    @Test("Work older than the window is counted from the first day")
    func historyBeforeTheWindowStillCounts() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)

        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Ancient")
        clock.advance(days: 90)

        let points = try AnalyticsRepository(database: database, clock: clock)
            .cumulativeFlow(inProject: ids.project, days: 7)

        #expect(points.first?.toDo == 1)
        #expect(points.count == 7)
    }

    @Test("Cycle time runs from starting work, lead time from creation")
    func controlChart() throws {
        let board = try walkedBoard()
        let analytics = AnalyticsRepository(database: board.database, clock: board.clock)

        let points = try analytics.controlChart(inProject: board.ids.project, days: 30)
        let point = try #require(points.first)

        // Three days in progress; five days since it was asked for.
        #expect(abs(point.cycleTime - 3) < 0.001)
        #expect(abs(point.leadTime - 5) < 0.001)
    }

    /// A card sent back and finished later finished later. Recording the first
    /// arrival in done would report a cycle time the work never had.
    @Test("A card moved back out of done is not finished until it returns")
    func reworkDelaysCompletion() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)

        let task = try tasks.create(inProject: ids.project, statusID: ids.inProgress, title: "Rework")
        clock.advance(days: 1)
        try tasks.move(task.id, toStatus: ids.done)
        clock.advance(days: 1)
        try tasks.move(task.id, toStatus: ids.toDo)
        clock.advance(days: 4)
        try tasks.move(task.id, toStatus: ids.done)

        let points = try AnalyticsRepository(database: database, clock: clock)
            .controlChart(inProject: ids.project, days: 30)
        let point = try #require(points.first)

        #expect(abs(point.cycleTime - 6) < 0.001)
    }

    @Test("An unfinished card is not on the control chart at all")
    func openWorkIsNotPlotted() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)

        try tasks.create(inProject: ids.project, statusID: ids.inProgress, title: "Still going")

        let points = try AnalyticsRepository(database: database, clock: clock)
            .controlChart(inProject: ids.project, days: 30)
        #expect(points.isEmpty)
    }

    /// The whole reason a burnup beats a burndown: a release that slipped
    /// because it grew looks nothing like one that slipped because it stalled.
    @Test("A burnup's scope line rises as work is added")
    func burnupScopeMoves() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)

        let first = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Planned")
        clock.advance(days: 3)
        let late = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Added later")
        clock.advance(days: 1)
        try tasks.move(first.id, toStatus: ids.done)
        clock.advance(days: 1)

        let points = try AnalyticsRepository(database: database, clock: clock)
            .burnup(taskIDs: [first.id, late.id], days: 6)

        #expect(points.first?.scope == 1)
        #expect(points.last?.scope == 2)
        #expect(points.last?.done == 1)
    }

    @Test("The rolling average follows the recent cards, not all of them")
    func rollingAverage() {
        let points = (0..<10).map { index in
            CycleTimePoint(
                taskID: "t\(index)",
                completedAt: Date(timeIntervalSince1970: Double(index) * 86_400),
                cycleTime: index < 5 ? 10 : 2,
                leadTime: 0
            )
        }

        let averages = points.rollingAverage(window: 5, using: \.cycleTime)
        #expect(averages[0] == 10)
        // By the last point the window holds only the recent, quicker cards.
        #expect(averages[9] == 2)
    }

    @Test("Standard deviation of an unvarying series is zero")
    func standardDeviation() {
        let steady = (0..<4).map {
            CycleTimePoint(taskID: "\($0)", completedAt: .now, cycleTime: 3, leadTime: 3)
        }
        #expect(steady.standardDeviation(using: \.cycleTime) == 0)

        let varied = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0].enumerated().map {
            CycleTimePoint(taskID: "\($0.offset)", completedAt: .now, cycleTime: $0.element, leadTime: 0)
        }
        #expect(abs(varied.standardDeviation(using: \.cycleTime) - 2) < 0.001)
    }
}

@Suite("The query language reaches the new fields")
struct ExtendedQueryTests {

    @Test("is:flagged finds blocked work")
    func flagged() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        let stuck = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Stuck")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Fine")
        try tasks.setFlag(true, reason: "Waiting on legal", for: stuck.id)

        #expect(try tasks.tasks(matching: "is:flagged", inProject: ids.project).count == 1)
        // And the reason itself is searchable, which is what makes writing one
        // worth the trouble.
        #expect(try tasks.tasks(matching: "flag = legal", inProject: ids.project).count == 1)
        #expect(try tasks.tasks(matching: "flag = database", inProject: ids.project).isEmpty)
    }

    @Test("is:mine answers against the person chosen in Settings")
    func mine() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let people = PersonRepository(database: database)
        let settings = AppSettings(database: database)

        let me = try people.create(name: "Ada")
        let them = try people.create(name: "Grace")
        let mine = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Mine")
        let theirs = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Theirs")
        try tasks.setAssignee(me.id, for: mine.id)
        try tasks.setAssignee(them.id, for: theirs.id)

        // Nobody chosen yet: an unanswered question has no answers.
        #expect(try tasks.tasks(matching: "is:mine", inProject: ids.project).isEmpty)

        try settings.setCurrentPerson(me.id)
        let found = try tasks.tasks(matching: "is:mine", inProject: ids.project)
        #expect(found.map(\.title) == ["Mine"])
    }

    @Test("A deleted person is nobody, so is:mine stops matching")
    func mineAfterDeletion() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let people = PersonRepository(database: database)
        let settings = AppSettings(database: database)

        let me = try people.create(name: "Ada")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Mine")
        try tasks.setAssignee(me.id, for: task.id)
        try settings.setCurrentPerson(me.id)
        #expect(try tasks.tasks(matching: "is:mine", inProject: ids.project).count == 1)

        try people.delete(me.id)
        #expect(try settings.currentPersonID == nil)
        #expect(try tasks.tasks(matching: "is:mine", inProject: ids.project).isEmpty)
    }

    @Test("key finds a card by its printed tag")
    func key() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "First")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Second")

        #expect(try tasks.tasks(matching: "key = WORK-2", inProject: ids.project).map(\.title) == ["Second"])
        #expect(try tasks.tasks(matching: "key = 1", inProject: ids.project).map(\.title) == ["First"])
        // A key from another project is not this project's card.
        #expect(try tasks.tasks(matching: "key = DOCS-1", inProject: ids.project).isEmpty)
    }

    /// An unestimated card is not a zero-point card, and a numeric filter must
    /// not quietly treat it as the smallest one.
    @Test("points leaves unestimated cards out of the comparison")
    func points() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        let sized = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Sized")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Unsized")
        try tasks.setEstimate(5, for: sized.id)

        #expect(try tasks.tasks(matching: "points >= 3", inProject: ids.project).map(\.title) == ["Sized"])
        #expect(try tasks.tasks(matching: "points < 3", inProject: ids.project).isEmpty)
    }

    @Test("days asks how long a card has sat where it is")
    func daysInColumn() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)

        let stale = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Stale")
        clock.advance(days: 6)
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Fresh")

        let found = try tasks.tasks(matching: "days >= 5", inProject: ids.project)
        #expect(found.map(\.id) == [stale.id])
        #expect(try tasks.tasks(matching: "days < 5", inProject: ids.project).map(\.title) == ["Fresh"])
    }

    @Test("version and is:released follow the release")
    func versions() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let versions = VersionRepository(database: database)

        let release = try versions.create(inProject: ids.project, name: "1.0")
        let shipped = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Shipped")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Unscheduled")
        try tasks.setVersion(release.id, for: shipped.id)

        #expect(try tasks.tasks(matching: "version = 1.0", inProject: ids.project).count == 1)
        #expect(try tasks.tasks(matching: "is:released", inProject: ids.project).isEmpty)

        try versions.setReleased(true, for: release.id)
        #expect(try tasks.tasks(matching: "is:released", inProject: ids.project).count == 1)
        #expect(try tasks.tasks(matching: "version = none", inProject: ids.project).count == 1)
    }
}
