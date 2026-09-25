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
    let ids = try database.seedBoardProject()
    // Workflow rules only bite when the project enforces its workflow.
    try WorkflowRepository(database: database, clock: clock)
        .setEnforced(true, inProject: ids.project)
    return (database, clock, ids)
}

/// Allows the move and returns the transition, so a test can hang rules on it.
private func transition(
    _ database: Database, _ clock: StoppedClock,
    project: String, from: String, to: String
) throws -> String {
    let workflow = WorkflowRepository(database: database, clock: clock)
    try workflow.allow(from: from, to: to, inProject: project)
    return try #require(database.queryOne(
        """
        SELECT id FROM workflow_transition
        WHERE project_id = ? AND from_status_id = ? AND to_status_id = ?;
        """,
        [project, from, to]
    )?.string("id"))
}

@Suite("What a move has to satisfy")
struct TransitionValidatorTests {

    @Test("A validator refuses the move and says what is missing")
    func validatorRefuses() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let rules = TransitionRuleRepository(database: database, clock: clock)

        let move = try transition(database, clock, project: ids.project, from: ids.toDo, to: ids.done)
        try rules.add(.resolutionRequired, toTransition: move)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Unfinished")
        #expect(throws: (any Error).self) { try tasks.move(card.id, toStatus: ids.done) }
        // And it has not moved.
        #expect(try tasks.task(id: card.id).statusID == ids.toDo)

        try ComponentRepository(database: database, clock: clock).setResolution(
            try #require(try VocabularyRepository(database: database, clock: clock)
                .defaultResolution(inProject: ids.project)).id,
            forTask: card.id
        )
        try tasks.move(card.id, toStatus: ids.done)
        #expect(try tasks.task(id: card.id).statusID == ids.done)
    }

    @Test("Every failing validator is reported at once, not one at a time")
    func allReasonsTogether() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let rules = TransitionRuleRepository(database: database, clock: clock)

        let move = try transition(database, clock, project: ids.project, from: ids.toDo, to: ids.done)
        try rules.add(.resolutionRequired, toTransition: move)
        try rules.add(.timeLoggedRequired, toTransition: move)
        try rules.add(.commentRequired, toTransition: move)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Bare")
        let refusal = try #require(try rules.refusal(move, forTask: card.id, transitionName: "Done"))

        // Being told about one, then once it is satisfied about the next, is
        // how a workflow earns its reputation.
        #expect(refusal.reasons.count == 3)
        #expect(refusal.message.contains("resolution"))
        #expect(refusal.message.contains("comment"))
    }

    @Test("A required field is checked by name, built-in or the project's own")
    func requiredFields() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let rules = TransitionRuleRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let size = try fields.create(inProject: ids.project, name: "Size", kind: .number)
        let move = try transition(database, clock, project: ids.project, from: ids.toDo, to: ids.inProgress)
        try rules.add(.fieldRequired, toTransition: move, target: FieldReference.builtIn("assignee").stored)
        try rules.add(.fieldRequired, toTransition: move, target: FieldReference.custom(size.id).stored)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Unsized")
        let refusal = try #require(try rules.refusal(move, forTask: card.id, transitionName: "Start"))
        #expect(refusal.reasons.count == 2)
        // The project's own field is named as the person named it.
        #expect(refusal.message.contains("Size"))

        let people = PersonRepository(database: database, clock: clock)
        let ada = try people.create(name: "Ada Lovelace")
        try tasks.setAssignee(ada.id, for: card.id)
        try fields.setValue(.number(3), forField: size.id, onTask: card.id)

        #expect(try rules.refusal(move, forTask: card.id, transitionName: "Start") == nil)
    }

    @Test("A validator added today does not make yesterday's card invalid")
    func validatorsAreNotRetroactive() throws {
        // The approval's condition: new validators apply only to future
        // transitions. Nothing here reads a card's past, so a card that has
        // already moved stays where it is.
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let rules = TransitionRuleRepository(database: database, clock: clock)

        let move = try transition(database, clock, project: ids.project, from: ids.toDo, to: ids.done)
        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Already done")
        try tasks.move(card.id, toStatus: ids.done)

        // The rule arrives afterwards.
        try rules.add(.timeLoggedRequired, toTransition: move)

        #expect(try tasks.task(id: card.id).statusID == ids.done)
        #expect(try tasks.task(id: card.id).completedAt != nil)
    }
}

@Suite("Whether a move is offered at all")
struct TransitionConditionTests {

    @Test("A condition hides the move rather than refusing it")
    func conditionsHide() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let rules = TransitionRuleRepository(database: database, clock: clock)

        let move = try transition(database, clock, project: ids.project, from: ids.toDo, to: ids.done)
        try rules.add(.allSubtasksDone, toTransition: move)

        let parent = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Parent")
        let child = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Child")
        try tasks.setParent(parent.id, for: child.id)

        #expect(try !rules.isOffered(move, forTask: parent.id))

        try tasks.move(child.id, toStatus: ids.done)
        #expect(try rules.isOffered(move, forTask: parent.id))
    }

    @Test("A card with no subtasks has finished none of them, and that counts as done")
    func noSubtasks() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let rules = TransitionRuleRepository(database: database, clock: clock)

        let move = try transition(database, clock, project: ids.project, from: ids.toDo, to: ids.done)
        try rules.add(.allSubtasksDone, toTransition: move)

        let lonely = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "On its own")
        // Nothing is outstanding, so nothing is in the way.
        #expect(try rules.isOffered(move, forTask: lonely.id))
    }

    @Test("A condition can be a query, checked in its own language")
    func queryCondition() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let rules = TransitionRuleRepository(database: database, clock: clock)

        let move = try transition(database, clock, project: ids.project, from: ids.toDo, to: ids.done)
        try rules.add(.matchesQuery, toTransition: move, query: "priority >= high")

        let urgent = try tasks.create(
            inProject: ids.project, statusID: ids.toDo, title: "Urgent", priority: .highest
        )
        let ordinary = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Ordinary")

        #expect(try rules.isOffered(move, forTask: urgent.id))
        #expect(try !rules.isOffered(move, forTask: ordinary.id))
    }

    @Test("A query condition that will not parse is refused when it is written")
    func badQueryRefused() throws {
        let (database, clock, ids) = try fixture()
        let rules = TransitionRuleRepository(database: database, clock: clock)
        let move = try transition(database, clock, project: ids.project, from: ids.toDo, to: ids.done)

        // Better than refusing every move later with a message about syntax.
        #expect(throws: (any Error).self) {
            try rules.add(.matchesQuery, toTransition: move, query: "priority >= wombat")
        }
    }
}

@Suite("What happens after a move")
struct TransitionPostFunctionTests {

    @Test("Post-functions run once the move is written")
    func postFunctionsRun() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let rules = TransitionRuleRepository(database: database, clock: clock)
        let people = PersonRepository(database: database, clock: clock)

        let ada = try people.create(name: "Ada Lovelace")
        let move = try transition(database, clock, project: ids.project, from: ids.toDo, to: ids.inProgress)
        try rules.add(.assign, toTransition: move, target: ada.id)
        try rules.add(.clearFlag, toTransition: move)
        try rules.add(.addComment, toTransition: move, value: "Picked up.")

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Work")
        try tasks.setFlag(true, reason: "waiting", for: card.id)
        try tasks.move(card.id, toStatus: ids.inProgress)

        let after = try tasks.task(id: card.id)
        #expect(after.assigneeID == ada.id)
        #expect(!after.flagged)
        #expect(try database.count("SELECT COUNT(*) FROM comment WHERE task_id = ?;", [card.id]) == 1)
    }

    @Test("A post-function leaves nothing behind on a move that was refused")
    func nothingRunsOnARefusedMove() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let rules = TransitionRuleRepository(database: database, clock: clock)
        let people = PersonRepository(database: database, clock: clock)

        let ada = try people.create(name: "Ada Lovelace")
        let move = try transition(database, clock, project: ids.project, from: ids.toDo, to: ids.done)
        try rules.add(.commentRequired, toTransition: move)
        try rules.add(.assign, toTransition: move, target: ada.id)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Blocked")
        #expect(throws: (any Error).self) { try tasks.move(card.id, toStatus: ids.done) }

        // The assignment must not have happened: it runs after the move, and
        // there was no move.
        #expect(try tasks.task(id: card.id).assigneeID == nil)
    }

    @Test("A post-function can set a field, reading dates the way a query does")
    func setField() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let rules = TransitionRuleRepository(database: database, clock: clock)

        let move = try transition(database, clock, project: ids.project, from: ids.toDo, to: ids.inProgress)
        try rules.add(
            .setField, toTransition: move,
            target: FieldReference.builtIn("due").stored, value: "+7d"
        )

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Work")
        try tasks.move(card.id, toStatus: ids.inProgress)

        let due = try #require(try tasks.task(id: card.id).dueDate)
        #expect(due > clock.now)
    }
}

@Suite("What each kind of card asks for")
struct FieldConfigTests {

    @Test("No configuration means every field shows and none is required")
    func defaultsAreSilent() throws {
        let (database, clock, ids) = try fixture()
        let configs = FieldConfigRepository(database: database, clock: clock)
        let tasks = TaskRepository(database: database, clock: clock)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Bare")
        #expect(try configs.configurations(inProject: ids.project, forType: 2).isEmpty)
        #expect(try configs.isShown(.builtIn("due"), forType: 2, inProject: ids.project))
        #expect(try configs.missingRequired(forTask: card.id).isEmpty)
    }

    @Test("A required field is reported missing until it is filled in")
    func requiredFields() throws {
        let (database, clock, ids) = try fixture()
        let configs = FieldConfigRepository(database: database, clock: clock)
        let tasks = TaskRepository(database: database, clock: clock)
        let people = PersonRepository(database: database, clock: clock)

        try configs.set(
            inProject: ids.project, forType: 3, field: .builtIn("environment"),
            shown: true, required: true, defaultValue: ""
        )

        // A bug — type 3 — is asked for an environment; a task is not.
        let bug = try tasks.create(
            inProject: ids.project, statusID: ids.toDo, title: "Crashes", type: .bug
        )
        let chore = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Tidy up")

        #expect(try configs.missingRequired(forTask: bug.id) == ["environment"])
        #expect(try configs.missingRequired(forTask: chore.id).isEmpty)

        try tasks.setEnvironment("Safari 18, staging", for: bug.id)
        #expect(try configs.missingRequired(forTask: bug.id).isEmpty)
        _ = people
    }

    @Test("A hidden field cannot also be required")
    func hiddenCannotBeRequired() throws {
        let (database, clock, ids) = try fixture()
        let configs = FieldConfigRepository(database: database, clock: clock)
        // There would be no way to fill it in.
        #expect(throws: (any Error).self) {
            try configs.set(
                inProject: ids.project, forType: 2, field: .builtIn("due"),
                shown: false, required: true, defaultValue: ""
            )
        }
    }

    @Test("A configuration that says nothing is not stored at all")
    func silentConfigurationsAreDeleted() throws {
        let (database, clock, ids) = try fixture()
        let configs = FieldConfigRepository(database: database, clock: clock)

        try configs.set(
            inProject: ids.project, forType: 2, field: .builtIn("due"),
            shown: true, required: true, defaultValue: ""
        )
        #expect(try configs.configurations(inProject: ids.project, forType: 2).count == 1)

        // Back to the default: shown, not required, no default. The row goes,
        // so the table holds only decisions somebody actually made.
        try configs.set(
            inProject: ids.project, forType: 2, field: .builtIn("due"),
            shown: true, required: false, defaultValue: ""
        )
        #expect(try configs.configurations(inProject: ids.project, forType: 2).isEmpty)
    }

    @Test("Defaults are applied to a new card of that kind")
    func defaultsApply() throws {
        let (database, clock, ids) = try fixture()
        let configs = FieldConfigRepository(database: database, clock: clock)
        let tasks = TaskRepository(database: database, clock: clock)

        try configs.set(
            inProject: ids.project, forType: 3, field: .builtIn("due"),
            shown: true, required: false, defaultValue: "+3d"
        )

        let bug = try tasks.create(
            inProject: ids.project, statusID: ids.toDo, title: "Crashes", type: .bug
        )
        try configs.applyDefaults(toTask: bug.id)

        let due = try #require(try tasks.task(id: bug.id).dueDate)
        #expect(due > clock.now)

        // A card of another kind takes nothing.
        let chore = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Tidy")
        try configs.applyDefaults(toTask: chore.id)
        #expect(try tasks.task(id: chore.id).dueDate == nil)
    }
}
