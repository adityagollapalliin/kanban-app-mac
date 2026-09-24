import Foundation
import Testing
@testable import LocalBoardCore

@Suite("Query parser")
struct TaskQueryParserTests {

    private func parse(_ source: String) throws -> TaskFilter {
        try TaskQueryParser.parse(source)
    }

    // MARK: - Shape

    @Test("An empty query matches everything")
    func empty() throws {
        #expect(try parse("") == .all)
        #expect(try parse("    ") == .all)
    }

    @Test("A comparison parses to its field, operator and value")
    func comparison() throws {
        #expect(try parse("due < +7d") == .comparison(.due, .lessThan, .date(.daysFromToday(7))))
        #expect(try parse("priority >= high") == .comparison(.priority, .atLeast, .priority(.high)))
        #expect(try parse("type != bug") == .comparison(.type, .notEquals, .type(.bug)))
    }

    @Test("A colon means equals, so type:bug and type = bug agree")
    func colonIsEquals() throws {
        #expect(try parse("type:bug") == parse("type = bug"))
        #expect(try parse("priority:highest") == .comparison(.priority, .equals, .priority(.highest)))
    }

    @Test("Flags parse from is:")
    func flags() throws {
        #expect(try parse("is:done") == .flag(.done))
        #expect(try parse("is:overdue") == .flag(.overdue))
        #expect(try parse("is:UNASSIGNED") == .flag(.unassigned))
    }

    /// Terms sitting next to each other mean all of them, which is what people
    /// expect from a search box.
    @Test("Adjacent terms are an implicit AND")
    func implicitAnd() throws {
        #expect(try parse("is:open is:overdue") == .and([.flag(.open), .flag(.overdue)]))
        #expect(try parse("is:open and is:overdue") == parse("is:open is:overdue"))
    }

    @Test("or and not are honoured")
    func orAndNot() throws {
        #expect(try parse("is:done or is:trashed") == .or([.flag(.done), .flag(.trashed)]))
        #expect(try parse("not is:done") == .not(.flag(.done)))
    }

    @Test("Parentheses group against the default precedence")
    func parentheses() throws {
        let grouped = try parse("(is:done or is:trashed) is:overdue")
        #expect(grouped == .and([.or([.flag(.done), .flag(.trashed)]), .flag(.overdue)]))
    }

    @Test("or binds looser than adjacency")
    func precedence() throws {
        let filter = try parse("is:open is:overdue or is:done")
        #expect(filter == .or([.and([.flag(.open), .flag(.overdue)]), .flag(.done)]))
    }

    // MARK: - Free text

    @Test("Words that are not fields are text to search for")
    func bareText() throws {
        #expect(try parse("parser") == .text("parser"))
        #expect(try parse("\"the whole phrase\"") == .text("the whole phrase"))
    }

    /// `status` alone is someone searching for the word, not a broken filter.
    @Test("A field name with no operator is just a word")
    func fieldNameWithoutOperator() throws {
        #expect(try parse("status") == .text("status"))
    }

    @Test("An unterminated quote still parses, because search fields are read while being typed")
    func unterminatedQuote() throws {
        #expect(try parse("\"half a phra") == .text("half a phra"))
    }

    // MARK: - Dates

    @Test("Dates parse in every accepted spelling")
    func dates() throws {
        #expect(try parse("due = today") == .comparison(.due, .equals, .date(.daysFromToday(0))))
        #expect(try parse("due = tomorrow") == .comparison(.due, .equals, .date(.daysFromToday(1))))
        #expect(try parse("due = yesterday") == .comparison(.due, .equals, .date(.daysFromToday(-1))))
        #expect(try parse("due < -2w") == .comparison(.due, .lessThan, .date(.daysFromToday(-14))))
        #expect(try parse("created > 2026-10-01") == .comparison(.created, .greaterThan, .date(.absolute(year: 2026, month: 10, day: 1))))
    }

    @Test("none asks whether the field is set at all")
    func noneValue() throws {
        #expect(try parse("due = none") == .comparison(.due, .equals, .none))
        #expect(try parse("assignee != none") == .comparison(.assignee, .notEquals, .none))
    }

    /// The point of keeping dates relative: the same query means something
    /// different tomorrow, which is what a saved view needs.
    @Test("A relative date resolves against the day it is asked")
    func relativeDatesResolve() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13 UTC

        let today = RelativeDate.daysFromToday(0).resolve(now: noon, calendar: calendar)
        let inAWeek = RelativeDate.daysFromToday(7).resolve(now: noon, calendar: calendar)

        #expect(inAWeek.timeIntervalSince(today) == 7 * 86_400)
        #expect(calendar.startOfDay(for: today) == today)
    }

    // MARK: - What the user gets wrong

    @Test("A comparison with nothing to compare against is reported")
    func missingValue() {
        #expect(throws: QueryError.self) { try parse("due <") }
    }

    @Test("A value of the wrong kind names the kinds that would work")
    func wrongValueKind() throws {
        let error = try #require(throws: QueryError.self) { try parse("due < banana") }
        #expect(error.message.contains("2026-10-01"))

        let priority = try #require(throws: QueryError.self) { try parse("priority = urgentish") }
        #expect(priority.message.contains("lowest"))
    }

    @Test("An unknown flag lists the ones that exist")
    func unknownFlag() throws {
        let error = try #require(throws: QueryError.self) { try parse("is:sideways") }
        #expect(error.message.contains("done"))
    }

    @Test("Unbalanced parentheses are reported, not guessed at")
    func unbalancedParentheses() {
        #expect(throws: QueryError.self) { try parse("(is:done") }
        #expect(throws: QueryError.self) { try parse("is:done)") }
    }

    @Test("An operator with no field in front of it is reported")
    func danglingOperator() {
        #expect(throws: QueryError.self) { try parse("< +7d") }
    }
}
