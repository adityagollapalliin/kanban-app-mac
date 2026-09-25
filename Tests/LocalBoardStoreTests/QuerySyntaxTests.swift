import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

private func fixture() throws -> (
    Database, StoppedClock,
    (workspace: String, project: String, board: String, toDo: String, inProgress: String, done: String)
) {
    let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
    let database = try Database.inMemoryMigrated()
    return (database, clock, try database.seedBoardProject())
}

@Suite("A simple filter keeps meaning what it meant")
struct SimpleFilterPreservationTests {

    /// The five JQL-shaped strings that already compiled in the old language,
    /// as full-text searches. This is the condition attached to the approval:
    /// a `simple` filter containing them must return the same cards after 8.5b
    /// as it did before.
    private let collisions = [
        "ORDER BY due",
        "priority IN (high, highest)",
        "summary ~ login",
        "status WAS \"In Progress\"",
        "status CHANGED FROM \"To Do\" TO \"Done\"",
    ]

    @Test("Each still runs, and still searches for its words")
    func stillTextSearches() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)

        // A card whose title contains the words one of those queries searches
        // for. Under the old language it matches; under JQL the same string is
        // a clause and does not.
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Fix the ORDER BY due clause")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Something else entirely")

        let found = try tasks.tasks(matching: "ORDER BY due", inProject: ids.project, syntax: .simple)
        #expect(found.count == 1)
        #expect(found.first?.title.contains("ORDER BY due") == true)

        // Every one of them compiles and returns a result set rather than
        // throwing. That is the promise: nothing anybody saved stopped working.
        for source in collisions {
            #expect(throws: Never.self) {
                _ = try tasks.tasks(matching: source, inProject: ids.project, syntax: .simple)
            }
        }
    }

    @Test("The same string in the new language means something else entirely")
    func jqlReadsThemAsClauses() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)

        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Fix the ORDER BY due clause")
        let high = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Urgent", priority: .highest)

        // Under JQL this is "every card, ordered by due date" — both of them.
        let ordered = try tasks.tasks(matching: "ORDER BY due", inProject: ids.project, syntax: .jql)
        #expect(ordered.count == 2)

        // And this is a real priority filter rather than four words.
        let urgent = try tasks.tasks(
            matching: "priority IN (high, highest)", inProject: ids.project, syntax: .jql
        )
        #expect(urgent.map(\.id) == [high.id])

        // Which is precisely why a stored query has to say which language it
        // is in: the same text, two answers.
        let asText = try tasks.tasks(
            matching: "priority IN (high, highest)", inProject: ids.project, syntax: .simple
        )
        #expect(asText.count != urgent.count)
    }

    @Test("Everything a simple filter could ask returns the same cards in both languages")
    func sharedConstructsAgree() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let people = PersonRepository(database: database, clock: clock)

        let ada = try people.create(name: "Ada Lovelace")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "One", priority: .high)
        try tasks.create(
            inProject: ids.project, statusID: ids.inProgress, title: "Two",
            type: .bug, assigneeID: ada.id
        )
        let done = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Three")
        try tasks.move(done.id, toStatus: ids.done)

        for source in [
            "is:open", "is:done", "priority >= high", "type = bug",
            "assignee = \"Ada Lovelace\"", "not is:done", "is:open or is:done",
            "status = \"In Progress\"", "due = none",
        ] {
            let asSimple = try tasks.tasks(matching: source, inProject: ids.project, syntax: .simple)
            let asJQL = try tasks.tasks(matching: source, inProject: ids.project, syntax: .jql)
            #expect(asSimple.map(\.id) == asJQL.map(\.id), "`\(source)` returns different cards")
        }
    }
}

@Suite("Saved filters carry their language")
struct SavedViewSyntaxTests {

    @Test("Anything saved before the column existed is simple")
    func defaultsToSimple() throws {
        let (database, clock, ids) = try fixture()
        let views = SavedViewRepository(database: database, clock: clock)

        // Written the way the app wrote them before schema 10: no syntax.
        try database.execute(
            """
            INSERT INTO saved_view (id, project_id, name, query, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            ["v1", ids.project, "Old one", "ORDER BY due", 1_000.0, clock.now]
        )

        #expect(try views.views(inProject: ids.project).first?.syntax == .simple)
    }

    @Test("A filter written in the new language says so")
    func explicitSyntax() throws {
        let (database, clock, ids) = try fixture()
        let views = SavedViewRepository(database: database, clock: clock)

        let advanced = try views.create(
            inProject: ids.project, name: "Urgent", query: "priority IN (high, highest)", syntax: .jql
        )
        #expect(advanced.syntax == .jql)

        // And the same text is refused as a basic filter only if it does not
        // parse — here it does, as a text search, so both are legal and mean
        // different things. That is the whole point.
        let basic = try views.create(
            inProject: ids.project, name: "Words", query: "priority IN (high, highest)", syntax: .simple
        )
        #expect(basic.syntax == .simple)
    }

    @Test("Editing a filter's text never changes its language")
    func editingKeepsSyntax() throws {
        let (database, clock, ids) = try fixture()
        let views = SavedViewRepository(database: database, clock: clock)
        let view = try views.create(
            inProject: ids.project, name: "Mine", query: "is:open", syntax: .jql
        )

        try views.setQuery("priority IN (high)", for: view.id)
        #expect(try views.view(id: view.id).syntax == .jql)

        // And a basic filter stays basic even when what was typed would also
        // be valid JQL.
        let basic = try views.create(inProject: ids.project, name: "Basic", query: "is:open")
        try views.setQuery("ORDER BY due", for: basic.id)
        #expect(try views.view(id: basic.id).syntax == .simple)
    }

    @Test("Converting shows what it would do before it does it")
    func conversionPreview() throws {
        let (database, clock, ids) = try fixture()
        let views = SavedViewRepository(database: database, clock: clock)
        let tasks = TaskRepository(database: database, clock: clock)

        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Fix the ORDER BY due clause")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Another")

        let view = try views.create(inProject: ids.project, name: "Words", query: "ORDER BY due")
        let preview = try views.previewConversion(view.id, to: .jql)

        #expect(preview.parses)
        // One card matched the text search; every card matches the clause.
        #expect(preview.matchesBefore == 1)
        #expect(preview.matchesAfter == 2)
        #expect(preview.resultsChange)

        // And nothing has been saved by asking.
        #expect(try views.view(id: view.id).syntax == .simple)
    }

    @Test("A preview reports a filter that would not parse, rather than converting it")
    func conversionRefusesBadQueries() throws {
        let (database, clock, ids) = try fixture()
        let views = SavedViewRepository(database: database, clock: clock)

        // Three ordinary words to search for in the old language; in the new
        // one `currentUser` is a function and is missing its brackets.
        let view = try views.create(
            inProject: ids.project, name: "Prose", query: "assignee = currentUser"
        )
        let preview = try views.previewConversion(view.id, to: .jql)

        #expect(!preview.parses)
        #expect(throws: (any Error).self) { try views.convert(view.id, to: .jql) }
        #expect(try views.view(id: view.id).syntax == .simple)
    }

    @Test("Converting is a deliberate act, and it sticks")
    func converting() throws {
        let (database, clock, ids) = try fixture()
        let views = SavedViewRepository(database: database, clock: clock)
        let view = try views.create(inProject: ids.project, name: "Urgent", query: "priority >= high")

        try views.convert(view.id, to: .jql)
        #expect(try views.view(id: view.id).syntax == .jql)
    }

    @Test("Filters can be starred and given their own columns")
    func starringAndColumns() throws {
        let (database, clock, ids) = try fixture()
        let views = SavedViewRepository(database: database, clock: clock)
        let view = try views.create(inProject: ids.project, name: "Mine", query: "is:mine")

        #expect(!view.starred)
        #expect(view.columns.isEmpty)

        try views.setStarred(true, for: view.id)
        try views.setColumns(["key", "title", "due"], for: view.id)

        let after = try views.view(id: view.id)
        #expect(after.starred)
        #expect(after.columns == ["key", "title", "due"])
    }
}

@Suite("What the new language can ask the database")
struct JQLCompilerTests {

    @Test("IN, NOT IN and IS EMPTY against real cards")
    func membershipAndEmptiness() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let people = PersonRepository(database: database, clock: clock)

        let ada = try people.create(name: "Ada Lovelace")
        let high = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "High", priority: .high)
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Low", priority: .low)
        let assigned = try tasks.create(
            inProject: ids.project, statusID: ids.toDo, title: "Assigned", assigneeID: ada.id
        )

        func run(_ source: String) throws -> [String] {
            try tasks.tasks(matching: source, inProject: ids.project, syntax: .jql).map(\.title)
        }

        #expect(try run("priority IN (high, highest)") == ["High"])
        #expect(try run("priority NOT IN (high, highest)").sorted() == ["Assigned", "Low"])
        #expect(try run("assignee IS EMPTY").sorted() == ["High", "Low"])
        #expect(try run("assignee IS NOT EMPTY") == ["Assigned"])
        _ = (high, assigned)
    }

    @Test("~ finds part of a word, where the text index would not")
    func contains() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Refactor the login screen")

        // The full-text index matches whole tokens with a prefix, so `ogin`
        // finds nothing through it and this card through `~`.
        let found = try tasks.tasks(matching: "title ~ ogin", inProject: ids.project, syntax: .jql)
        #expect(found.count == 1)
    }

    @Test("ORDER BY actually orders, and unset dates sort last")
    func ordering() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)

        let later = try tasks.create(
            inProject: ids.project, statusID: ids.toDo, title: "Later",
            dueDate: clock.now.addingTimeInterval(86_400 * 7)
        )
        let sooner = try tasks.create(
            inProject: ids.project, statusID: ids.toDo, title: "Sooner",
            dueDate: clock.now.addingTimeInterval(86_400)
        )
        let undated = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "No date")

        let ascending = try tasks.tasks(matching: "ORDER BY due", inProject: ids.project, syntax: .jql)
        // A card with no due date is not the most urgent thing on the board.
        #expect(ascending.map(\.id) == [sooner.id, later.id, undated.id])

        let descending = try tasks.tasks(
            matching: "ORDER BY due DESC", inProject: ids.project, syntax: .jql
        )
        #expect(descending.first?.id == later.id)
    }

    @Test("WAS and CHANGED read the recorded history")
    func history() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)

        let travelled = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Travelled")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Stayed put")
        clock.advance(days: 1)
        try tasks.move(travelled.id, toStatus: ids.inProgress)
        clock.advance(days: 1)
        try tasks.move(travelled.id, toStatus: ids.done)

        func run(_ source: String) throws -> [String] {
            try tasks.tasks(matching: source, inProject: ids.project, syntax: .jql).map(\.title)
        }

        #expect(try run("status WAS \"In Progress\"") == ["Travelled"])
        #expect(try run("status CHANGED FROM \"To Do\" TO \"In Progress\"") == ["Travelled"])
        // The card that never left its column has no move to find.
        #expect(try run("status CHANGED TO \"Done\"") == ["Travelled"])
    }

    @Test("currentUser() is whoever this copy of the app belongs to")
    func currentUser() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let people = PersonRepository(database: database, clock: clock)

        let ada = try people.create(name: "Ada Lovelace")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Mine", assigneeID: ada.id)
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Somebody else's")

        // Nobody chosen yet: an unanswered question has no answers.
        #expect(try tasks.tasks(
            matching: "assignee = currentUser()", inProject: ids.project, syntax: .jql
        ).isEmpty)

        try AppSettings(database: database).setCurrentPerson(ada.id)
        #expect(try tasks.tasks(
            matching: "assignee = currentUser()", inProject: ids.project, syntax: .jql
        ).map(\.title) == ["Mine"])
    }

    @Test("openSprints() and releasedVersions() read the board's state")
    func setFunctions() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let sprints = SprintRepository(database: database, clock: clock)

        let sprint = try sprints.create(inProject: ids.project, name: "Sprint 1", goal: "")
        let inSprint = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Committed")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Not committed")
        try sprints.setSprint(sprint.id, for: inSprint.id)

        // Planned, not started: `openSprints()` is about what is running.
        #expect(try tasks.tasks(
            matching: "sprint IN openSprints()", inProject: ids.project, syntax: .jql
        ).isEmpty)

        try sprints.start(sprint.id)
        #expect(try tasks.tasks(
            matching: "sprint IN openSprints()", inProject: ids.project, syntax: .jql
        ).map(\.title) == ["Committed"])
    }

    @Test("A date function resolves against the clock, every time it is run")
    func dateFunctions() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)

        try tasks.create(
            inProject: ids.project, statusID: ids.toDo, title: "Due tomorrow",
            dueDate: clock.now.addingTimeInterval(86_400)
        )
        try tasks.create(
            inProject: ids.project, statusID: ids.toDo, title: "Due next year",
            dueDate: clock.now.addingTimeInterval(86_400 * 400)
        )

        let soon = try tasks.tasks(
            matching: "due <= endOfMonth()", inProject: ids.project, syntax: .jql
        )
        #expect(soon.map(\.title) == ["Due tomorrow"])
    }

    @Test("A function used where it makes no sense is refused")
    func misusedFunctions() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        #expect(throws: (any Error).self) {
            try tasks.tasks(matching: "priority = currentUser()", inProject: ids.project, syntax: .jql)
        }
    }
}
