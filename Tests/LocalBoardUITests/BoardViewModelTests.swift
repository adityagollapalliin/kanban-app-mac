import Foundation
import Testing
import LocalBoardCore
import LocalBoardStore
@testable import LocalBoardUI

/// The layer between the views and the store. Until now the only thing that
/// exercised the drop arithmetic was a hand on a trackpad.
@Suite("Board view model")
@MainActor
struct BoardViewModelTests {

    private func loadedModel() throws -> BoardViewModel {
        let model = BoardViewModel(database: try makeDatabase(), clock: FixedClock(fixedNow))
        model.load()
        return model
    }

    private func column(_ model: BoardViewModel, _ index: Int) -> LoadedColumn {
        model.snapshot!.columns[index]
    }

    // MARK: - Loading

    @Test("Loading an empty file seeds a board and opens it")
    func loadSeedsAndSelects() throws {
        let model = try loadedModel()

        #expect(model.selectedBoardID != nil)
        #expect(model.snapshot != nil)
        #expect(model.statuses.map(\.name) == ["To Do", "In Progress", "Done"])
        #expect(model.failure == nil)
    }

    @Test("Loading twice does not produce a second board")
    func loadIsIdempotent() throws {
        let model = try loadedModel()
        let first = model.selectedBoardID

        model.load()

        #expect(model.selectedBoardID == first)
        #expect(model.boards.count == 1)
        #expect(model.workspaces.count == 1)
    }

    @Test("Cards are tagged with the project key and number")
    func tagFormatting() throws {
        let model = try loadedModel()
        model.addTask(title: "First", toStatus: column(model, 0).status.id)

        let task = try #require(column(model, 0).tasks.first)
        #expect(model.tag(for: task) == "TASK-1")
    }

    // MARK: - Adding

    @Test("A new card lands in the column it was added to")
    func addTask() throws {
        let model = try loadedModel()
        model.addTask(title: "Write the thing", toStatus: column(model, 1).status.id)

        #expect(column(model, 0).tasks.isEmpty)
        #expect(column(model, 1).tasks.map(\.title) == ["Write the thing"])
        #expect(model.snapshot?.taskCount == 1)
    }

    /// The views have no `try` in them, so a rejected edit has to arrive as
    /// state rather than as a thrown error.
    @Test("A blank title surfaces as a failure instead of throwing")
    func blankTitleSurfaces() throws {
        let model = try loadedModel()
        model.addTask(title: "   ", toStatus: column(model, 0).status.id)

        #expect(model.failure != nil)
        #expect(model.snapshot?.taskCount == 0)
    }

    @Test("A failure clears once something succeeds")
    func failureClears() throws {
        let model = try loadedModel()
        model.addTask(title: "", toStatus: column(model, 0).status.id)
        #expect(model.failure != nil)

        model.addTask(title: "Fine", toStatus: column(model, 0).status.id)
        #expect(model.failure == nil)
    }

    @Test("A failure can also be dismissed by hand")
    func dismissFailure() throws {
        let model = try loadedModel()
        model.addTask(title: "", toStatus: column(model, 0).status.id)

        model.dismissFailure()
        #expect(model.failure == nil)
    }

    // MARK: - Selection

    @Test("Selecting a card resolves it out of the current snapshot")
    func selection() throws {
        let model = try loadedModel()
        model.addTask(title: "Inspect me", toStatus: column(model, 0).status.id)
        let task = try #require(column(model, 0).tasks.first)

        model.selectedTaskID = task.id
        #expect(model.selectedTask?.title == "Inspect me")

        model.selectedTaskID = nil
        #expect(model.selectedTask == nil)
    }

    /// The inspector must not be left describing a card the board no longer
    /// shows.
    @Test("Trashing the open card closes the inspector")
    func trashingSelectedClearsSelection() throws {
        let model = try loadedModel()
        model.addTask(title: "Doomed", toStatus: column(model, 0).status.id)
        let task = try #require(column(model, 0).tasks.first)
        model.selectedTaskID = task.id

        model.setTrashed(true, for: task.id)

        #expect(model.selectedTaskID == nil)
        #expect(model.snapshot?.taskCount == 0)
    }

    @Test("Trashing a different card leaves the selection alone")
    func trashingOtherKeepsSelection() throws {
        let model = try loadedModel()
        let status = column(model, 0).status.id
        model.addTask(title: "Kept", toStatus: status)
        model.addTask(title: "Doomed", toStatus: status)

        let kept = try #require(column(model, 0).tasks.first { $0.title == "Kept" })
        let doomed = try #require(column(model, 0).tasks.first { $0.title == "Doomed" })
        model.selectedTaskID = kept.id

        model.setTrashed(true, for: doomed.id)

        #expect(model.selectedTaskID == kept.id)
        #expect(model.selectedTask?.title == "Kept")
    }

    // MARK: - Moving

    @Test("Moving a card to another column regroups it")
    func moveAcrossColumns() throws {
        let model = try loadedModel()
        model.addTask(title: "Travelling", toStatus: column(model, 0).status.id)
        let task = try #require(column(model, 0).tasks.first)

        model.move(task.id, toStatus: column(model, 2).status.id)

        #expect(column(model, 0).tasks.isEmpty)
        #expect(column(model, 2).tasks.map(\.title) == ["Travelling"])
        // The third column is Done, so the move finished the card.
        #expect(column(model, 2).tasks.first?.completedAt == fixedNow)
    }

    /// The arithmetic behind every drag: `before` names the card to land above,
    /// and the model has to find what is now directly above it.
    @Test("Dropping above a card puts it directly above that card")
    func moveAboveACard() throws {
        let model = try loadedModel()
        let status = column(model, 0).status.id
        for title in ["A", "B", "C"] { model.addTask(title: title, toStatus: status) }

        let c = try #require(column(model, 0).tasks.first { $0.title == "C" })
        let b = try #require(column(model, 0).tasks.first { $0.title == "B" })

        model.move(c.id, toStatus: status, before: b.id)

        #expect(column(model, 0).tasks.map(\.title) == ["A", "C", "B"])
    }

    @Test("Dropping above the first card puts it at the top")
    func moveToTop() throws {
        let model = try loadedModel()
        let status = column(model, 0).status.id
        for title in ["A", "B"] { model.addTask(title: title, toStatus: status) }

        let b = try #require(column(model, 0).tasks.first { $0.title == "B" })
        let a = try #require(column(model, 0).tasks.first { $0.title == "A" })

        model.move(b.id, toStatus: status, before: a.id)

        #expect(column(model, 0).tasks.map(\.title) == ["B", "A"])
    }

    @Test("Dropping with no card below it puts it at the bottom")
    func moveToBottom() throws {
        let model = try loadedModel()
        let status = column(model, 0).status.id
        for title in ["A", "B"] { model.addTask(title: title, toStatus: status) }

        let a = try #require(column(model, 0).tasks.first { $0.title == "A" })
        model.move(a.id, toStatus: status, before: nil)

        #expect(column(model, 0).tasks.map(\.title) == ["B", "A"])
    }

    /// Picking a card up and putting it back down must not be a move to
    /// nowhere.
    @Test("Dropping a card onto itself changes nothing")
    func moveOntoItself() throws {
        let model = try loadedModel()
        let status = column(model, 0).status.id
        for title in ["A", "B"] { model.addTask(title: title, toStatus: status) }

        let a = try #require(column(model, 0).tasks.first { $0.title == "A" })
        let before = column(model, 0).tasks.map(\.sortOrder)

        model.move(a.id, toStatus: status, before: a.id)

        #expect(column(model, 0).tasks.map(\.title) == ["A", "B"])
        #expect(column(model, 0).tasks.map(\.sortOrder) == before)
        #expect(model.failure == nil)
    }

    @Test("The inspector's status picker sends a card to the end of a column")
    func moveToEnd() throws {
        let model = try loadedModel()
        let from = column(model, 0).status.id
        let to = column(model, 1).status.id
        model.addTask(title: "Already there", toStatus: to)
        model.addTask(title: "Arriving", toStatus: from)

        let arriving = try #require(column(model, 0).tasks.first)
        model.moveToEnd(of: to, taskID: arriving.id)

        #expect(column(model, 1).tasks.map(\.title) == ["Already there", "Arriving"])
    }

    // MARK: - Editing

    @Test("Edits from the inspector reach the board")
    func edits() throws {
        let model = try loadedModel()
        model.addTask(title: "Before", toStatus: column(model, 0).status.id)
        let task = try #require(column(model, 0).tasks.first)

        model.rename(task.id, to: "After")
        model.setType(.bug, for: task.id)
        model.setPriority(.highest, for: task.id)
        model.setDescription("Notes", for: task.id)
        model.setDueDate(fixedNow, for: task.id)

        let edited = try #require(column(model, 0).tasks.first)
        #expect(edited.title == "After")
        #expect(edited.type == .bug)
        #expect(edited.priority == .highest)
        #expect(edited.descriptionMarkdown == "Notes")
        #expect(edited.dueDate == fixedNow)
        #expect(model.failure == nil)
    }

    @Test("A due date can be cleared again from the inspector")
    func clearDueDate() throws {
        let model = try loadedModel()
        model.addTask(title: "Dated", toStatus: column(model, 0).status.id)
        let task = try #require(column(model, 0).tasks.first)

        model.setDueDate(fixedNow, for: task.id)
        model.setDueDate(nil, for: task.id)

        #expect(column(model, 0).tasks.first?.dueDate == nil)
    }
}
