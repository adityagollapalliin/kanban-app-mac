import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

/// What disappears with its parent, and what deliberately does not.
///
/// Every table added in v9–v11 either cascades or nulls, and which one is a
/// decision rather than a default: a card outlives the resolution that was
/// deleted out from under it, but a rule cannot outlive the transition it is
/// a rule about. None of this was asserted until now, and an untested cascade
/// is a row nobody will notice is orphaned.
@Suite("Cascades and their deliberate exceptions")
struct CascadeTests {

    private func fixture() throws -> (
        Database, StoppedClock,
        (workspace: String, project: String, board: String, toDo: String, inProgress: String, done: String)
    ) {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        return (database, clock, try database.seedBoardProject())
    }

    @Test("Deleting a card takes its components and versions with it")
    func taskCascades() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)
        let versions = VersionRepository(database: database, clock: clock)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Doomed")
        let parser = try components.create(inProject: ids.project, name: "Parser")
        let one = try versions.create(inProject: ids.project, name: "1.0")
        try components.add(parser.id, toTask: card.id)
        try components.add(one.id, toTask: card.id, as: .fix)

        try database.execute("DELETE FROM task WHERE id = ?;", [card.id])

        #expect(try database.count("SELECT COUNT(*) FROM task_component;") == 0)
        #expect(try database.count("SELECT COUNT(*) FROM task_version;") == 0)
        // The component and the version are about the project, not the card.
        #expect(try components.components(inProject: ids.project).count == 1)
        #expect(try versions.versions(inProject: ids.project).count == 1)
    }

    @Test("Deleting a transition takes its rules with it")
    func transitionCascades() throws {
        let (database, clock, ids) = try fixture()
        let workflow = WorkflowRepository(database: database, clock: clock)
        let rules = TransitionRuleRepository(database: database, clock: clock)

        try workflow.allow(from: ids.toDo, to: ids.done, inProject: ids.project)
        let move = try #require(try database.queryOne(
            "SELECT id FROM workflow_transition WHERE project_id = ?;", [ids.project]
        )?.string("id"))
        try rules.add(.resolutionRequired, toTransition: move)

        try workflow.forbid(from: ids.toDo, to: ids.done, inProject: ids.project)
        // A rule cannot outlive the move it is a rule about.
        #expect(try database.count("SELECT COUNT(*) FROM transition_rule;") == 0)
    }

    @Test("Deleting a component takes the tag off cards but leaves the cards")
    func componentCascades() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Tagged")
        let parser = try components.create(inProject: ids.project, name: "Parser")
        try components.add(parser.id, toTask: card.id)

        try components.delete(parser.id)
        #expect(try database.count("SELECT COUNT(*) FROM task_component;") == 0)
        #expect(try tasks.task(id: card.id).title == "Tagged")
    }

    @Test("Deleting a resolution leaves the card, without a reason for being closed")
    func resolutionNullsRatherThanCascades() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let vocabulary = VocabularyRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        let duplicate = try vocabulary.addResolution(inProject: ids.project, name: "Obsolete")
        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Closed")
        try components.setResolution(duplicate.id, forTask: card.id)

        try vocabulary.deleteResolution(duplicate.id)

        // Cascading here would delete somebody's work because a word was
        // removed from a list.
        #expect(try tasks.task(id: card.id).title == "Closed")
        #expect(try components.resolution(forTask: card.id) == nil)
    }

    @Test("Deleting a person leaves the component they looked after")
    func personNullsOnComponent() throws {
        let (database, clock, ids) = try fixture()
        let people = PersonRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        let ada = try people.create(name: "Ada Lovelace")
        let parser = try components.create(
            inProject: ids.project, name: "Parser", defaultAssigneeID: ada.id
        )

        try people.delete(ada.id)
        let after = try #require(try components.components(inProject: ids.project).first)
        #expect(after.id == parser.id)
        #expect(after.defaultAssigneeID == nil)
    }

    @Test("Deleting a project takes its whole vocabulary with it")
    func projectCascades() throws {
        let (database, clock, ids) = try fixture()
        let configs = FieldConfigRepository(database: database, clock: clock)
        try configs.set(
            inProject: ids.project, forType: 2, field: .builtIn("due"),
            shown: true, required: true, defaultValue: ""
        )

        try database.execute("DELETE FROM project WHERE id = ?;", [ids.project])

        for table in ["issue_type", "priority_value", "link_type", "resolution",
                      "component", "field_config"] {
            #expect(
                try database.count("SELECT COUNT(*) FROM \(table);") == 0,
                "\(table) still holds rows for a project that is gone"
            )
        }
    }

    @Test("Nothing is left dangling after all of that")
    func noOrphansRemain() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "A card")
        let parser = try components.create(inProject: ids.project, name: "Parser")
        try components.add(parser.id, toTask: card.id)
        try database.execute("DELETE FROM project WHERE id = ?;", [ids.project])

        // The check SQLite itself performs, which is the only one that covers
        // relationships nobody thought to write a test for.
        #expect(try database.query("PRAGMA foreign_key_check;").isEmpty)
    }
}
