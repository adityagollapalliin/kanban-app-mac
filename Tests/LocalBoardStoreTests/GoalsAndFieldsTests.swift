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

@Suite("Rollups over real cards")
struct RollupStoreTests {

    @Test("A sum gathers the subtasks' values")
    func sumOfSubtasks() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let points = try fields.create(inProject: ids.project, name: "Points", kind: .number)
        let total = try fields.create(
            inProject: ids.project, name: "Total points", kind: .rollup,
            rollupSource: .subtasks, rollupFieldID: points.id, rollupFunction: .sum
        )

        let parent = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Epic")
        for value in [3.0, 5.0, 2.0] {
            let child = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Bit")
            try tasks.setParent(parent.id, for: child.id)
            try fields.setValue(.number(value), forField: points.id, onTask: child.id)
        }

        let computed = ComputedFieldRepository(database: database, clock: clock)
        #expect(try computed.values(inProject: ids.project)[parent.id]?[total.id] == .number(10))
    }

    @Test("An average leaves out the subtasks that answered nothing")
    func averageSkipsBlanks() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let score = try fields.create(inProject: ids.project, name: "Score", kind: .number)
        let mean = try fields.create(
            inProject: ids.project, name: "Mean", kind: .rollup,
            rollupSource: .subtasks, rollupFieldID: score.id, rollupFunction: .average
        )

        let parent = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Parent")
        let filled = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "One")
        let blank = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Two")
        let other = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Three")
        for child in [filled, blank, other] { try tasks.setParent(parent.id, for: child.id) }
        try fields.setValue(.number(4), forField: score.id, onTask: filled.id)
        try fields.setValue(.number(8), forField: score.id, onTask: other.id)

        // 6, not 4: dividing by the card that left it blank would drag the
        // figure down with data nobody entered.
        let computed = ComputedFieldRepository(database: database, clock: clock)
        #expect(try computed.values(inProject: ids.project)[parent.id]?[mean.id] == .number(6))
    }

    @Test("A count counts the cards, values or not")
    func countCountsCards() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let howMany = try fields.create(
            inProject: ids.project, name: "Subtasks", kind: .rollup,
            rollupSource: .subtasks, rollupFunction: .count
        )

        let parent = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Parent")
        for index in 1...3 {
            let child = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Bit \(index)")
            try tasks.setParent(parent.id, for: child.id)
        }

        let computed = ComputedFieldRepository(database: database, clock: clock)
        #expect(try computed.values(inProject: ids.project)[parent.id]?[howMany.id] == .number(3))
    }

    @Test("A card with no subtasks rolls up to blank, not to zero")
    func nothingToRollUp() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let points = try fields.create(inProject: ids.project, name: "Points", kind: .number)
        let total = try fields.create(
            inProject: ids.project, name: "Total", kind: .rollup,
            rollupSource: .subtasks, rollupFieldID: points.id, rollupFunction: .sum
        )

        let lonely = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "On its own")
        let computed = ComputedFieldRepository(database: database, clock: clock)
        #expect(try computed.values(inProject: ids.project)[lonely.id]?[total.id] == .empty)
    }

    @Test("A rollup can follow a relationship field instead of the subtasks")
    func rollupOverRelationship() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let cost = try fields.create(inProject: ids.project, name: "Cost", kind: .money)
        let link = try fields.create(inProject: ids.project, name: "Invoices", kind: .relationship)
        let total = try fields.create(
            inProject: ids.project, name: "Billed", kind: .rollup,
            rollupSource: .relationship, rollupLinkID: link.id,
            rollupFieldID: cost.id, rollupFunction: .sum
        )

        let job = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "The job")
        var linked: [String] = []
        for amount in [120.0, 80.0] {
            let invoice = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Invoice")
            try fields.setValue(.number(amount), forField: cost.id, onTask: invoice.id)
            linked.append(invoice.id)
        }
        try fields.setValue(RelationshipValue.stored(linked), forField: link.id, onTask: job.id)

        let computed = ComputedFieldRepository(database: database, clock: clock)
        #expect(try computed.values(inProject: ids.project)[job.id]?[total.id] == .number(200))
    }

    @Test("A rollup that needs a field but was given none is refused when it is made")
    func rollupNeedsAField() throws {
        let (database, clock, ids) = try fixture()
        let fields = CustomFieldRepository(database: database, clock: clock)
        #expect(throws: (any Error).self) {
            try fields.create(
                inProject: ids.project, name: "Broken", kind: .rollup, rollupFunction: .sum
            )
        }
    }
}

@Suite("Formulas over real cards")
struct FormulaStoreTests {

    @Test("A formula reads the project's own fields")
    func readsCustomFields() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let done = try fields.create(inProject: ids.project, name: "Done", kind: .number)
        let total = try fields.create(inProject: ids.project, name: "Total", kind: .number)
        let percent = try fields.create(
            inProject: ids.project, name: "Percent", kind: .formula,
            formula: "round({Done} / {Total} * 100)"
        )

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Work")
        try fields.setValue(.number(3), forField: done.id, onTask: task.id)
        try fields.setValue(.number(8), forField: total.id, onTask: task.id)

        let computed = ComputedFieldRepository(database: database, clock: clock)
        #expect(try computed.values(inProject: ids.project)[task.id]?[percent.id] == .number(38))
    }

    @Test("A formula can do date arithmetic on the card's own dates")
    func readsBuiltInFields() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let slack = try fields.create(
            inProject: ids.project, name: "Days left", kind: .formula, formula: "days({Due}, today())"
        )

        let task = try tasks.create(
            inProject: ids.project, statusID: ids.toDo, title: "Due soon",
            dueDate: clock.now.addingTimeInterval(3 * 86_400)
        )

        let computed = ComputedFieldRepository(database: database, clock: clock)
        #expect(try computed.values(inProject: ids.project)[task.id]?[slack.id] == .number(3))
    }

    @Test("A formula over a field nobody filled in reads as blank")
    func blankStaysBlank() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        try fields.create(inProject: ids.project, name: "Points", kind: .number)
        let doubled = try fields.create(
            inProject: ids.project, name: "Doubled", kind: .formula, formula: "{Points} * 2"
        )

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Unfilled")
        let computed = ComputedFieldRepository(database: database, clock: clock)
        #expect(try computed.values(inProject: ids.project)[task.id]?[doubled.id] == .empty)
    }

    @Test("A formula can read another formula")
    func formulaOverFormula() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let base = try fields.create(inProject: ids.project, name: "Base", kind: .number)
        try fields.create(inProject: ids.project, name: "Doubled", kind: .formula, formula: "{Base} * 2")
        let quadrupled = try fields.create(
            inProject: ids.project, name: "Quadrupled", kind: .formula, formula: "{Doubled} * 2"
        )

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Chain")
        try fields.setValue(.number(3), forField: base.id, onTask: task.id)

        let computed = ComputedFieldRepository(database: database, clock: clock)
        #expect(try computed.values(inProject: ids.project)[task.id]?[quadrupled.id] == .number(12))
    }

    @Test("A formula that ends up reading itself is blank rather than a hang")
    func circularReference() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        // Each is valid on its own; the cycle only exists once both are there,
        // which is why it has to be caught at evaluation rather than at save.
        let a = try fields.create(inProject: ids.project, name: "A", kind: .formula, formula: "{B} + 1")
        try fields.create(inProject: ids.project, name: "B", kind: .formula, formula: "{A} + 1")

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Round and round")
        let computed = ComputedFieldRepository(database: database, clock: clock)
        #expect(try computed.values(inProject: ids.project)[task.id]?[a.id] == .empty)
    }

    @Test("A formula that will not parse is refused when the field is made")
    func invalidFormulaRefused() throws {
        let (database, clock, ids) = try fixture()
        let fields = CustomFieldRepository(database: database, clock: clock)
        #expect(throws: (any Error).self) {
            try fields.create(inProject: ids.project, name: "Bad", kind: .formula, formula: "1 +")
        }
        #expect(throws: (any Error).self) {
            try fields.create(inProject: ids.project, name: "Empty", kind: .formula, formula: "")
        }
    }

    @Test("Nothing can be written into a computed field")
    func computedFieldsAreReadOnly() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let formula = try fields.create(
            inProject: ids.project, name: "Twice", kind: .formula, formula: "2 * 2"
        )
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Card")
        #expect(throws: (any Error).self) {
            try fields.setValue(.number(9), forField: formula.id, onTask: task.id)
        }
    }

    @Test("A formula field cannot be searched on, and says so")
    func computedFieldsAreNotQueryable() throws {
        let (database, clock, ids) = try fixture()
        let fields = CustomFieldRepository(database: database, clock: clock)
        let tasks = TaskRepository(database: database, clock: clock)
        try fields.create(inProject: ids.project, name: "Twice", kind: .formula, formula: "2 * 2")

        // Returning nothing would let the user conclude their cards vanished.
        #expect(throws: (any Error).self) {
            try tasks.tasks(matching: "cf:Twice = 4", inProject: ids.project)
        }
    }

    @Test("Progress counted off the subtasks follows them being ticked")
    func automaticProgress() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let progress = try fields.create(
            inProject: ids.project, name: "Progress", kind: .progress, progressMode: .subtasks
        )

        let parent = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Parent")
        var children: [BoardTask] = []
        for index in 1...4 {
            let child = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Bit \(index)")
            try tasks.setParent(parent.id, for: child.id)
            children.append(child)
        }

        let computed = ComputedFieldRepository(database: database, clock: clock)
        #expect(try computed.values(inProject: ids.project)[parent.id]?[progress.id] == .number(0))

        try tasks.move(children[0].id, toStatus: ids.done)
        #expect(try computed.values(inProject: ids.project)[parent.id]?[progress.id] == .number(25))
    }

    @Test("A card with nothing to count has no percentage at all")
    func progressWithNothingToCount() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let progress = try fields.create(
            inProject: ids.project, name: "Progress", kind: .progress, progressMode: .subtasks
        )
        let lonely = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "No subtasks")

        // Not 100%: a card with no subtasks has not finished them, it has none.
        let computed = ComputedFieldRepository(database: database, clock: clock)
        #expect(try computed.values(inProject: ids.project)[lonely.id]?[progress.id] == .empty)
    }

    @Test("A formula can be tried against a real card before it is saved")
    func preview() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let fields = CustomFieldRepository(database: database, clock: clock)

        let points = try fields.create(inProject: ids.project, name: "Points", kind: .number)
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Card")
        try fields.setValue(.number(6), forField: points.id, onTask: task.id)

        let computed = ComputedFieldRepository(database: database, clock: clock)
        let good = try computed.preview(formula: "{Points} / 2", forTask: task.id, inProject: ids.project)
        #expect(good == .success(.number(3)))

        let bad = try computed.preview(formula: "{Nope} + 1", forTask: task.id, inProject: ids.project)
        #expect(bad == .failure(.unknownField("Nope")))
    }
}

@Suite("Goals")
struct GoalStoreTests {

    @Test("A goal counting finished cards starts at where it already is")
    func automaticGoalCounts() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)

        let first = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "One")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Two")
        try tasks.move(first.id, toStatus: ids.done)

        let goals = GoalRepository(database: database, clock: clock)
        let goal = try goals.create(
            inProject: ids.project, name: "Ship it", kind: .tasksCompleted, target: 2
        )
        #expect(goal.current == 1)
        #expect(goal.fraction == 0.5)
    }

    @Test("Recounting picks up work finished since")
    func refresh() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let goals = GoalRepository(database: database, clock: clock)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "One")
        let goal = try goals.create(
            inProject: ids.project, name: "Ship it", kind: .tasksCompleted, target: 1
        )
        #expect(goal.current == 0)

        try tasks.move(card.id, toStatus: ids.done)
        try goals.refresh(goal.id)

        let after = try goals.goal(id: goal.id)
        #expect(after.current == 1)
        #expect(after.isMet)
        #expect(after.completedAt != nil)
    }

    @Test("A goal can watch a query rather than the whole space")
    func goalWithQuery() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let goals = GoalRepository(database: database, clock: clock)

        let bug = try tasks.create(
            inProject: ids.project, statusID: ids.toDo, title: "A bug", type: .bug
        )
        let chore = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "A chore")
        try tasks.move(bug.id, toStatus: ids.done)
        try tasks.move(chore.id, toStatus: ids.done)

        let goal = try goals.create(
            inProject: ids.project, name: "Clear the bugs", kind: .tasksCompleted,
            target: 1, query: "type:bug"
        )
        // One, not two: the chore is not what this goal is about.
        #expect(goal.current == 1)
    }

    @Test("A figure kept by hand is typed in; an automatic one refuses to be")
    func manualAndAutomatic() throws {
        let (database, clock, ids) = try fixture()
        let goals = GoalRepository(database: database, clock: clock)

        let manual = try goals.create(
            inProject: ids.project, name: "Revenue", kind: .currency, target: 10_000
        )
        try goals.setCurrent(4_000, for: manual.id)
        #expect(try goals.goal(id: manual.id).current == 4_000)

        let automatic = try goals.create(
            inProject: ids.project, name: "Ship", kind: .tasksCompleted, target: 5
        )
        #expect(throws: (any Error).self) { try goals.setCurrent(3, for: automatic.id) }
    }

    @Test("Reaching the target records when it happened, and going back undoes it")
    func completion() throws {
        let (database, clock, ids) = try fixture()
        let goals = GoalRepository(database: database, clock: clock)
        let goal = try goals.create(inProject: ids.project, name: "Save up", target: 100)

        try goals.setCurrent(100, for: goal.id)
        #expect(try goals.goal(id: goal.id).completedAt != nil)

        // Money spent again is a goal no longer met, and the date it was met
        // is no longer true.
        try goals.setCurrent(50, for: goal.id)
        #expect(try goals.goal(id: goal.id).completedAt == nil)
    }

    @Test("A goal with nothing to reach is refused")
    func degenerateGoal() throws {
        let (database, clock, ids) = try fixture()
        let goals = GoalRepository(database: database, clock: clock)
        #expect(throws: (any Error).self) {
            try goals.create(inProject: ids.project, name: "Nothing", target: 0, start: 0)
        }
    }

    @Test("Deleting a folder tidies it away without taking the goals with it")
    func deletingAFolder() throws {
        let (database, clock, ids) = try fixture()
        let goals = GoalRepository(database: database, clock: clock)

        let folder = try goals.createFolder(inProject: ids.project, named: "This quarter")
        let goal = try goals.create(
            inProject: ids.project, name: "Ship", target: 3, folderID: folder.id
        )

        try goals.deleteFolder(folder.id)
        let after = try goals.goal(id: goal.id)
        #expect(after.folderID == nil)
        #expect(try goals.goals(inProject: ids.project).count == 1)
    }

    @Test("Archived goals are out of the way but not gone")
    func archiving() throws {
        let (database, clock, ids) = try fixture()
        let goals = GoalRepository(database: database, clock: clock)
        let goal = try goals.create(inProject: ids.project, name: "Old", target: 1)

        try goals.setArchived(true, for: goal.id)
        #expect(try goals.goals(inProject: ids.project).isEmpty)
        #expect(try goals.goals(inProject: ids.project, includingArchived: true).count == 1)
    }
}

@Suite("Dashboards")
struct DashboardStoreTests {

    @Test("A new dashboard opens with something on it")
    func starterWidgets() throws {
        let (database, clock, ids) = try fixture()
        let dashboards = DashboardRepository(database: database, clock: clock)
        let dashboard = try dashboards.createStarter(inProject: ids.project)
        // An empty grid with an "Add widget" button teaches nothing about what
        // a widget is.
        #expect(try dashboards.widgets(on: dashboard.id).count == 4)
    }

    @Test("Widgets keep their arrangement across a reload")
    func layoutPersists() throws {
        let (database, clock, ids) = try fixture()
        let dashboards = DashboardRepository(database: database, clock: clock)
        let dashboard = try dashboards.create(inProject: ids.project, named: "Mine")

        try dashboards.addWidget(to: dashboard.id, kind: .taskCount, title: "A")
        try dashboards.addWidget(to: dashboard.id, kind: .taskCount, title: "B")
        try dashboards.addWidget(to: dashboard.id, kind: .taskCount, title: "C")

        let original = try dashboards.widgets(on: dashboard.id)
        let moved = DashboardLayout.reorder(original, from: 0, to: 3)
        try dashboards.saveLayout(moved, columns: 3)

        #expect(try dashboards.widgets(on: dashboard.id).map(\.title) == ["B", "C", "A"])
    }

    @Test("A widget's query drives what it counts")
    func widgetCounting() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let dashboards = DashboardRepository(database: database, clock: clock)

        let done = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Finished")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Open one")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Open two")
        try tasks.move(done.id, toStatus: ids.done)

        let dashboard = try dashboards.create(inProject: ids.project, named: "Mine")
        let widget = try dashboards.addWidget(to: dashboard.id, kind: .taskCount, query: "is:open")

        let data = DashboardDataRepository(database: database, clock: clock)
        #expect(try data.data(for: widget, inProject: ids.project) == .count(2, of: 3))
    }

    @Test("A widget with a broken query says so instead of taking the page down")
    func brokenQuery() throws {
        let (database, clock, ids) = try fixture()
        let dashboards = DashboardRepository(database: database, clock: clock)
        let dashboard = try dashboards.create(inProject: ids.project, named: "Mine")
        let widget = try dashboards.addWidget(
            to: dashboard.id, kind: .taskCount, query: "cf:Nonexistent > 3"
        )

        let data = DashboardDataRepository(database: database, clock: clock)
        guard case .unavailable = try data.data(for: widget, inProject: ids.project) else {
            Issue.record("A broken query should report itself, not return a count.")
            return
        }
    }

    @Test("A status breakdown names every column, empty ones included")
    func statusBreakdown() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let dashboards = DashboardRepository(database: database, clock: clock)

        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "One")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Two")

        let dashboard = try dashboards.create(inProject: ids.project, named: "Mine")
        let widget = try dashboards.addWidget(to: dashboard.id, kind: .statusBreakdown)

        let data = DashboardDataRepository(database: database, clock: clock)
        let result = try data.data(for: widget, inProject: ids.project)
        guard case .breakdown(let slices) = result else {
            Issue.record("Expected a breakdown, got \(result)")
            return
        }
        // A board with nothing in Review is telling you something.
        #expect(slices.count == 3)
        #expect(slices[0].value == 2)
        #expect(slices[1].value == 0)
    }

    @Test("Deleting a dashboard takes its widgets with it")
    func cascade() throws {
        let (database, clock, ids) = try fixture()
        let dashboards = DashboardRepository(database: database, clock: clock)
        let dashboard = try dashboards.createStarter(inProject: ids.project)

        try dashboards.delete(dashboard.id)
        #expect(try database.count("SELECT COUNT(*) FROM dashboard_widget;") == 0)
    }
}
