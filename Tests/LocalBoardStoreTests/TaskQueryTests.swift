import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("Query language")
struct TaskQueryTests {

    private struct Fixture {
        let database: Database
        let repository: TaskRepository
        let clock: FixedClock
        let project: String
        let toDo: String
        let inProgress: String
        let done: String
    }

    private func fixture() throws -> Fixture {
        let database = try Database.inMemoryMigrated()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let ids = try database.seedBoardProject()
        return Fixture(
            database: database,
            repository: TaskRepository(database: database, clock: clock),
            clock: clock,
            project: ids.project,
            toDo: ids.toDo,
            inProgress: ids.inProgress,
            done: ids.done
        )
    }

    private func days(_ count: Int, from clock: FixedClock) -> Date {
        clock.now.addingTimeInterval(Double(count) * 86_400)
    }

    private func titles(_ fixture: Fixture, _ query: String) throws -> [String] {
        try fixture.repository.tasks(matching: query, inProject: fixture.project).map(\.title).sorted()
    }

    // MARK: - Dates

    @Test("due < +7d finds what is due inside a week and nothing beyond it")
    func dueWithinAWeek() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Soon", dueDate: days(3, from: f.clock))
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Later", dueDate: days(30, from: f.clock))
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Undated")

        #expect(try titles(f, "due < +7d") == ["Soon"])
    }

    @Test("A date comparison covers the whole day, not an instant")
    func dateIsADay() throws {
        let f = try fixture()
        // Two cards due the same calendar day, several hours apart.
        let morning = Calendar.current.startOfDay(for: days(2, from: f.clock)).addingTimeInterval(9 * 3_600)
        let evening = Calendar.current.startOfDay(for: days(2, from: f.clock)).addingTimeInterval(22 * 3_600)
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Morning", dueDate: morning)
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Evening", dueDate: evening)
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Next day", dueDate: days(3, from: f.clock))

        #expect(try titles(f, "due = +2d") == ["Evening", "Morning"])
    }

    @Test("due = none finds the cards with no date at all")
    func undated() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Dated", dueDate: days(1, from: f.clock))
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Undated")

        #expect(try titles(f, "due = none") == ["Undated"])
        #expect(try titles(f, "due != none") == ["Dated"])
    }

    // MARK: - Enumerations

    @Test("priority >= high is an ordering, not a set of names")
    func priorityOrdering() throws {
        let f = try fixture()
        for (title, priority) in [("Lowest", Priority.lowest), ("Normal", .normal), ("High", .high), ("Highest", .highest)] {
            try f.repository.create(inProject: f.project, statusID: f.toDo, title: title, priority: priority)
        }

        #expect(try titles(f, "priority >= high") == ["High", "Highest"])
        #expect(try titles(f, "priority < normal") == ["Lowest"])
    }

    @Test("type filters by card type")
    func typeFilter() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "A bug", type: .bug)
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "An epic", type: .epic)

        #expect(try titles(f, "type:bug") == ["A bug"])
        #expect(try titles(f, "type != bug") == ["An epic"])
    }

    @Test("status matches the column by the name on it")
    func statusFilter() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Waiting")
        try f.repository.create(inProject: f.project, statusID: f.inProgress, title: "Started")

        #expect(try titles(f, "status = \"In Progress\"") == ["Started"])
        // Case is not something to get right when typing a search.
        #expect(try titles(f, "status = \"in progress\"") == ["Started"])
        #expect(try titles(f, "status != \"In Progress\"") == ["Waiting"])
    }

    // MARK: - Flags

    @Test("is:done and is:open follow the completion stamp")
    func doneAndOpen() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Open")
        try f.repository.create(inProject: f.project, statusID: f.done, title: "Finished")

        #expect(try titles(f, "is:done") == ["Finished"])
        #expect(try titles(f, "is:open") == ["Open"])
    }

    @Test("is:overdue means dated, past, and not finished")
    func overdue() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Late", dueDate: days(-3, from: f.clock))
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Upcoming", dueDate: days(3, from: f.clock))
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Undated")
        // Finished late is not overdue; it is finished.
        let closed = try f.repository.create(
            inProject: f.project, statusID: f.toDo, title: "Late but done", dueDate: days(-3, from: f.clock)
        )
        try f.repository.move(closed.id, toStatus: f.done)

        #expect(try titles(f, "is:overdue") == ["Late"])
    }

    /// Trashed cards stay out of every query that does not ask for them, so a
    /// search does not need a separate switch to stay clean.
    @Test("The trash is invisible unless the query mentions it")
    func trash() throws {
        let f = try fixture()
        let kept = try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Kept")
        let binned = try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Binned")
        try f.repository.setTrashed(true, for: binned.id)

        #expect(try titles(f, "") == ["Kept"])
        #expect(try titles(f, "is:trashed") == ["Binned"])
        #expect(try titles(f, "not is:trashed") == ["Kept"])
        _ = kept
    }

    // MARK: - Combining

    @Test("Adjacent terms narrow, or widens, not inverts")
    func combining() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Urgent bug", type: .bug, priority: .highest)
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Quiet bug", type: .bug, priority: .low)
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Urgent story", type: .story, priority: .highest)

        #expect(try titles(f, "type:bug priority >= high") == ["Urgent bug"])
        #expect(try titles(f, "type:bug or priority >= high") == ["Quiet bug", "Urgent bug", "Urgent story"])
        #expect(try titles(f, "not type:bug") == ["Urgent story"])
        #expect(try titles(f, "(type:bug or type:story) priority >= high") == ["Urgent bug", "Urgent story"])
    }

    // MARK: - Text

    @Test("Bare words search the full-text index, across title and notes")
    func freeText() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Refactor the parser")
        try f.repository.create(
            inProject: f.project, statusID: f.toDo, title: "Unrelated",
            descriptionMarkdown: "mentions the parser as well"
        )
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Nothing to see")

        #expect(try titles(f, "parser") == ["Refactor the parser", "Unrelated"])
    }

    @Test("title matches a substring, unlike the word-based index")
    func titleContains() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Refactoring")
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Nothing")

        #expect(try titles(f, "title:factor") == ["Refactoring"])
    }

    /// LIKE reads % and _ as wildcards. Someone searching for a percentage
    /// means the character.
    @Test("Wildcards typed into a title search are literal")
    func likeWildcardsAreEscaped() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Cut latency 50% by Friday")
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Unrelated work")

        #expect(try titles(f, "title:\"50%\"") == ["Cut latency 50% by Friday"])
        #expect(try titles(f, "title:\"%\"") == ["Cut latency 50% by Friday"])
        #expect(try titles(f, "title:_") == [])
    }

    // MARK: - The promise SQLValue makes

    /// The comment on SQLValue says the app never interpolates a value into SQL
    /// text, "including in the query language compiler". This is that claim,
    /// tested.
    @Test("A query that looks like SQL is data, not SQL")
    func injectionAttempts() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "'; DROP TABLE task; --")
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Innocent")

        let hostile = [
            "title:\"'; DROP TABLE task; --\"",
            "title:\"' OR 1=1 --\"",
            "status = \"' OR '1'='1\"",
            "assignee = \"'; DELETE FROM task WHERE '1'='1\"",
        ]

        for query in hostile {
            _ = try f.repository.tasks(matching: query, inProject: f.project)
            // The table is still there, and so is everything in it.
            #expect(try f.database.count("SELECT COUNT(*) FROM task;") == 2)
        }

        // And the card whose title is an injection attempt is findable by it,
        // because it is simply a title.
        #expect(try titles(f, "title:\"DROP TABLE\"") == ["'; DROP TABLE task; --"])
    }

    @Test("An unparseable query is an error, not an empty result")
    func badQuery() throws {
        let f = try fixture()
        #expect(throws: QueryError.self) {
            try f.repository.tasks(matching: "due < banana", inProject: f.project)
        }
    }

    @Test("An empty query returns the whole project")
    func emptyQuery() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "One")
        try f.repository.create(inProject: f.project, statusID: f.inProgress, title: "Two")

        #expect(try titles(f, "") == ["One", "Two"])
    }

    @Test("Results come back most urgent first")
    func ordering() throws {
        let f = try fixture()
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Low", priority: .low)
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Highest", priority: .highest)
        try f.repository.create(inProject: f.project, statusID: f.toDo, title: "Normal", priority: .normal)

        let ordered = try f.repository.tasks(matching: "", inProject: f.project).map(\.title)
        #expect(ordered == ["Highest", "Normal", "Low"])
    }
}
