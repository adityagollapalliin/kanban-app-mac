import Foundation
import Testing
@testable import LocalBoardCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2   // Monday, so the week has a fixed shape here.
    return calendar
}()

private func at(_ text: String) -> Date {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    let hour = parts.count > 3 ? parts[3] : 0
    return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
}

private func entry(
    _ id: String,
    task: String = "t1",
    person: String? = "p1",
    minutes: Int,
    on day: String,
    billable: Bool = false
) -> WorkLogEntry {
    WorkLogEntry(
        id: id, taskID: task, personID: person, minutes: minutes,
        workedOn: at(day), billable: billable, createdAt: at(day)
    )
}

@Suite("Reading what somebody typed into a timesheet cell")
struct DurationParsingTests {

    @Test("The ways an hour and a half gets typed")
    func ninetyMinutes() {
        for typed in ["1:30", "1.5", "90m", "1h30", "1h 30m", "90"] {
            #expect(DurationFormat.minutes(from: typed) == 90, "\(typed) should be 90 minutes")
        }
    }

    @Test("A bare number is hours with a point and minutes without")
    func bareNumbers() {
        // Which is how each is habitually typed: nobody means thirty hours by
        // "30", and nobody means half a minute by "0.5".
        #expect(DurationFormat.minutes(from: "30") == 30)
        #expect(DurationFormat.minutes(from: "0.5") == 30)
        #expect(DurationFormat.minutes(from: "2") == 2)
        #expect(DurationFormat.minutes(from: "2.0") == 120)
    }

    @Test("Whole hours, written every way")
    func wholeHours() {
        #expect(DurationFormat.minutes(from: "2h") == 120)
        #expect(DurationFormat.minutes(from: "2:00") == 120)
        #expect(DurationFormat.minutes(from: "2.0") == 120)
    }

    @Test("Nothing typed is nothing, and rubbish is refused")
    func refusals() {
        #expect(DurationFormat.minutes(from: "") == nil)
        #expect(DurationFormat.minutes(from: "  ") == nil)
        #expect(DurationFormat.minutes(from: "abc") == nil)
        #expect(DurationFormat.minutes(from: "1:xy") == nil)
    }

    @Test("Minutes read back the way a timesheet shows them")
    func formatting() {
        #expect(DurationFormat.clock(90) == "1:30")
        #expect(DurationFormat.clock(60) == "1:00")
        #expect(DurationFormat.clock(5) == "0:05")
        #expect(DurationFormat.short(90) == "1h 30m")
        #expect(DurationFormat.short(45) == "45m")
        #expect(DurationFormat.short(120) == "2h")
    }
}

@Suite("The week a timesheet covers")
struct TimesheetWeekTests {

    @Test("Seven days, starting on the day the calendar starts on")
    func sevenDays() {
        let week = TimesheetWeek(containing: at("2026-06-17"), calendar: utc)  // a Wednesday
        #expect(week.days.count == 7)
        #expect(week.days.first == at("2026-06-15"))   // the Monday
        #expect(week.days.last == at("2026-06-21"))
        #expect(week.end == at("2026-06-22"))
    }

    @Test("A day knows which column it falls in, and which week it is not in")
    func indexing() {
        let week = TimesheetWeek(containing: at("2026-06-17"), calendar: utc)
        #expect(week.index(of: at("2026-06-15-09")) == 0)
        #expect(week.index(of: at("2026-06-17-23")) == 2)
        #expect(week.index(of: at("2026-06-22")) == nil)
        #expect(week.contains(at("2026-06-21-23")))
        #expect(!week.contains(at("2026-06-22")))
    }

    @Test("Stepping back and forward lands on whole weeks")
    func shifting() {
        let week = TimesheetWeek(containing: at("2026-06-17"), calendar: utc)
        #expect(week.shifted(by: -1).start == at("2026-06-08"))
        #expect(week.shifted(by: 1).start == at("2026-06-22"))
    }
}

@Suite("Building the timesheet grid")
struct TimesheetTests {

    private let week = TimesheetWeek(containing: at("2026-06-17"), calendar: utc)

    @Test("Entries land in the right day, and several on a day add up")
    func grid() {
        let sheet = Timesheet.build(
            week: week,
            entries: [
                entry("1", minutes: 60, on: "2026-06-15"),
                entry("2", minutes: 30, on: "2026-06-15"),
                entry("3", minutes: 45, on: "2026-06-18"),
            ],
            titles: ["t1": "Write it down"],
            keys: ["t1": "WORK-1"]
        )

        #expect(sheet.rows.count == 1)
        #expect(sheet.rows[0].minutes == [90, 0, 0, 45, 0, 0, 0])
        #expect(sheet.rows[0].total == 135)
        #expect(sheet.rows[0].title == "Write it down")
        #expect(sheet.rows[0].entryIDs[0].sorted() == ["1", "2"])
    }

    @Test("A card and a person together make one line")
    func rowsPerCardAndPerson() {
        let sheet = Timesheet.build(
            week: week,
            entries: [
                entry("1", task: "t1", person: "p1", minutes: 60, on: "2026-06-15"),
                entry("2", task: "t1", person: "p2", minutes: 30, on: "2026-06-15"),
                entry("3", task: "t2", person: "p1", minutes: 30, on: "2026-06-15"),
            ],
            titles: [:], keys: [:]
        )
        #expect(sheet.rows.count == 3)
        #expect(sheet.total == 120)
    }

    @Test("Work outside the week is left out rather than moved into it")
    func outsideTheWeek() {
        // A timesheet that quietly shifted somebody's hours would be worse
        // than one that shows a day short.
        let sheet = Timesheet.build(
            week: week,
            entries: [
                entry("1", minutes: 60, on: "2026-06-15"),
                entry("2", minutes: 999, on: "2026-06-30"),
            ],
            titles: [:], keys: [:]
        )
        #expect(sheet.total == 60)
    }

    @Test("Billable minutes are counted separately, not instead")
    func billable() {
        let sheet = Timesheet.build(
            week: week,
            entries: [
                entry("1", minutes: 60, on: "2026-06-15", billable: true),
                entry("2", minutes: 30, on: "2026-06-15", billable: false),
            ],
            titles: [:], keys: [:]
        )
        #expect(sheet.total == 90)
        #expect(sheet.billableTotal == 60)
        #expect(sheet.dailyTotals[0] == 90)
        #expect(sheet.dailyBillableTotals[0] == 60)
    }

    @Test("A card nobody named still gets a line")
    func missingTitle() {
        let sheet = Timesheet.build(
            week: week,
            entries: [entry("1", minutes: 60, on: "2026-06-15")],
            titles: [:], keys: [:]
        )
        #expect(sheet.rows[0].title == "Untitled")
        #expect(sheet.rows[0].cardKey == "")
    }

    @Test("A week with nothing logged is empty rather than missing")
    func emptyWeek() {
        let sheet = Timesheet.build(week: week, entries: [], titles: [:], keys: [:])
        #expect(sheet.rows.isEmpty)
        #expect(sheet.dailyTotals == [0, 0, 0, 0, 0, 0, 0])
        #expect(sheet.total == 0)
    }
}

@Suite("Where a card's time went")
struct TimeInStatusTests {

    private func change(_ to: String, _ day: String, task: String = "t1", from: String? = nil) -> StatusChangeRecord {
        StatusChangeRecord(taskID: task, fromStatusID: from, toStatusID: to, at: at(day))
    }

    @Test("Each stretch is counted up to the next move")
    func stretches() {
        let report = TimeInStatusReport.forTask(
            [change("todo", "2026-06-01"), change("doing", "2026-06-03"), change("done", "2026-06-08")],
            now: at("2026-06-10")
        )
        #expect(report.count == 3)
        #expect(report[0].days == 2)
        #expect(report[1].days == 5)
        // The stretch it is in now runs up to now, which is why the figure
        // moves between two readings with nothing having changed.
        #expect(report[2].days == 2)
    }

    @Test("Coming back for rework counts as a second visit, not one long stay")
    func revisits() {
        let report = TimeInStatusReport.forTask(
            [
                change("doing", "2026-06-01"),
                change("review", "2026-06-02"),
                change("doing", "2026-06-03"),
                change("review", "2026-06-05"),
            ],
            now: at("2026-06-06")
        )
        let doing = report.first { $0.statusID == "doing" }
        let review = report.first { $0.statusID == "review" }
        #expect(doing?.visits == 2)
        #expect(doing?.days == 3)      // one day, then two
        #expect(review?.visits == 2)
        #expect(review?.days == 2)     // one day, then one up to now
    }

    @Test("History written out of order cannot produce a negative stretch")
    func unordered() {
        // An import or a clock that went backwards must not make a card read
        // as having spent minus four days somewhere.
        let report = TimeInStatusReport.forTask(
            [change("done", "2026-06-08"), change("todo", "2026-06-01")],
            now: at("2026-06-10")
        )
        #expect(report.allSatisfy { $0.seconds >= 0 })
        #expect(report.first?.statusID == "todo")
    }

    @Test("A card that has never moved has no history to read")
    func noHistory() {
        #expect(TimeInStatusReport.forTask([], now: at("2026-06-10")).isEmpty)
    }

    @Test("A change dated in the future does not run backwards")
    func futureChange() {
        let report = TimeInStatusReport.forTask(
            [change("todo", "2026-07-01")], now: at("2026-06-10")
        )
        #expect(report[0].seconds == 0)
    }

    @Test("Across cards, the average divides by the cards that were there")
    func acrossCards() throws {
        // Two cards in review, one for a day and one for three. The average is
        // two days, not two thirds of a day across the three cards that exist.
        let summaries = TimeInStatusReport.across(
            [
                change("review", "2026-06-01", task: "a"),
                change("done", "2026-06-02", task: "a"),
                change("review", "2026-06-01", task: "b"),
                change("done", "2026-06-04", task: "b"),
                change("todo", "2026-06-01", task: "c"),
            ],
            now: at("2026-06-05")
        )

        let review = try #require(summaries["review"])
        #expect(review.taskCount == 2)
        #expect(review.totalSeconds == 4 * 86_400)
        #expect(review.averageSeconds == 2 * 86_400)
        #expect(review.longestSeconds == 3 * 86_400)
    }

    @Test("How a stretch reads, from minutes to days")
    func wording() {
        #expect(TimeInStatus(statusID: "s", seconds: 1_800, visits: 1).description == "30m")
        #expect(TimeInStatus(statusID: "s", seconds: 5_400, visits: 1).description == "1.5h")
        #expect(TimeInStatus(statusID: "s", seconds: 3 * 86_400, visits: 1).description == "3.0 days")
    }
}
