import Foundation
import Testing
import LocalBoardCore
import LocalBoardStore
@testable import LocalBoardUI

@MainActor
private func board() throws -> BoardViewModel {
    let model = BoardViewModel(database: try makeDatabase())
    model.load()
    return model
}

@MainActor
@Suite("Goals on a live board")
struct GoalsModelTests {

    @Test("A goal appears on the board it was made on")
    func creating() throws {
        let model = try board()
        model.createGoal(named: "Ship it", kind: .number, target: 10)

        #expect(model.goals.map(\.name) == ["Ship it"])
        #expect(model.failure == nil)
    }

    @Test("A folder groups goals, and loose ones stay reachable")
    func folders() throws {
        let model = try board()
        model.createGoalFolder(named: "This quarter")
        let folder = try #require(model.goalFolders.first)

        model.createGoal(named: "In a folder", kind: .number, target: 5, folderID: folder.id)
        model.createGoal(named: "Loose", kind: .number, target: 5)

        #expect(model.goals(inFolder: folder.id).map(\.name) == ["In a folder"])
        #expect(model.goals(inFolder: nil).map(\.name) == ["Loose"])
    }

    @Test("Typing a figure moves the bar; an automatic goal refuses to be typed into")
    func updatingTheFigure() throws {
        let model = try board()
        model.createGoal(named: "Revenue", kind: .currency, target: 1_000)
        let goal = try #require(model.goals.first)

        model.setGoalCurrent(250, for: goal.id)
        #expect(model.goals.first?.fraction == 0.25)

        model.createGoal(named: "Finish", kind: .tasksCompleted, target: 4)
        let automatic = try #require(model.goals.first { $0.kind == .tasksCompleted })
        model.setGoalCurrent(3, for: automatic.id)
        // Reported rather than silently ignored: the figure comes from the
        // cards, and saying so is the only honest answer.
        #expect(model.failure != nil)
    }

    @Test("A goal counting cards follows the board")
    func automaticGoalFollowsTheBoard() throws {
        let model = try board()
        let columns = model.visibleColumns
        let toDo = try #require(columns.first?.status.id)
        let done = try #require(columns.last?.status.id)

        model.addTask(title: "The work", toStatus: toDo)
        let card = try #require(model.visibleTasks.first { $0.title == "The work" })

        model.createGoal(named: "Finish it", kind: .tasksCompleted, target: 1)
        #expect(model.goals.first?.current == 0)

        model.move(card.id, toStatus: done)
        model.refreshGoals()
        #expect(model.goals.first?.isMet == true)
    }

    @Test("Deleting a goal takes it off the screen")
    func deleting() throws {
        let model = try board()
        model.createGoal(named: "Temporary", kind: .number, target: 3)
        let goal = try #require(model.goals.first)

        model.deleteGoal(goal.id)
        #expect(model.goals.isEmpty)
    }
}

@MainActor
@Suite("Dashboards on a live board")
struct DashboardModelTests {

    @Test("A new dashboard arrives with widgets already on it")
    func starter() throws {
        let model = try board()
        let id = try #require(model.createDashboard(named: "Overview"))

        #expect(model.dashboards.map(\.name) == ["Overview"])
        #expect(model.widgets(on: id).count == 4)
    }

    @Test("Adding and removing a widget is visible immediately")
    func addingWidgets() throws {
        let model = try board()
        let id = try #require(model.createDashboard(named: "Mine", withStarterWidgets: false))
        #expect(model.widgets(on: id).isEmpty)

        model.addWidget(.note, to: id, title: "A note")
        let widget = try #require(model.widgets(on: id).first)
        #expect(widget.displayTitle == "A note")

        model.removeWidget(widget.id)
        #expect(model.widgets(on: id).isEmpty)
    }

    @Test("Dragging a widget keeps the new order across a reload")
    func reordering() throws {
        let model = try board()
        let id = try #require(model.createDashboard(named: "Mine", withStarterWidgets: false))
        for title in ["A", "B", "C"] { model.addWidget(.taskCount, to: id, title: title) }

        model.moveWidget(on: id, from: 0, to: 3, columns: 3)
        #expect(model.widgets(on: id).map(\.title) == ["B", "C", "A"])

        model.load()
        #expect(model.widgets(on: id).map(\.title) == ["B", "C", "A"])
    }

    @Test("A widget reads what its query matches")
    func widgetData() throws {
        let model = try board()
        let toDo = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Open one", toStatus: toDo)

        let id = try #require(model.createDashboard(named: "Mine", withStarterWidgets: false))
        model.addWidget(.taskCount, to: id, query: "is:open")
        let widget = try #require(model.widgets(on: id).first)

        guard case .count(let matching, _) = model.widgetData(widget) else {
            Issue.record("Expected a count.")
            return
        }
        #expect(matching >= 1)
    }
}

@MainActor
@Suite("The new field kinds on a live board")
struct ComputedFieldModelTests {

    @Test("A money field reads with its currency wherever it is shown")
    func moneyDisplay() throws {
        let model = try board()
        model.createCustomField(
            named: "Cost", kind: .money, currency: "GBP", progressMode: .manual,
            targetListID: nil, formula: "", rollupSource: .subtasks,
            rollupLinkID: nil, rollupFieldID: nil, rollupFunction: .sum
        )
        let field = try #require(model.customFields.first { $0.name == "Cost" })

        let toDo = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Billable work", toStatus: toDo)
        let task = try #require(model.visibleTasks.first { $0.title == "Billable work" })

        model.setCustomValue(.number(120), forField: field.id, on: task.id)
        let refreshed = try #require(model.visibleTasks.first { $0.id == task.id })
        #expect(model.display(field, for: refreshed) == "GBP 120")
    }

    @Test("A rating reads as stars")
    func ratingDisplay() throws {
        let model = try board()
        model.createCustomField(
            named: "Value", kind: .rating, currency: "USD", progressMode: .manual,
            targetListID: nil, formula: "", rollupSource: .subtasks,
            rollupLinkID: nil, rollupFieldID: nil, rollupFunction: .sum
        )
        let field = try #require(model.customFields.first { $0.name == "Value" })

        let toDo = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Rated", toStatus: toDo)
        let task = try #require(model.visibleTasks.first { $0.title == "Rated" })

        model.setCustomValue(.number(3), forField: field.id, on: task.id)
        let refreshed = try #require(model.visibleTasks.first { $0.id == task.id })
        #expect(model.display(field, for: refreshed) == "★★★")
    }

    @Test("A formula is worked out for the card it is shown on")
    func formulaDisplay() throws {
        let model = try board()
        model.createCustomField(
            named: "Points", kind: .number, currency: "USD", progressMode: .manual,
            targetListID: nil, formula: "", rollupSource: .subtasks,
            rollupLinkID: nil, rollupFieldID: nil, rollupFunction: .sum
        )
        model.createCustomField(
            named: "Doubled", kind: .formula, currency: "USD", progressMode: .manual,
            targetListID: nil, formula: "{Points} * 2", rollupSource: .subtasks,
            rollupLinkID: nil, rollupFieldID: nil, rollupFunction: .sum
        )
        let points = try #require(model.customFields.first { $0.name == "Points" })
        let doubled = try #require(model.customFields.first { $0.name == "Doubled" })

        let toDo = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Sized", toStatus: toDo)
        let task = try #require(model.visibleTasks.first { $0.title == "Sized" })

        model.setCustomValue(.number(4), forField: points.id, on: task.id)
        #expect(model.computedValue(doubled.id, for: task.id) == .number(8))
    }

    @Test("A formula that will not parse is reported rather than saved")
    func badFormulaIsReported() throws {
        let model = try board()
        model.createCustomField(
            named: "Broken", kind: .formula, currency: "USD", progressMode: .manual,
            targetListID: nil, formula: "1 +", rollupSource: .subtasks,
            rollupLinkID: nil, rollupFieldID: nil, rollupFunction: .sum
        )
        #expect(model.failure != nil)
        #expect(!model.customFields.contains { $0.name == "Broken" })
    }

    @Test("A formula can be tried against a real card before it is saved")
    func preview() throws {
        let model = try board()
        model.createCustomField(
            named: "Points", kind: .number, currency: "USD", progressMode: .manual,
            targetListID: nil, formula: "", rollupSource: .subtasks,
            rollupLinkID: nil, rollupFieldID: nil, rollupFunction: .sum
        )
        let points = try #require(model.customFields.first { $0.name == "Points" })
        let toDo = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Sized", toStatus: toDo)
        let task = try #require(model.visibleTasks.first { $0.title == "Sized" })
        model.setCustomValue(.number(9), forField: points.id, on: task.id)

        #expect(model.previewFormula("{Points} / 3", on: task.id) == "3")
        #expect(model.previewFormula("{Missing} + 1", on: task.id).contains("Missing"))
    }
}

@MainActor
@Suite("Time on a live board")
struct TimeModelTests {

    @Test("Typing into a timesheet cell logs the hours against the card")
    func timesheetEditing() throws {
        let model = try board()
        let toDo = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Timed", toStatus: toDo)
        let task = try #require(model.visibleTasks.first { $0.title == "Timed" })

        let week = TimesheetWeek(containing: Date())
        model.setTimesheetCell(90, task: task.id, day: week.days[0], personID: nil)

        let sheet = model.timesheet(for: week)
        #expect(sheet.total == 90)
        #expect(sheet.rows.first?.minutes[0] == 90)

        // Clearing the cell takes the day's hours off again.
        model.setTimesheetCell(0, task: task.id, day: week.days[0], personID: nil)
        #expect(model.timesheet(for: week).total == 0)
    }

    @Test("Billable hours are counted apart from the rest")
    func billable() throws {
        let model = try board()
        let toDo = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Timed", toStatus: toDo)
        let task = try #require(model.visibleTasks.first { $0.title == "Timed" })
        model.selectedTaskID = task.id

        model.logWork(minutes: 60, note: "", on: Date(), taskID: task.id, billable: true)
        model.logWork(minutes: 30, note: "", on: Date(), taskID: task.id)

        #expect(model.loggedMinutes == 90)
        #expect(model.billableMinutes == 60)

        let entry = try #require(model.workLog.first { $0.billable })
        model.setBillable(false, entry: entry.id)
        #expect(model.billableMinutes == 0)
    }

    @Test("A card that has moved has a time-in-status line for each column")
    func timeInStatus() throws {
        let model = try board()
        let columns = model.visibleColumns
        let toDo = try #require(columns.first?.status.id)
        let done = try #require(columns.last?.status.id)

        model.addTask(title: "Moved", toStatus: toDo)
        let task = try #require(model.visibleTasks.first { $0.title == "Moved" })
        model.move(task.id, toStatus: done)

        let report = model.timeInStatus(forTask: task.id)
        #expect(report.count == 2)
        #expect(report.allSatisfy { $0.seconds >= 0 })
    }
}
