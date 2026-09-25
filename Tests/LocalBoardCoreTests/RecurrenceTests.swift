import Foundation
import Testing
@testable import LocalBoardCore

/// Dates are where quiet bugs live, so the calendar is fixed rather than the
/// tester's: a suite that passes in London and fails in Auckland has tested
/// the machine, not the rule.
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

private func text(_ date: Date?) -> String {
    guard let date else { return "never" }
    let parts = utc.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
}

@Suite("When a card comes back")
struct RecurrenceTests {

    @Test("Every day, and every third day")
    func daily() {
        let daily = RecurrenceRule(frequency: .daily)
        #expect(text(daily.next(after: day("2026-01-01"), calendar: utc)) == "2026-01-02")

        let thirdDay = RecurrenceRule(frequency: .daily, interval: 3)
        #expect(text(thirdDay.next(after: day("2026-01-01"), calendar: utc)) == "2026-01-04")
    }

    @Test("Every week keeps the weekday it started on")
    func weeklyWithoutDays() {
        let weekly = RecurrenceRule(frequency: .weekly)
        #expect(text(weekly.next(after: day("2026-01-05"), calendar: utc)) == "2026-01-12")

        let fortnightly = RecurrenceRule(frequency: .weekly, interval: 2)
        #expect(text(fortnightly.next(after: day("2026-01-05"), calendar: utc)) == "2026-01-19")
    }

    /// Two chosen days mean two occurrences a week, not one — the common case
    /// a weekly rule gets wrong by treating the set as "pick one".
    @Test("Mondays and Thursdays gives both days")
    func weeklyWithDays() {
        // 2 = Monday, 5 = Thursday.
        let rule = RecurrenceRule(frequency: .weekly, weekdays: [2, 5])

        #expect(text(rule.next(after: day("2026-01-05"), calendar: utc)) == "2026-01-08")
        // Past the last chosen day of the week, it comes round to the first.
        #expect(text(rule.next(after: day("2026-01-08"), calendar: utc)) == "2026-01-12")
    }

    /// Every other Monday is not "every Monday, sometimes" — the week between
    /// is skipped, which is why the interval is applied before the weekday.
    @Test("Every other Monday skips the week between")
    func fortnightlyOnAWeekday() {
        let rule = RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [2])
        #expect(text(rule.next(after: day("2026-01-05"), calendar: utc)) == "2026-01-19")
    }

    @Test("A day of the month")
    func monthlyByDay() {
        let rule = RecurrenceRule(frequency: .monthly, monthDay: 15)
        #expect(text(rule.next(after: day("2026-01-15"), calendar: utc)) == "2026-02-15")
    }

    /// The 31st in February is the 28th, not the 3rd of March. Spilling into
    /// the next month would move a monthly card off the month it belongs to.
    @Test("A month too short gets its last day rather than the next month")
    func monthlyClampsToShortMonths() {
        let rule = RecurrenceRule(frequency: .monthly, monthDay: 31)
        #expect(text(rule.next(after: day("2026-01-31"), calendar: utc)) == "2026-02-28")
        // And the month after is the 31st again — the clamp is not sticky.
        #expect(text(rule.next(after: day("2026-02-28"), calendar: utc)) == "2026-03-31")
    }

    /// The brief's own example.
    @Test("Every 2nd Tuesday")
    func secondTuesday() {
        // 3 = Tuesday.
        let rule = RecurrenceRule(frequency: .monthly, weekdays: [3], weekOfMonth: 2)

        #expect(text(rule.next(after: day("2026-01-13"), calendar: utc)) == "2026-02-10")
        #expect(text(rule.next(after: day("2026-02-10"), calendar: utc)) == "2026-03-10")
        #expect(rule.summary == "The 2nd Tuesday of every month")
    }

    /// "Last" is its own case rather than "the fifth": a month with four
    /// Fridays would otherwise answer with a date in the month after.
    @Test("The last Friday of the month")
    func lastFriday() {
        // 6 = Friday.
        let rule = RecurrenceRule(frequency: .monthly, weekdays: [6], weekOfMonth: -1)

        #expect(text(rule.next(after: day("2026-01-30"), calendar: utc)) == "2026-02-27")
        #expect(rule.summary == "The last Friday of every month")
    }

    @Test("A fifth weekday in a month that has four is the fourth")
    func fifthFallsBackToLast() {
        let rule = RecurrenceRule(frequency: .monthly, weekdays: [3], weekOfMonth: 5)
        // February 2026 has four Tuesdays: the 3rd, 10th, 17th and 24th.
        #expect(text(rule.next(after: day("2026-01-06"), calendar: utc)) == "2026-02-24")
    }

    @Test("Every year")
    func yearly() {
        let rule = RecurrenceRule(frequency: .yearly)
        #expect(text(rule.next(after: day("2026-03-01"), calendar: utc)) == "2027-03-01")
    }

    /// A rule that answered with the date it was given would recur a card onto
    /// its own due date forever.
    @Test("The next one is always after the one asked about")
    func strictlyAfter() {
        for rule in [
            RecurrenceRule(frequency: .daily),
            RecurrenceRule(frequency: .weekly, weekdays: [2, 5]),
            RecurrenceRule(frequency: .monthly, monthDay: 15),
            RecurrenceRule(frequency: .monthly, weekdays: [3], weekOfMonth: 2),
            RecurrenceRule(frequency: .yearly),
        ] {
            let from = day("2026-01-15")
            let next = rule.next(after: from, calendar: utc)
            #expect(next != nil)
            #expect(next! > from, "\(rule.summary) answered with a date that is not later")
        }
    }

    @Test("A rule stops when it is told to")
    func ends() {
        let rule = RecurrenceRule(frequency: .daily, endsAt: day("2026-01-03"))

        #expect(text(rule.next(after: day("2026-01-01"), calendar: utc)) == "2026-01-02")
        #expect(rule.next(after: day("2026-01-03"), calendar: utc) == nil)
    }

    /// A rule repeating every zero weeks describes nothing, and left alone it
    /// would loop forever asking for the next one.
    @Test("An interval below one is read as one")
    func intervalFloor() {
        #expect(RecurrenceRule(frequency: .daily, interval: 0).interval == 1)
        #expect(RecurrenceRule(frequency: .daily, interval: -4).interval == 1)
    }

    @Test("Weekdays survive being written down and read back")
    func weekdayList() {
        let rule = RecurrenceRule(frequency: .weekly, weekdays: [5, 2])
        #expect(rule.weekdayList == "2,5")
        #expect(RecurrenceRule.weekdays(from: rule.weekdayList) == [2, 5])
        // Nonsense in the column does not become a nonsense rule.
        #expect(RecurrenceRule.weekdays(from: "0,9,x,3") == [3])
    }

    @Test("The rule reads back as a sentence")
    func summaries() {
        #expect(RecurrenceRule(frequency: .daily).summary == "Every day")
        #expect(RecurrenceRule(frequency: .daily, interval: 3).summary == "Every 3 days")
        #expect(RecurrenceRule(frequency: .weekly, interval: 2).summary == "Every 2 weeks")
        #expect(RecurrenceRule(frequency: .monthly, monthDay: 15).summary == "Day 15 of every month")
        #expect(RecurrenceRule(frequency: .yearly).summary == "Every year")
    }
}
