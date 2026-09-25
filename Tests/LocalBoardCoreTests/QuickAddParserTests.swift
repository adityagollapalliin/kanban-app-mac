import Foundation
import Testing
@testable import LocalBoardCore

/// A fixed calendar and a fixed "now", so the suite tests the parser rather
/// than the machine it runs on. Thursday 15 January 2026, mid-morning.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_GB")
    calendar.firstWeekday = 1
    return calendar
}()

private let now = calendar.date(
    from: DateComponents(year: 2026, month: 1, day: 15, hour: 10, minute: 0)
)!

private func parse(_ text: String) -> QuickAddResult {
    QuickAddParser.parse(text, now: now, calendar: calendar)
}

private func describe(_ date: Date?) -> String {
    guard let date else { return "none" }
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(format: "%04d-%02d-%02d %02d:%02d",
                  parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!)
}

@Suite("Typing a card in one line")
struct QuickAddParserTests {

    /// The brief's own example.
    @Test("Fix login bug tomorrow 3pm !high #backend @Aditya")
    func theWholeSentence() {
        let result = parse("Fix login bug tomorrow 3pm !high #backend @Aditya")

        #expect(result.title == "Fix login bug")
        #expect(describe(result.dueDate) == "2026-01-16 15:00")
        #expect(result.hasTime)
        #expect(result.priority == .high)
        #expect(result.labels == ["backend"])
        #expect(result.assignees == ["Aditya"])
    }

    /// Quick-add must never refuse. The worst case is a card titled exactly
    /// what was typed.
    @Test("A plain line is a plain card")
    func plainLine() {
        let result = parse("Write the release notes")

        #expect(result.title == "Write the release notes")
        #expect(result.isBare)
    }

    /// A word the parser does not know stays in the title rather than
    /// vanishing into a field nobody looks at.
    @Test("What is not understood is left in the title")
    func unknownWordsSurvive() {
        let result = parse("Investigate the flaky socket test !low")

        #expect(result.title == "Investigate the flaky socket test")
        #expect(result.priority == .low)
    }

    @Test("Priorities by name and by number")
    func priorities() {
        #expect(parse("x !highest").priority == .highest)
        #expect(parse("x !urgent").priority == .highest)
        #expect(parse("x !high").priority == .high)
        #expect(parse("x !normal").priority == .normal)
        #expect(parse("x !low").priority == .low)
        #expect(parse("x !lowest").priority == .lowest)
        #expect(parse("x !5").priority == .highest)
        // Nonsense after the bang is not a priority, and stays in the title.
        #expect(parse("Ship it !!!").priority == nil)
        #expect(parse("Ship it !!!").title == "Ship it !!!")
    }

    @Test("Several tags and several people")
    func tagsAndPeople() {
        let result = parse("Pair on the parser #backend #urgent @Ada @Grace")

        #expect(result.title == "Pair on the parser")
        #expect(result.labels == ["backend", "urgent"])
        #expect(result.assignees == ["Ada", "Grace"])
    }

    @Test("Today, tomorrow and the day before")
    func relativeDays() {
        #expect(describe(parse("x today").dueDate) == "2026-01-15 00:00")
        #expect(describe(parse("x tomorrow").dueDate) == "2026-01-16 00:00")
        #expect(describe(parse("x yesterday").dueDate) == "2026-01-14 00:00")
    }

    /// Somebody typing a weekday means one that has not happened yet.
    @Test("A weekday means the next one")
    func weekdays() {
        // The 15th is a Thursday.
        #expect(describe(parse("x friday").dueDate) == "2026-01-16 00:00")
        #expect(describe(parse("x monday").dueDate) == "2026-01-19 00:00")
        // Today's own weekday means a week today, not this morning.
        #expect(describe(parse("x thursday").dueDate) == "2026-01-22 00:00")
    }

    @Test("Next Friday skips a week")
    func nextWeekday() {
        #expect(describe(parse("x next friday").dueDate) == "2026-01-23 00:00")
        #expect(describe(parse("x this friday").dueDate) == "2026-01-16 00:00")
    }

    @Test("Next week, next month, and in three days")
    func spans() {
        #expect(describe(parse("x next week").dueDate) == "2026-01-22 00:00")
        #expect(describe(parse("x next month").dueDate) == "2026-02-15 00:00")
        #expect(describe(parse("x in 3 days").dueDate) == "2026-01-18 00:00")
        #expect(describe(parse("x in 2 weeks").dueDate) == "2026-01-29 00:00")
    }

    @Test("Times, written the ways people write them")
    func times() {
        #expect(describe(parse("x 3pm").dueDate) == "2026-01-15 15:00")
        #expect(describe(parse("x 3:30pm").dueDate) == "2026-01-15 15:30")
        #expect(describe(parse("x 9am").dueDate) == "2026-01-15 09:00")
        #expect(describe(parse("x 15:30").dueDate) == "2026-01-15 15:30")
        // Noon and midnight are the two everybody gets wrong.
        #expect(describe(parse("x 12pm").dueDate) == "2026-01-15 12:00")
        #expect(describe(parse("x 12am").dueDate) == "2026-01-15 00:00")
    }

    /// "Fix issue 3" must not become a card due at three in the morning.
    @Test("A bare number is not a time")
    func bareNumbersAreNotTimes() {
        let result = parse("Fix issue 3")

        #expect(result.title == "Fix issue 3")
        #expect(result.dueDate == nil)
        #expect(result.hasTime == false)
    }

    /// Both orders are the same sentence, and only one of them working would
    /// be a parser that makes people think about parsing.
    @Test("A time before the day means the same as after it")
    func orderDoesNotMatter() {
        #expect(describe(parse("x 3pm tomorrow").dueDate) == "2026-01-16 15:00")
        #expect(describe(parse("x tomorrow 3pm").dueDate) == "2026-01-16 15:00")
    }

    /// A day with no time is a day, and a reminder has to know the difference
    /// between "due Thursday" and "due Thursday at nine".
    @Test("Whether a time was said is remembered")
    func hasTimeIsHonest() {
        #expect(parse("x tomorrow").hasTime == false)
        #expect(parse("x tomorrow 3pm").hasTime)
    }

    @Test("Numeric dates in the calendar's own order")
    func numericDates() {
        // A British calendar: day first.
        #expect(describe(parse("x 24/12").dueDate) == "2026-12-24 00:00")
        #expect(describe(parse("x 24/12/2027").dueDate) == "2027-12-24 00:00")
        #expect(describe(parse("x 2026-03-09").dueDate) == "2026-03-09 00:00")
        // Impossible dates are not dates; they stay in the title.
        #expect(parse("x 45/99").dueDate == nil)
    }

    /// A line of nothing but tokens still has to become something.
    @Test("A line with no words left keeps what was typed")
    func allTokens() {
        let result = parse("!high #backend @Ada")

        #expect(result.title == "!high #backend @Ada")
        #expect(result.priority == .high)
        #expect(result.labels == ["backend"])
    }

    @Test("Empty in, empty out")
    func empty() {
        #expect(parse("").title.isEmpty)
        #expect(parse("   ").title.isEmpty)
    }

    /// A lone `#` or `@` is punctuation somebody typed, not an empty tag.
    @Test("A bare hash or at sign is just text")
    func bareSigils() {
        let result = parse("Discuss # and @ in the parser")

        #expect(result.labels.isEmpty)
        #expect(result.assignees.isEmpty)
        #expect(result.title == "Discuss # and @ in the parser")
    }
}
