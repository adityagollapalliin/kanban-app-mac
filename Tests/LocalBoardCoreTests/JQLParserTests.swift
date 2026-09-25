import Foundation
import Testing
@testable import LocalBoardCore

private func jql(_ source: String) throws -> ParsedQuery {
    try TaskQueryParser.parse(source, syntax: .jql)
}

private func simple(_ source: String) throws -> ParsedQuery {
    try TaskQueryParser.parse(source, syntax: .simple)
}

@Suite("The JQL grammar reads what the old one could not")
struct JQLParserTests {

    @Test("ORDER BY, with and without a direction")
    func ordering() throws {
        #expect(try jql("is:open ORDER BY due").order == [QueryOrder(field: .due)])
        #expect(try jql("is:open ORDER BY due DESC").order == [QueryOrder(field: .due, ascending: false)])
        #expect(try jql("ORDER BY priority DESC, due ASC").order == [
            QueryOrder(field: .priority, ascending: false),
            QueryOrder(field: .due, ascending: true),
        ])
    }

    @Test("A query with no ORDER BY asks for no particular order")
    func noOrdering() throws {
        #expect(try jql("is:open").order.isEmpty)
    }

    @Test("IN and NOT IN")
    func membership() throws {
        let parsed = try jql("priority IN (high, highest)")
        #expect(parsed.filter == .membership(
            .field(.priority), [.priority(.high), .priority(.highest)], negated: false
        ))

        let negated = try jql("type NOT IN (bug, story)")
        #expect(negated.filter == .membership(
            .field(.type), [.type(.bug), .type(.story)], negated: true
        ))
    }

    @Test("IS EMPTY and IS NOT EMPTY")
    func emptiness() throws {
        #expect(try jql("assignee IS EMPTY").filter == .emptiness(.field(.assignee), negated: false))
        #expect(try jql("due IS NOT EMPTY").filter == .emptiness(.field(.due), negated: true))
    }

    @Test("~ looks inside text")
    func contains() throws {
        #expect(try jql("title ~ login").filter == .contains(.field(.title), "login"))
        #expect(try jql("cf:Notes ~ urgent").filter == .contains(.custom("Notes"), "urgent"))
    }

    @Test("WAS asks about a card's past")
    func was() throws {
        let parsed = try jql("status WAS \"In Progress\"")
        #expect(parsed.filter == .history(HistoryClause(
            target: .field(.status), kind: .was, value: .text("In Progress")
        )))
    }

    @Test("CHANGED, with either end or both, and a window")
    func changed() throws {
        let both = try jql("status CHANGED FROM \"To Do\" TO \"Done\"")
        #expect(both.filter == .history(HistoryClause(
            target: .field(.status), kind: .changed,
            from: .text("To Do"), to: .text("Done")
        )))

        let during = try jql("status CHANGED TO \"Done\" DURING (-1w, today)")
        guard case .history(let clause) = during.filter else {
            Issue.record("Expected a history clause")
            return
        }
        #expect(clause.to == .text("Done"))
        #expect(clause.duringStart != nil && clause.duringEnd != nil)
    }

    @Test("Only status has a history to ask about")
    func historyIsStatusOnly() {
        // Nothing else has ever been recorded, and a query answered with
        // silence is worse than one that says it cannot be answered.
        #expect(throws: (any Error).self) { try jql("assignee WAS \"Ada\"") }
        #expect(throws: (any Error).self) { try jql("priority CHANGED TO high") }
    }

    @Test("The functions, and their offsets")
    func functions() throws {
        #expect(try jql("assignee = currentUser()").filter
                == .comparison(.assignee, .equals, .function(.currentUser)))
        #expect(try jql("sprint IN openSprints()").filter
                == .membership(.field(.sprint), [.function(.openSprints)], negated: false))
        #expect(try jql("version IN releasedVersions()").filter
                == .membership(.field(.version), [.function(.releasedVersions)], negated: false))
        #expect(try jql("key IN linkedIssues(WORK-12)").filter
                == .membership(.field(.key), [.function(.linkedIssues("WORK-12"))], negated: false))
    }

    @Test("A date function where a date is wanted becomes an ordinary date")
    func dateFunctionsFold() throws {
        // So that everything downstream keeps one path for dates.
        #expect(try jql("due >= startOfWeek()").filter
                == .comparison(.due, .atLeast, .date(.function(.startOfWeek(0)))))
        #expect(try jql("due < endOfMonth(1)").filter
                == .comparison(.due, .lessThan, .date(.function(.endOfMonth(1)))))
    }

    @Test("A function without its brackets is refused")
    func functionsNeedBrackets() {
        #expect(throws: (any Error).self) { try jql("assignee = currentUser") }
    }

    @Test("Bad JQL says what is wrong")
    func errors() {
        #expect(throws: (any Error).self) { try jql("priority IN high") }
        #expect(throws: (any Error).self) { try jql("priority IN ()") }
        #expect(throws: (any Error).self) { try jql("assignee IS") }
        #expect(throws: (any Error).self) { try jql("ORDER due") }
        #expect(throws: (any Error).self) { try jql("ORDER BY nonsense") }
        #expect(throws: (any Error).self) { try jql("status CHANGED TO \"Done\" DURING (-1w)") }
    }
}

@Suite("The two languages stay apart")
struct QuerySyntaxSeparationTests {

    /// The six strings that already meant something in the old language, and
    /// the whole reason a `syntax` column exists.
    private let collisions = [
        "ORDER BY due",
        "priority IN (high, highest)",
        "summary ~ login",
        "status WAS \"In Progress\"",
        "status CHANGED FROM \"To Do\" TO \"Done\"",
    ]

    @Test("In the old language they are still text searches, every one")
    func stillTextInSimple() throws {
        for source in collisions {
            let parsed = try simple(source)
            #expect(parsed.order.isEmpty, "`\(source)` must not acquire an ordering")

            // Every one of them is a run of words to search for, and nothing
            // else. This is the assertion that would fail if somebody let a
            // JQL production loose in the simple grammar.
            let onlyText = containsOnlyText(parsed.filter)
            #expect(onlyText, "`\(source)` stopped being a text search")
        }
    }

    @Test("In the new language they are operators")
    func operatorsInJQL() throws {
        #expect(try jql("ORDER BY due").order == [QueryOrder(field: .due)])
        #expect(!containsOnlyText(try jql("priority IN (high, highest)").filter))
        #expect(!containsOnlyText(try jql("status WAS \"In Progress\"").filter))
    }

    @Test("`~` is an ordinary character in the old language")
    func tildeIsTextInSimple() throws {
        // Tokenising it as an operator in both would change what a saved
        // filter containing it searches for.
        #expect(containsOnlyText(try simple("title~login").filter))
        #expect(!containsOnlyText(try jql("title ~ login").filter))
    }

    @Test("Everything the old language could say, the new one says the same way")
    func supersetHolds() throws {
        // The part of "strict superset" that *is* achievable: every construct
        // of the old grammar parses identically under the new one.
        let shared = [
            "is:open", "due < +7d", "priority >= high", "type = bug",
            "assignee = \"Ada Lovelace\"", "cf:Size >= 3", "is:done or is:trashed",
            "not is:done", "(is:done or is:trashed) is:overdue", "points > 3",
            "status = \"In Progress\"", "due = none", "is:mine", "updated >= -3d",
        ]
        for source in shared {
            #expect(
                try simple(source).filter == (try jql(source).filter),
                "`\(source)` reads differently in the two languages"
            )
        }
    }

    private func containsOnlyText(_ filter: TaskFilter) -> Bool {
        switch filter {
        case .text: true
        case .all: true
        case .and(let branches), .or(let branches): branches.allSatisfy(containsOnlyText)
        case .not(let inner): containsOnlyText(inner)
        default: false
        }
    }
}
