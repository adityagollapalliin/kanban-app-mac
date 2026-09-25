import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}()

private func at(_ text: String) -> Date {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    let hour = parts.count > 3 ? parts[3] : 12
    return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
}

private func fixture() throws -> (
    Database, StoppedClock,
    (workspace: String, project: String, board: String, toDo: String, inProgress: String, done: String)
) {
    let clock = StoppedClock(at("2026-06-17"))
    let database = try Database.inMemoryMigrated()
    return (database, clock, try database.seedBoardProject())
}

@Suite("The weekly timesheet")
struct TimesheetStoreTests {

    @Test("Hours logged in the week land on the right day")
    func readsTheWeek() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let details = CardDetailRepository(database: database, clock: clock)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Write it")
        try details.logWork(onTask: card.id, minutes: 60, workedOn: at("2026-06-15"))
        try details.logWork(onTask: card.id, minutes: 30, workedOn: at("2026-06-17"))
        // Last week, which this sheet is not about.
        try details.logWork(onTask: card.id, minutes: 999, workedOn: at("2026-06-08"))

        let time = TimeRepository(database: database, clock: clock, calendar: utc)
        let sheet = try time.timesheet(
            inProject: ids.project, week: TimesheetWeek(containing: at("2026-06-17"), calendar: utc)
        )

        #expect(sheet.rows.count == 1)
        #expect(sheet.rows[0].minutes == [60, 0, 30, 0, 0, 0, 0])
        #expect(sheet.rows[0].cardKey == "WORK-1")
        #expect(sheet.total == 90)
    }

    @Test("Typing more into a cell adds to it rather than replacing what is there")
    func addingToACell() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let details = CardDetailRepository(database: database, clock: clock)
        let time = TimeRepository(database: database, clock: clock, calendar: utc)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Write it")
        try details.logWork(onTask: card.id, minutes: 60, note: "Morning", workedOn: at("2026-06-15"))

        try time.setMinutes(90, onTask: card.id, day: at("2026-06-15"), personID: nil)

        // The note on the original entry is the part of a timesheet that is
        // worth anything a month later, so it has to survive the edit.
        let entries = try details.workLog(forTask: card.id)
        #expect(entries.reduce(0) { $0 + $1.minutes } == 90)
        #expect(entries.contains { $0.note == "Morning" })
    }

    @Test("Typing less takes it off the newest entry first")
    func reducingACell() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let details = CardDetailRepository(database: database, clock: clock)
        let time = TimeRepository(database: database, clock: clock, calendar: utc)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Write it")
        // Both in the same second, which is what a timer stopped and a
        // correction typed straight after actually looks like.
        try details.logWork(onTask: card.id, minutes: 60, note: "Morning", workedOn: at("2026-06-15"))
        try details.logWork(onTask: card.id, minutes: 30, note: "Afternoon", workedOn: at("2026-06-15"))

        try time.setMinutes(70, onTask: card.id, day: at("2026-06-15"), personID: nil)

        let entries = try details.workLog(forTask: card.id)
        #expect(entries.reduce(0) { $0 + $1.minutes } == 70)
        // The most recent one is the one most likely to be the mistake being
        // corrected, so it is the one that gives way.
        #expect(entries.first { $0.note == "Morning" }?.minutes == 60)
        #expect(entries.first { $0.note == "Afternoon" }?.minutes == 10)
    }

    @Test("Clearing a cell removes the day's entries for that card")
    func clearingACell() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let details = CardDetailRepository(database: database, clock: clock)
        let time = TimeRepository(database: database, clock: clock, calendar: utc)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Write it")
        try details.logWork(onTask: card.id, minutes: 60, workedOn: at("2026-06-15"))
        try details.logWork(onTask: card.id, minutes: 45, workedOn: at("2026-06-16"))

        try time.setMinutes(0, onTask: card.id, day: at("2026-06-15"), personID: nil)

        // Only that day: the rest of the week is somebody else's business.
        #expect(try details.totalMinutes(forTask: card.id) == 45)
    }

    @Test("Typing into an empty cell writes a new entry on that day")
    func fillingAnEmptyCell() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let time = TimeRepository(database: database, clock: clock, calendar: utc)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Write it")
        try time.setMinutes(45, onTask: card.id, day: at("2026-06-16"), personID: nil, billable: true)

        let sheet = try time.timesheet(
            inProject: ids.project, week: TimesheetWeek(containing: at("2026-06-17"), calendar: utc)
        )
        #expect(sheet.rows[0].minutes[1] == 45)
        #expect(sheet.billableTotal == 45)
    }

    @Test("Negative time is refused")
    func negativeTime() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let time = TimeRepository(database: database, clock: clock, calendar: utc)
        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Write it")

        #expect(throws: (any Error).self) {
            try time.setMinutes(-5, onTask: card.id, day: at("2026-06-16"), personID: nil)
        }
    }

    @Test("Hours logged before anyone was asked are not billable")
    func billableDefaultsToNo() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let details = CardDetailRepository(database: database, clock: clock)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Write it")
        let entry = try details.logWork(onTask: card.id, minutes: 60)
        #expect(!entry.billable)

        let time = TimeRepository(database: database, clock: clock, calendar: utc)
        try time.setBillable(true, for: entry.id)
        #expect(try details.workLog(forTask: card.id).first?.billable == true)
    }

    @Test("A whole card's hours can be marked billable at once")
    func billableByCard() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let details = CardDetailRepository(database: database, clock: clock)
        let time = TimeRepository(database: database, clock: clock, calendar: utc)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Write it")
        try details.logWork(onTask: card.id, minutes: 60)
        try details.logWork(onTask: card.id, minutes: 30)

        try time.setBillable(true, forTask: card.id)
        #expect(try details.workLog(forTask: card.id).allSatisfy(\.billable))
    }

    @Test("Totals can be asked for billable time alone")
    func billableTotals() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let details = CardDetailRepository(database: database, clock: clock)
        let time = TimeRepository(database: database, clock: clock, calendar: utc)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Write it")
        try details.logWork(onTask: card.id, minutes: 60, workedOn: at("2026-06-15"), billable: true)
        try details.logWork(onTask: card.id, minutes: 30, workedOn: at("2026-06-15"))

        let from = at("2026-06-01"), to = at("2026-07-01")
        #expect(try time.totalMinutes(inProject: ids.project, from: from, to: to) == 90)
        #expect(try time.totalMinutes(inProject: ids.project, from: from, to: to, billableOnly: true) == 60)
    }
}

@Suite("Time in status, from the history")
struct TimeInStatusStoreTests {

    @Test("A card's stretches come from its own status changes")
    func perCard() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Write it")
        clock.advance(days: 2)
        try tasks.move(card.id, toStatus: ids.inProgress)
        clock.advance(days: 3)
        try tasks.move(card.id, toStatus: ids.done)
        clock.advance(days: 1)

        let report = try TimeRepository(database: database, clock: clock, calendar: utc)
            .timeInStatus(forTask: card.id)

        #expect(report.count == 3)
        #expect(report[0].days == 2)
        #expect(report[1].days == 3)
        #expect(report[2].days == 1)
    }

    @Test("The project report reads in the board's own column order")
    func columnOrder() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "One")
        clock.advance(days: 1)
        try tasks.move(card.id, toStatus: ids.done)
        clock.advance(days: 1)

        let report = try TimeRepository(database: database, clock: clock, calendar: utc)
            .timeInStatus(inProject: ids.project)

        // Left to right, the way the board reads.
        #expect(report.map(\.statusID) == [ids.toDo, ids.done])
    }

    @Test("Work that was thrown away does not move the averages")
    func trashedCardsExcluded() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)

        let kept = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Kept")
        let binned = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Binned")
        clock.advance(days: 4)
        try tasks.setTrashed(true, for: binned.id)

        let report = try TimeRepository(database: database, clock: clock, calendar: utc)
            .timeInStatus(inProject: ids.project)

        #expect(report.first?.taskCount == 1)
        _ = kept
    }

    @Test("A project where nothing has moved has an empty report, not a crash")
    func nothingToReport() throws {
        let (database, clock, ids) = try fixture()
        let report = try TimeRepository(database: database, clock: clock, calendar: utc)
            .timeInStatus(inProject: ids.project)
        #expect(report.isEmpty)
    }
}
