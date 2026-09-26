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

/// Proof that the workflow features are *wired*, not merely implemented.
///
/// Milestone 8.5c shipped four of these configurable and inert: the repository
/// method existed, the settings UI wrote the configuration, and nothing ever
/// read it. Each test here fails if its feature goes back to being a setting
/// that does nothing.
@MainActor
@Suite("The workflow rules actually bite")
struct WorkflowWiringTests {

    /// Allows a move and returns it, so a test can hang rules on it.
    private func transition(
        _ model: BoardViewModel, from: String, to: String
    ) throws -> WorkflowTransition {
        model.setTransition(from: from, to: to, allowed: true)
        return try #require(model.transitions.first {
            $0.fromStatusID == from && $0.toStatusID == to
        })
    }

    @Test("A condition hides the move from the status menu")
    func conditionsHideMoves() throws {
        let model = try board()
        let columns = model.visibleColumns
        let toDo = try #require(columns.first?.status.id)
        let done = try #require(columns.last?.status.id)

        let move = try transition(model, from: toDo, to: done)
        model.addTransitionRule(
            .allSubtasksDone, to: move.id, target: "", value: "", query: "", syntax: .simple
        )

        model.addTask(title: "Parent", toStatus: toDo)
        let parent = try #require(model.visibleTasks.first { $0.title == "Parent" })
        model.addSubtask("Child", to: parent.id)

        let reloaded = try #require(model.visibleTasks.first { $0.id == parent.id })
        // The subtask is outstanding, so Done is not on the menu at all.
        #expect(!model.offeredStatuses(for: reloaded).contains { $0.id == done })

        let child = try #require(model.visibleTasks.first { $0.title == "Child" })
        model.move(child.id, toStatus: done)

        let after = try #require(model.visibleTasks.first { $0.id == parent.id })
        #expect(model.offeredStatuses(for: after).contains { $0.id == done })
    }

    @Test("A card's own column is always on the menu")
    func ownColumnAlwaysOffered() throws {
        let model = try board()
        let toDo = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Somewhere", toStatus: toDo)
        let task = try #require(model.visibleTasks.first { $0.title == "Somewhere" })

        // Otherwise the picker would have no way to show where the card is.
        #expect(model.offeredStatuses(for: task).contains { $0.id == toDo })
    }

    @Test("A transition with a screen parks the move instead of making it")
    func screenParksTheMove() throws {
        let model = try board()
        let columns = model.visibleColumns
        let toDo = try #require(columns.first?.status.id)
        let doing = try #require(columns.dropFirst().first?.status.id)

        let move = try transition(model, from: toDo, to: doing)
        model.updateTransition(
            move.id, name: "Start work", screenTitle: "Before starting",
            screenFields: [.builtIn("assignee")]
        )

        model.addTask(title: "Work", toStatus: toDo)
        let task = try #require(model.visibleTasks.first { $0.title == "Work" })

        model.move(task.id, toStatus: doing)

        // Parked, not moved — nothing is written until the sheet is submitted.
        #expect(model.pendingTransition?.taskID == task.id)
        #expect(try #require(model.visibleTasks.first { $0.id == task.id }).statusID == toDo)
    }

    @Test("Submitting the screen fills the field in and completes the move")
    func screenCompletesTheMove() throws {
        let model = try board()
        let columns = model.visibleColumns
        let toDo = try #require(columns.first?.status.id)
        let doing = try #require(columns.dropFirst().first?.status.id)

        let move = try transition(model, from: toDo, to: doing)
        model.updateTransition(
            move.id, name: "Start work", screenTitle: "", screenFields: [.builtIn("assignee")]
        )
        model.createPerson(named: "Ada Lovelace")
        let ada = try #require(model.people.first { $0.name == "Ada Lovelace" })

        model.addTask(title: "Work", toStatus: toDo)
        let task = try #require(model.visibleTasks.first { $0.title == "Work" })
        model.move(task.id, toStatus: doing)

        model.completePendingTransition([.builtIn("assignee"): ada.id])

        let after = try #require(model.visibleTasks.first { $0.id == task.id })
        #expect(after.statusID == doing)
        #expect(after.assigneeID == ada.id)
        #expect(model.pendingTransition == nil)
    }

    @Test("Cancelling the screen leaves the card exactly where it was")
    func cancellingChangesNothing() throws {
        let model = try board()
        let columns = model.visibleColumns
        let toDo = try #require(columns.first?.status.id)
        let doing = try #require(columns.dropFirst().first?.status.id)

        let move = try transition(model, from: toDo, to: doing)
        model.updateTransition(
            move.id, name: "", screenTitle: "", screenFields: [.builtIn("assignee")]
        )

        model.addTask(title: "Work", toStatus: toDo)
        let task = try #require(model.visibleTasks.first { $0.title == "Work" })
        model.move(task.id, toStatus: doing)
        model.cancelPendingTransition()

        let after = try #require(model.visibleTasks.first { $0.id == task.id })
        #expect(after.statusID == toDo)
        #expect(after.assigneeID == nil)
        #expect(model.pendingTransition == nil)
    }

    @Test("A screen whose fields are already answered does not appear")
    func answeredScreenIsSkipped() throws {
        let model = try board()
        let columns = model.visibleColumns
        let toDo = try #require(columns.first?.status.id)
        let doing = try #require(columns.dropFirst().first?.status.id)

        let move = try transition(model, from: toDo, to: doing)
        model.updateTransition(
            move.id, name: "", screenTitle: "", screenFields: [.builtIn("assignee")]
        )
        model.createPerson(named: "Ada Lovelace")
        let ada = try #require(model.people.first { $0.name == "Ada Lovelace" })

        model.addTask(title: "Work", toStatus: toDo)
        let task = try #require(model.visibleTasks.first { $0.title == "Work" })
        model.setAssignee(ada.id, for: task.id)

        model.move(task.id, toStatus: doing)

        // Asking for something the card already carries is a dialog nobody
        // learns anything from.
        #expect(model.pendingTransition == nil)
        #expect(try #require(model.visibleTasks.first { $0.id == task.id }).statusID == doing)
    }

    @Test("A required field this kind of card lacks is reported on the card")
    func missingRequiredIsSurfaced() throws {
        let model = try board()
        let toDo = try #require(model.visibleColumns.first?.status.id)

        model.setFieldConfiguration(
            forType: 3, field: .builtIn("environment"),
            shown: true, required: true, defaultValue: ""
        )

        model.addTask(title: "Crashes", toStatus: toDo)
        let card = try #require(model.visibleTasks.first { $0.title == "Crashes" })
        model.setIssueTypeCode(3, on: card.id)

        let bug = try #require(model.visibleTasks.first { $0.id == card.id })
        #expect(model.missingRequired(for: bug) == ["environment"])

        model.setEnvironment("Safari 18, staging", on: bug.id)
        let fixed = try #require(model.visibleTasks.first { $0.id == card.id })
        #expect(model.missingRequired(for: fixed).isEmpty)
    }

    @Test("A new card of a kind with defaults gets them")
    func defaultsApplyToNewCards() throws {
        let model = try board()
        let toDo = try #require(model.visibleColumns.first?.status.id)

        model.setFieldConfiguration(
            forType: 2, field: .builtIn("environment"),
            shown: true, required: false, defaultValue: "Staging"
        )

        model.addTask(title: "Ordinary work", toStatus: toDo)
        let card = try #require(model.visibleTasks.first { $0.title == "Ordinary work" })
        #expect(card.environment == "Staging")
    }
}
