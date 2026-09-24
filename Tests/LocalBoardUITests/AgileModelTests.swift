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
private func boardWithCards(_ titles: [String]) throws -> BoardViewModel {
    let model = try board()
    let status = try #require(model.visibleColumns.first?.status.id)
    for title in titles { model.addTask(title: title, toStatus: status) }
    return model
}

@MainActor
@Suite("The lasso")
struct LassoTests {

    @Test("A band covers what it overlaps and nothing else")
    func covers() {
        let lasso = Lasso(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 110, y: 110))

        #expect(lasso.covers(CGRect(x: 50, y: 50, width: 20, height: 20)))
        // Touching at the edge counts: a card half under the band was dragged over.
        #expect(lasso.covers(CGRect(x: 100, y: 100, width: 40, height: 40)))
        #expect(!lasso.covers(CGRect(x: 200, y: 200, width: 20, height: 20)))
    }

    /// A stray click is not a lasso, and treating one as a zero-size band
    /// would clear the selection on every click that misses a card by a pixel.
    @Test("A click is not a lasso")
    func tinyDragIsAClick() {
        let click = Lasso(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 12, y: 11))
        #expect(!click.isMeaningful)

        let drag = Lasso(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 40, y: 11))
        #expect(drag.isMeaningful)
    }

    @Test("A band drawn upwards is the same band")
    func normalised() {
        let downwards = Lasso(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 50, y: 50))
        let upwards = Lasso(start: CGPoint(x: 50, y: 50), current: CGPoint(x: 10, y: 10))
        #expect(downwards.rect == upwards.rect)
    }

    @Test("Picking adds to or replaces the selection")
    func picking() throws {
        let model = try boardWithCards(["A", "B", "C"])
        let ids = try #require(model.visibleColumns.first?.tasks.map(\.id))

        model.pick([ids[0]], adding: false)
        #expect(model.selectedTaskIDs == [ids[0]])

        model.pick([ids[1]], adding: true)
        #expect(model.selectedTaskIDs == Set([ids[0], ids[1]]))

        model.pick([ids[2]], adding: false)
        #expect(model.selectedTaskIDs == [ids[2]])
    }
}

@MainActor
@Suite("Undo and redo")
struct UndoTests {

    @Test("Nothing to undo on a fresh board")
    func startsEmpty() throws {
        let model = try board()
        #expect(!model.canUndo)
        #expect(!model.canRedo)
    }

    @Test("An ordinary edit can be undone and redone")
    func singleEdit() throws {
        let model = try boardWithCards(["Original"])
        let task = try #require(model.visibleColumns.first?.tasks.first)

        model.rename(task.id, to: "Changed")
        #expect(model.visibleColumns.first?.tasks.first?.title == "Changed")
        #expect(model.canUndo)
        #expect(model.undoLabel == "Rename")

        model.undo()
        #expect(model.visibleColumns.first?.tasks.first?.title == "Original")
        #expect(model.canRedo)

        model.redo()
        #expect(model.visibleColumns.first?.tasks.first?.title == "Changed")
    }

    @Test("Undo walks back through several edits in order")
    func stack() throws {
        let model = try boardWithCards(["Card"])
        let task = try #require(model.visibleColumns.first?.tasks.first)

        model.setPriority(.high, for: task.id)
        model.setPriority(.highest, for: task.id)

        model.undo()
        #expect(model.visibleColumns.first?.tasks.first?.priority == .high)

        model.undo()
        #expect(model.visibleColumns.first?.tasks.first?.priority == .normal)
        #expect(!model.canUndo)
    }

    /// A new edit means the future the redo stack led to is no longer the one
    /// the user is in.
    @Test("A new edit after undoing clears redo")
    func newEditClearsRedo() throws {
        let model = try boardWithCards(["Card"])
        let task = try #require(model.visibleColumns.first?.tasks.first)

        model.setPriority(.high, for: task.id)
        model.undo()
        #expect(model.canRedo)

        model.setPriority(.low, for: task.id)
        #expect(!model.canRedo)
    }

    @Test("Moving a card between columns can be undone")
    func undoMove() throws {
        let model = try boardWithCards(["Travelling"])
        let task = try #require(model.visibleColumns.first?.tasks.first)
        let destination = try #require(model.visibleColumns.dropFirst().first)

        model.move(task.id, toStatus: destination.status.id)
        #expect(model.visibleColumns[1].tasks.count == 1)

        model.undo()
        #expect(model.visibleColumns[0].tasks.count == 1)
        #expect(model.visibleColumns[1].tasks.isEmpty)
    }

    @Test("A bulk edit goes on the same stack as an ordinary one")
    func bulkAndSingleShareTheStack() throws {
        let model = try boardWithCards(["A", "B"])
        model.pickAll()
        model.bulkPriority(.highest)

        #expect(model.canUndo)
        model.undo()
        #expect(model.visibleColumns.first?.tasks.allSatisfy { $0.priority == .normal } == true)
    }
}

@MainActor
@Suite("The command palette")
struct PaletteTests {

    private func result(_ title: String, keywords: String = "") -> PaletteResult {
        PaletteResult(id: title, title: title, symbol: "star", keywords: keywords) {}
    }

    /// Someone typing expects what they typed at the top. Database order is
    /// how a palette stops being used on the second try.
    @Test("An exact match outranks a prefix, which outranks a match in the middle")
    func ranking() {
        let query = "board"

        #expect(result("Board").score(for: query) > result("Board Settings").score(for: query))
        #expect(result("Board Settings").score(for: query) > result("Go to Board").score(for: query))
        #expect(result("Go to Board").score(for: query) > result("Nothing").score(for: query))
    }

    @Test("A word beginning outranks a match buried inside one")
    func wordBoundary() {
        #expect(result("Go to Sprints").score(for: "spr") > result("Unsprinted").score(for: "spr"))
    }

    @Test("Keywords match when the title does not")
    func keywords() {
        let entry = result("Go to Timeline", keywords: "gantt schedule")
        #expect(entry.matches("gantt"))
        #expect(entry.score(for: "gantt") > 0)
        #expect(!entry.matches("nonsense"))
    }

    @Test("An empty query matches everything")
    func emptyQuery() {
        #expect(result("Anything").matches(""))
    }
}

@MainActor
@Suite("Sprints on a live board")
struct SprintModelTests {

    @Test("Starting a sprint makes it the active one")
    func starting() throws {
        let model = try boardWithCards(["Work"])
        model.createSprint(named: "Sprint 1", goal: "Ship it", from: Date(), to: Date().addingTimeInterval(86_400 * 14))
        let sprint = try #require(model.sprints.first)

        model.startSprint(sprint.id)

        #expect(model.activeSprint?.id == sprint.id)
        #expect(model.failure == nil)
    }

    @Test("Completing reports what did not fit")
    func carryOverIsReported() throws {
        let model = try boardWithCards(["Unfinished"])
        model.createSprint(named: "Sprint 1", goal: "", from: Date(), to: Date().addingTimeInterval(86_400))
        let sprint = try #require(model.sprints.first)
        let task = try #require(model.visibleColumns.first?.tasks.first)

        model.setSprint(sprint.id, for: task.id)
        model.startSprint(sprint.id)
        model.completeSprint(sprint.id, carryingOverTo: nil)

        #expect(model.carriedOverCount == 1)
        #expect(model.activeSprint == nil)
    }

    @Test("A card's sprint can be set and cleared")
    func membership() throws {
        let model = try boardWithCards(["Work"])
        model.createSprint(named: "Sprint 1", goal: "", from: nil, to: nil)
        let sprint = try #require(model.sprints.first)
        let task = try #require(model.visibleColumns.first?.tasks.first)

        model.setSprint(sprint.id, for: task.id)
        #expect(model.visibleColumns.first?.tasks.first?.sprintID == sprint.id)

        model.setSprint(nil, for: task.id)
        #expect(model.visibleColumns.first?.tasks.first?.sprintID == nil)
    }
}

@MainActor
@Suite("Custom fields on a live board")
struct CustomFieldModelTests {

    @Test("A field and its value survive a board reload")
    func roundTrip() throws {
        let model = try boardWithCards(["Sized"])
        model.createCustomField(named: "Size", kind: .number)
        let field = try #require(model.customFields.first)
        let task = try #require(model.visibleColumns.first?.tasks.first)

        model.setCustomValue(.number(8), forField: field.id, on: task.id)

        #expect(model.customValues(for: task)[field.id] == .number(8))
    }

    /// Custom rows share the three-row cap with the built-in ones, because a
    /// card showing six things shows none of them.
    @Test("Custom rows count against the same card limit")
    func sharedCap() throws {
        let model = try boardWithCards(["Card"])
        model.createCustomField(named: "Size", kind: .number)
        let field = try #require(model.customFields.first)

        model.setCardFields([.dueDate, .labels, .points])
        model.toggleCustomCardField(field.id)

        #expect(model.snapshot?.board.customCardFieldIDs.isEmpty == true)
        #expect(model.failure != nil)
    }

    @Test("Turning a built-in row off makes room for a custom one")
    func makingRoom() throws {
        let model = try boardWithCards(["Card"])
        model.createCustomField(named: "Size", kind: .number)
        let field = try #require(model.customFields.first)

        model.setCardFields([.dueDate, .labels])
        model.toggleCustomCardField(field.id)

        #expect(model.snapshot?.board.customCardFieldIDs == [field.id])
        #expect(model.snapshot?.board.cardRowCount == 3)
    }

    @Test("The stored form keeps both kinds apart")
    func storedForm() {
        let stored = CardField.stored([.dueDate, .labels], custom: ["abc"])
        #expect(stored == "due,labels,cf:abc")
        #expect(CardField.list(from: stored) == [.dueDate, .labels])
        #expect(CardField.customIDs(from: stored) == ["abc"])
        #expect(CardField.count(in: stored) == 3)
    }
}

@MainActor
@Suite("Workflow on a live board")
struct WorkflowModelTests {

    @Test("A refused move surfaces as a failure and the card stays put")
    func refusedMoveIsReported() throws {
        let model = try boardWithCards(["Bound"])
        let columns = model.visibleColumns
        let task = try #require(columns.first?.tasks.first)

        model.setTransition(from: columns[0].status.id, to: columns[1].status.id, allowed: true)
        model.setWorkflowEnforced(true)

        model.move(task.id, toStatus: columns[2].status.id)

        #expect(model.failure != nil)
        #expect(model.visibleColumns[0].tasks.count == 1)
        #expect(model.visibleColumns[2].tasks.isEmpty)
    }

    @Test("Seeding allows one step either way but not two")
    func seeding() throws {
        let model = try board()
        let columns = model.visibleColumns
        model.seedWorkflow()
        model.setWorkflowEnforced(true)

        #expect(model.permitsTransition(from: columns[0].status.id, to: columns[1].status.id))
        #expect(model.permitsTransition(from: columns[1].status.id, to: columns[0].status.id))
        #expect(!model.permitsTransition(from: columns[0].status.id, to: columns[2].status.id))
    }
}
