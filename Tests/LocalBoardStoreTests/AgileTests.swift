import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("Fields a project defines for itself")
struct CustomFieldTests {

    @Test("A value comes back as the kind its field declares")
    func typedValues() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let fields = CustomFieldRepository(database: database)

        let size = try fields.create(inProject: ids.project, name: "Size", kind: .number)
        let team = try fields.create(inProject: ids.project, name: "Team", kind: .choice,
                                     options: ["Platform", "Growth"])
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Sized")

        try fields.setValue(.number(8), forField: size.id, onTask: task.id)
        try fields.setValue(.choice("Platform"), forField: team.id, onTask: task.id)

        let values = try fields.values(forTask: task.id)
        #expect(values[size.id] == .number(8))
        #expect(values[team.id] == .choice("Platform"))
    }

    /// Storing a number in the text column would make it invisible to every
    /// numeric read, so the field's declared kind wins over the caller's.
    @Test("A value of the wrong kind is refused, not coerced")
    func wrongKindRefused() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let fields = CustomFieldRepository(database: database)

        let size = try fields.create(inProject: ids.project, name: "Size", kind: .number)
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Sized")

        #expect(throws: LocalBoardError.self) {
            try fields.setValue(.text("eight"), forField: size.id, onTask: task.id)
        }
    }

    @Test("Clearing a value removes it rather than blanking it")
    func clearing() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let fields = CustomFieldRepository(database: database)

        let note = try fields.create(inProject: ids.project, name: "Note", kind: .text)
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Noted")
        try fields.setValue(.text("something"), forField: note.id, onTask: task.id)

        // Deleting the last character means "no answer", not "the empty answer".
        try fields.setValue(.text("   "), forField: note.id, onTask: task.id)

        #expect(try fields.values(forTask: task.id).isEmpty)
    }

    @Test("A choice field needs choices")
    func choiceNeedsOptions() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let fields = CustomFieldRepository(database: database)

        #expect(throws: LocalBoardError.self) {
            try fields.create(inProject: ids.project, name: "Team", kind: .choice, options: [])
        }
    }

    @Test("Deleting a field takes its values with it")
    func deleteCascades() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let fields = CustomFieldRepository(database: database)

        let size = try fields.create(inProject: ids.project, name: "Size", kind: .number)
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Sized")
        try fields.setValue(.number(3), forField: size.id, onTask: task.id)

        try fields.delete(size.id)
        #expect(try database.count("SELECT COUNT(*) FROM custom_field_value;") == 0)
    }

    /// The reason values live in typed columns: `10` must sort above `9`.
    @Test("A number field compares as a number, not as text")
    func numericComparison() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let fields = CustomFieldRepository(database: database)

        let size = try fields.create(inProject: ids.project, name: "Size", kind: .number)
        let big = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Ten")
        let small = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Nine")
        try fields.setValue(.number(10), forField: size.id, onTask: big.id)
        try fields.setValue(.number(9), forField: size.id, onTask: small.id)

        let found = try tasks.tasks(matching: "cf:Size > 9", inProject: ids.project)
        #expect(found.map(\.title) == ["Ten"])
    }

    @Test("cf: reaches text, choice, date and checkbox fields too")
    func queryingEveryKind() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let fields = CustomFieldRepository(database: database)

        let team = try fields.create(inProject: ids.project, name: "Team", kind: .choice,
                                     options: ["Platform", "Growth"])
        let signed = try fields.create(inProject: ids.project, name: "Signed", kind: .checkbox)
        let note = try fields.create(inProject: ids.project, name: "Note", kind: .text)

        let one = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "One")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Two")
        try fields.setValue(.choice("Platform"), forField: team.id, onTask: one.id)
        try fields.setValue(.checkbox(true), forField: signed.id, onTask: one.id)
        try fields.setValue(.text("needs a closer look"), forField: note.id, onTask: one.id)

        #expect(try tasks.tasks(matching: "cf:Team = Platform", inProject: ids.project).count == 1)
        #expect(try tasks.tasks(matching: "cf:Signed = yes", inProject: ids.project).count == 1)
        // Text matches loosely; a choice has to match exactly.
        #expect(try tasks.tasks(matching: "cf:Note = closer", inProject: ids.project).count == 1)
        #expect(try tasks.tasks(matching: "cf:Team = Plat", inProject: ids.project).isEmpty)
        // And "not filled in" is its own question.
        #expect(try tasks.tasks(matching: "cf:Team = none", inProject: ids.project).map(\.title) == ["Two"])
    }

    @Test("A query naming a field that does not exist says so")
    func unknownField() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)

        #expect(throws: QueryError.self) {
            try tasks.tasks(matching: "cf:Nonsense = 3", inProject: ids.project)
        }
    }
}

@Suite("Sprints")
struct SprintTests {

    private func project() throws -> (Database, StoppedClock,
                                      (workspace: String, project: String, board: String,
                                       toDo: String, inProgress: String, done: String)) {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        return (database, clock, try database.seedBoardProject())
    }

    /// The commitment is a fact about a moment. Derived from today's contents
    /// it would move its own starting line whenever work was added, hiding the
    /// one thing a burndown is best at showing.
    @Test("Starting a sprint freezes what it committed to")
    func commitmentIsFrozen() throws {
        let (database, clock, ids) = try project()
        let tasks = TaskRepository(database: database, clock: clock)
        let sprints = SprintRepository(database: database, clock: clock)

        let sprint = try sprints.create(inProject: ids.project, name: "Sprint 1",
                                        startsAt: clock.now, endsAt: clock.now.addingTimeInterval(14 * 86_400))
        let planned = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Planned")
        try tasks.setEstimate(5, for: planned.id)
        try sprints.setSprint(sprint.id, for: planned.id)

        try sprints.start(sprint.id)

        // Added after the start: in the sprint, but not in the commitment.
        let late = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Added later")
        try sprints.setSprint(sprint.id, for: late.id)

        let commitment = try sprints.commitment(ofSprint: sprint.id)
        #expect(commitment.count == 1)
        #expect(commitment.first?.estimate == 5)
        #expect(try sprints.tasks(inSprint: sprint.id).count == 2)
    }

    @Test("Only one sprint runs at a time")
    func oneActiveSprint() throws {
        let (database, clock, ids) = try project()
        let sprints = SprintRepository(database: database, clock: clock)

        let first = try sprints.create(inProject: ids.project, name: "Sprint 1")
        let second = try sprints.create(inProject: ids.project, name: "Sprint 2")
        try sprints.start(first.id)

        #expect(throws: LocalBoardError.self) { try sprints.start(second.id) }
    }

    /// Unfinished work does not evaporate and is not quietly marked done.
    @Test("Completing a sprint carries unfinished work forward")
    func carryOver() throws {
        let (database, clock, ids) = try project()
        let tasks = TaskRepository(database: database, clock: clock)
        let sprints = SprintRepository(database: database, clock: clock)

        let first = try sprints.create(inProject: ids.project, name: "Sprint 1")
        let next = try sprints.create(inProject: ids.project, name: "Sprint 2")

        let done = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Finished")
        let open = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Not finished")
        try sprints.setSprint(first.id, for: done.id)
        try sprints.setSprint(first.id, for: open.id)
        try sprints.start(first.id)
        try tasks.move(done.id, toStatus: ids.done)

        let carried = try sprints.complete(first.id, carryingOverTo: next.id)

        #expect(carried == 1)
        #expect(try tasks.task(id: open.id).sprintID == next.id)
        // The finished card stays where it was: it was done in that sprint.
        #expect(try tasks.task(id: done.id).sprintID == first.id)
        #expect(try tasks.task(id: open.id).completedAt == nil)
    }

    @Test("Completing with nowhere to carry to returns the work to no sprint")
    func carryToBacklog() throws {
        let (database, clock, ids) = try project()
        let tasks = TaskRepository(database: database, clock: clock)
        let sprints = SprintRepository(database: database, clock: clock)

        let sprint = try sprints.create(inProject: ids.project, name: "Sprint 1")
        let open = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Not finished")
        try sprints.setSprint(sprint.id, for: open.id)
        try sprints.start(sprint.id)

        try sprints.complete(sprint.id)

        #expect(try tasks.task(id: open.id).sprintID == nil)
    }

    @Test("A sprint cannot carry over into itself")
    func noSelfCarry() throws {
        let (database, clock, ids) = try project()
        let sprints = SprintRepository(database: database, clock: clock)
        let sprint = try sprints.create(inProject: ids.project, name: "Sprint 1")
        try sprints.start(sprint.id)

        #expect(throws: LocalBoardError.self) {
            try sprints.complete(sprint.id, carryingOverTo: sprint.id)
        }
    }

    /// A sprint still running has not achieved a velocity; counting it would
    /// drag the average down by however much has not happened yet.
    @Test("Velocity counts finished sprints only")
    func velocity() throws {
        let (database, clock, ids) = try project()
        let tasks = TaskRepository(database: database, clock: clock)
        let sprints = SprintRepository(database: database, clock: clock)

        let first = try sprints.create(inProject: ids.project, name: "Sprint 1")
        let done = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Shipped")
        try tasks.setEstimate(8, for: done.id)
        try sprints.setSprint(first.id, for: done.id)
        try sprints.start(first.id)
        try tasks.move(done.id, toStatus: ids.done)
        try sprints.complete(first.id)

        let running = try sprints.create(inProject: ids.project, name: "Sprint 2")
        try sprints.start(running.id)

        let velocity = try sprints.velocity(inProject: ids.project)
        #expect(velocity.count == 1)
        #expect(velocity[0].completedPoints == 8)
        #expect(velocity[0].committedPoints == 8)
    }

    @Test("A burndown measures against the commitment, so added scope shows")
    func burndownShowsScopeCreep() throws {
        let (database, clock, ids) = try project()
        let tasks = TaskRepository(database: database, clock: clock)
        let sprints = SprintRepository(database: database, clock: clock)

        let sprint = try sprints.create(
            inProject: ids.project, name: "Sprint 1",
            startsAt: clock.now, endsAt: clock.now.addingTimeInterval(4 * 86_400)
        )
        let planned = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Planned")
        try tasks.setEstimate(5, for: planned.id)
        try sprints.setSprint(sprint.id, for: planned.id)
        try sprints.start(sprint.id)

        clock.advance(days: 1)
        let extra = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Added")
        try tasks.setEstimate(3, for: extra.id)
        try sprints.setSprint(sprint.id, for: extra.id)
        clock.advance(days: 1)

        let points = try AnalyticsRepository(database: database, clock: clock)
            .burndown(sprint: try sprints.sprint(id: sprint.id))

        // The ideal line starts at what was committed, not at what is there.
        #expect(points.first?.ideal == 5)
        // And the actual line rose above it when work was added.
        #expect(points[1].remaining == 8)
    }
}

@Suite("Workflow rules")
struct WorkflowTests {

    @Test("With enforcement off, every move is allowed")
    func offByDefault() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let workflow = WorkflowRepository(database: database)

        try workflow.allow(from: ids.toDo, to: ids.inProgress, inProject: ids.project)
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Jumping")

        // To Do → Done is not in the list, but nothing is being enforced.
        #expect(throws: Never.self) { try tasks.move(task.id, toStatus: ids.done) }
    }

    /// The failure mode stays on the side of letting work move: a project
    /// half-configured does not trap its own cards.
    @Test("Enforcement with no rules still allows everything")
    func enforcementWithoutRules() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        try WorkflowRepository(database: database).setEnforced(true, inProject: ids.project)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Free")
        #expect(throws: Never.self) { try tasks.move(task.id, toStatus: ids.done) }
    }

    @Test("A forbidden move is refused, not merely reported")
    func refuses() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let workflow = WorkflowRepository(database: database)

        try workflow.allow(from: ids.toDo, to: ids.inProgress, inProject: ids.project)
        try workflow.setEnforced(true, inProject: ids.project)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Bound")

        #expect(throws: LocalBoardError.self) { try tasks.move(task.id, toStatus: ids.done) }
        #expect(throws: Never.self) { try tasks.move(task.id, toStatus: ids.inProgress) }
        // And the card did not move.
        #expect(try tasks.task(id: task.id).statusID == ids.inProgress)
    }

    @Test("Reordering within a column is never a forbidden transition")
    func reorderAlwaysAllowed() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let workflow = WorkflowRepository(database: database)

        try workflow.allow(from: ids.toDo, to: ids.inProgress, inProject: ids.project)
        try workflow.setEnforced(true, inProject: ids.project)

        let first = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "First")
        let second = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Second")

        #expect(throws: Never.self) {
            try tasks.move(second.id, toStatus: ids.toDo, before: first.id)
        }
    }

    @Test("Seeding gives a sequence that can be walked both ways")
    func seeding() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let workflow = WorkflowRepository(database: database)

        try workflow.seedSequentialTransitions(inProject: ids.project)
        try workflow.setEnforced(true, inProject: ids.project)

        #expect(try workflow.permits(from: ids.toDo, to: ids.inProgress, inProject: ids.project))
        #expect(try workflow.permits(from: ids.inProgress, to: ids.toDo, inProject: ids.project))
        // But not skipping a step.
        #expect(!(try workflow.permits(from: ids.toDo, to: ids.done, inProject: ids.project)))
    }
}

@Suite("Automations")
struct AutomationTests {

    @Test("A card reaching a column is assigned by rule")
    func statusTrigger() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let people = PersonRepository(database: database)
        let automations = AutomationRepository(database: database)

        let reviewer = try people.create(name: "Ada")
        try automations.create(
            inProject: ids.project, name: "Assign reviews",
            trigger: .statusChanged, triggerStatusID: ids.inProgress,
            action: .setAssignee, actionValue: reviewer.id
        )

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "To review")
        try tasks.move(task.id, toStatus: ids.inProgress)

        #expect(try tasks.task(id: task.id).assigneeID == reviewer.id)
    }

    @Test("Finishing the last subtask moves the parent")
    func allSubtasksDone() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let automations = AutomationRepository(database: database)

        try automations.create(
            inProject: ids.project, name: "Close finished parents",
            trigger: .allSubtasksDone, action: .moveToStatus, actionValue: ids.done
        )

        let parent = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Parent")
        let childOne = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "One")
        let childTwo = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Two")
        try tasks.setParent(parent.id, for: childOne.id)
        try tasks.setParent(parent.id, for: childTwo.id)

        try tasks.move(childOne.id, toStatus: ids.done)
        #expect(try tasks.task(id: parent.id).statusID == ids.toDo)

        try tasks.move(childTwo.id, toStatus: ids.done)
        #expect(try tasks.task(id: parent.id).statusID == ids.done)
    }

    /// Two rules pointing at each other would otherwise spin forever. The cap
    /// is cheaper to understand than cycle detection, and it is the reason the
    /// board cannot be made to hang by a configuration mistake.
    @Test("A cascade stops rather than running away")
    func cascadeIsCapped() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let automations = AutomationRepository(database: database)

        try automations.create(inProject: ids.project, name: "There",
                               trigger: .statusChanged, triggerStatusID: ids.inProgress,
                               action: .moveToStatus, actionValue: ids.done)
        try automations.create(inProject: ids.project, name: "Back",
                               trigger: .statusChanged, triggerStatusID: ids.done,
                               action: .moveToStatus, actionValue: ids.inProgress)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Ping pong")
        try tasks.move(task.id, toStatus: ids.inProgress)

        // It settled somewhere rather than looping, and the history is finite.
        #expect(try tasks.history(ofTask: task.id).count <= 4)
    }

    @Test("A rule pointing at its own trigger column is refused when made")
    func selfTriggeringRuleRefused() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let automations = AutomationRepository(database: database)

        #expect(throws: LocalBoardError.self) {
            try automations.create(
                inProject: ids.project, name: "Itself",
                trigger: .statusChanged, triggerStatusID: ids.done,
                action: .moveToStatus, actionValue: ids.done
            )
        }
    }

    /// A rule naming someone who has since been deleted should stop working,
    /// not stop the user moving their card.
    @Test("A broken rule does not break the move")
    func brokenRuleIsHarmless() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let automations = AutomationRepository(database: database)

        try automations.create(
            inProject: ids.project, name: "Assign to a ghost",
            trigger: .statusChanged, triggerStatusID: ids.done,
            action: .setAssignee, actionValue: "nobody-at-all"
        )

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Fine")
        #expect(throws: Never.self) { try tasks.move(task.id, toStatus: ids.done) }
        #expect(try tasks.task(id: task.id).statusID == ids.done)
    }

    @Test("A disabled rule does nothing")
    func disabled() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let automations = AutomationRepository(database: database)

        let rule = try automations.create(
            inProject: ids.project, name: "Flag them",
            trigger: .statusChanged, triggerStatusID: ids.done,
            action: .setFlag, actionValue: "check this"
        )
        try automations.setEnabled(false, for: rule.id)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Unflagged")
        try tasks.move(task.id, toStatus: ids.done)

        #expect(!(try tasks.task(id: task.id).flagged))
    }
}

@Suite("Templates")
struct TemplateTests {

    @Test("A card template writes its shape onto a new card")
    func cardTemplate() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let templates = TemplateRepository(database: database)
        let checklists = ChecklistRepository(database: database)
        let labels = LabelRepository(database: database)

        let saved = try templates.saveCardTemplate(
            inProject: ids.project,
            name: "Bug report",
            payload: CardTemplatePayload(
                type: .bug,
                priority: .high,
                descriptionMarkdown: "## Steps\n1. ",
                labelNames: ["needs triage"],
                checklist: ["Reproduced", "Root cause found"]
            )
        )

        let card = try templates.createCard(
            from: saved, titled: "Login fails", inProject: ids.project, statusID: ids.toDo
        )

        #expect(card.title == "Login fails")
        #expect(card.type == .bug)
        #expect(card.priority == .high)
        #expect(try checklists.items(forTask: card.id).count == 2)
        // The label did not exist; a template that silently dropped it would
        // be worse than one that creates it.
        #expect(try labels.labels(forTask: card.id).map(\.name) == ["needs triage"])
    }

    @Test("A template built from a card carries its shape, not its title")
    func fromExistingCard() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let templates = TemplateRepository(database: database)
        let checklists = ChecklistRepository(database: database)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo,
                                    title: "A specific bug", type: .bug, priority: .highest)
        try checklists.add(toTask: card.id, text: "Reproduce")

        let payload = try templates.cardTemplate(from: card)

        #expect(payload.type == .bug)
        #expect(payload.priority == .highest)
        #expect(payload.checklist == ["Reproduce"])
        // Naming every future card after the one it came from would be wrong.
        #expect(payload.titlePrefix == nil)
    }

    @Test("A project template lays out the columns it names and no others")
    func projectTemplate() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let templates = TemplateRepository(database: database)
        let boards = BoardRepository(database: database)

        let saved = try templates.saveProjectTemplate(
            name: "Support",
            payload: ProjectTemplatePayload(
                columns: [
                    .init(name: "Inbox", category: .toDo),
                    .init(name: "Working", category: .inProgress, wipLimit: 3),
                    .init(name: "Answered", category: .done),
                ],
                labels: [.init(name: "urgent", color: "red")]
            )
        )

        let project = try templates.createProject(
            from: saved, named: "Support", key: "SUP", inWorkspace: ids.workspace
        )

        let board = try #require(try boards.boards(inProject: project.id).first)
        let columns = try boards.snapshot(boardID: board.id).columns

        // The three standard columns were replaced, not added to.
        #expect(columns.map(\.name) == ["Inbox", "Working", "Answered"])
        #expect(columns[1].column.wipLimit == 3)
        #expect(try LabelRepository(database: database).labels(inProject: project.id).count == 1)
    }

    @Test("A template written by another version reports rather than crashes")
    func unreadablePayload() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let templates = TemplateRepository(database: database)

        try database.execute(
            """
            INSERT INTO template (id, project_id, kind, name, payload, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            ["broken", ids.project, TemplateKind.card.rawValue, "From the future", "{!!!", Date()]
        )
        let template = try #require(try templates.cardTemplates(inProject: ids.project).first)

        #expect(throws: LocalBoardError.self) { try templates.cardPayload(of: template) }
    }
}

@Suite("The timer")
struct TimerTests {

    @Test("Stopping the timer writes what it measured")
    func stopLogs() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)
        let details = CardDetailRepository(database: database, clock: clock)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Timed")
        try details.startTimer(onTask: task.id)
        clock.now = clock.now.addingTimeInterval(45 * 60)

        let entry = try details.stopTimer()

        #expect(entry?.minutes == 45)
        #expect(try details.totalMinutes(forTask: task.id) == 45)
        #expect(try details.runningTimer() == nil)
    }

    /// Two timers at once would record time that was never spent twice over.
    @Test("Starting a second timer stops and logs the first")
    func onlyOneRuns() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)
        let details = CardDetailRepository(database: database, clock: clock)

        let first = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "First")
        let second = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Second")

        try details.startTimer(onTask: first.id)
        clock.now = clock.now.addingTimeInterval(30 * 60)
        try details.startTimer(onTask: second.id)

        #expect(try details.totalMinutes(forTask: first.id) == 30)
        #expect(try details.runningTimer()?.taskID == second.id)
    }

    @Test("A timer stopped inside a minute logs nothing")
    func tooShortToLog() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)
        let details = CardDetailRepository(database: database, clock: clock)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Brief")
        try details.startTimer(onTask: task.id)
        clock.now = clock.now.addingTimeInterval(4)

        #expect(try details.stopTimer() == nil)
        #expect(try details.workLog(forTask: task.id).isEmpty)
    }

    @Test("A discarded timer logs nothing at all")
    func discarding() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)
        let details = CardDetailRepository(database: database, clock: clock)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Mistake")
        try details.startTimer(onTask: task.id)
        clock.now = clock.now.addingTimeInterval(3_600)

        try details.stopTimer(discarding: true)

        #expect(try details.workLog(forTask: task.id).isEmpty)
        #expect(try details.runningTimer() == nil)
    }
}
