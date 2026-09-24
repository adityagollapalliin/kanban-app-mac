import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

/// What a rule will *not* do.
///
/// `AutomationTests` in AgileTests covers a rule firing, cascading, being
/// switched off and being refused. These are the edges either side of that:
/// the cases where the right behaviour is to stay still.
@Suite("The edges of an automation rule")
struct AutomationEdgeTests {

    /// A rule watches one column. A rule that fired on every move would be a
    /// rule nobody could reason about.
    @Test("A move into another column leaves the card alone")
    func otherColumnsUnaffected() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        try AutomationRepository(database: database).create(
            inProject: ids.project, name: "Flag what is in review",
            trigger: .statusChanged, triggerStatusID: ids.inProgress,
            action: .setFlag, actionValue: "in review"
        )

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Work")
        try tasks.move(task.id, toStatus: ids.done)

        #expect(try tasks.task(id: task.id).flagged == false)
    }

    /// A card with no subtasks has not "finished them all" — otherwise every
    /// card in the project would move the moment such a rule was created.
    @Test("A card with no subtasks has not finished them all")
    func noSubtasksIsNotDone() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        let lonely = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Alone")
        #expect(try AutomationRepository(database: database).allSubtasksDone(of: lonely.id) == false)
    }

    @Test("A status rule without a column is refused")
    func triggerNeedsAColumn() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()

        #expect(throws: LocalBoardError.self) {
            try AutomationRepository(database: database).create(
                inProject: ids.project, name: "Vague",
                trigger: .statusChanged, action: .setFlag, actionValue: "why"
            )
        }
    }

    /// Creation is a trigger too, so a project can say "new work starts
    /// urgent" without anyone touching the card.
    @Test("A rule can fire when a card is created")
    func createdTrigger() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        try AutomationRepository(database: database).create(
            inProject: ids.project, name: "New work is urgent",
            trigger: .created, action: .setPriority, actionValue: String(Priority.highest.rawValue)
        )

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Fresh")
        #expect(try tasks.task(id: task.id).priority == .highest)
    }

    /// The cascade test in AgileTests asserts a chain settles. This asserts
    /// *where* it settles, which is the part a user would have to discover by
    /// experiment: a rule may set off a rule, and the one after that is
    /// refused. Two links, not one and not forever.
    @Test("A chain of rules stops two links in")
    func cascadeStopsTwoLinksIn() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let rules = AutomationRepository(database: database)

        let shipped = UUID().uuidString
        try database.execute(
            "INSERT INTO status (id, project_id, name, category, sort_order) VALUES (?, ?, ?, ?, ?);",
            [shipped, ids.project, "Shipped", StatusCategory.done.rawValue, 4_000.0]
        )

        // To Do → In Progress → Done → Shipped, by rules alone.
        try rules.create(inProject: ids.project, name: "Start it",
                         trigger: .statusChanged, triggerStatusID: ids.toDo,
                         action: .moveToStatus, actionValue: ids.inProgress)
        try rules.create(inProject: ids.project, name: "Finish it",
                         trigger: .statusChanged, triggerStatusID: ids.inProgress,
                         action: .moveToStatus, actionValue: ids.done)
        try rules.create(inProject: ids.project, name: "Ship it",
                         trigger: .statusChanged, triggerStatusID: ids.done,
                         action: .moveToStatus, actionValue: shipped)

        let task = try tasks.create(inProject: ids.project, statusID: shipped, title: "Work")
        try tasks.move(task.id, toStatus: ids.toDo)

        // The first two rules ran. The third was a level too deep, so a
        // configuration mistake costs a card one unexpected column, not a hang.
        #expect(try tasks.task(id: task.id).statusID == ids.done)
    }
}

@Suite("How the app looks, remembered")
struct AppearanceSettingsTests {

    @Test("An appearance survives being written and read back")
    func roundTrip() throws {
        let database = try Database.inMemoryMigrated()
        let settings = AppSettings(database: database)

        // Nothing stored means the Mac decides, which is the right default.
        #expect(try settings.appearance == .system)

        try settings.setAppearance(.dark)
        #expect(try settings.appearance == .dark)

        try settings.setAppearance(.light)
        #expect(try settings.appearance == .light)
    }

    /// `system` is stored as the absence of a value, so a file that has never
    /// been asked and one put back to system read the same.
    @Test("Going back to system leaves nothing behind")
    func systemStoresNothing() throws {
        let database = try Database.inMemoryMigrated()
        let settings = AppSettings(database: database)

        try settings.setAppearance(.dark)
        try settings.setAppearance(.system)

        #expect(try settings.appearance == .system)
        #expect(try database.count("SELECT COUNT(*) FROM app_meta WHERE key = 'appearance';") == 0)
    }

    /// A value from a build that knows more appearances than this one reads as
    /// system rather than crashing: the safe answer to a setting it does not
    /// understand is to do what the rest of the Mac does.
    @Test("An unreadable value reads as system")
    func unknownValueIsSystem() throws {
        let database = try Database.inMemoryMigrated()
        try database.execute("INSERT INTO app_meta (key, value) VALUES ('appearance', '99');")

        #expect(try AppSettings(database: database).appearance == .system)
    }
}
