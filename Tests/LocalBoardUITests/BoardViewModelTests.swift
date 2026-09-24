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

    /// Clicking the open card again closes it, the way clicking it opened it.
    @Test("Clicking a card toggles the inspector rather than only opening it")
    func selectionToggles() throws {
        let model = try loadedModel()
        let status = column(model, 0).status.id
        model.addTask(title: "First", toStatus: status)
        model.addTask(title: "Second", toStatus: status)

        let first = try #require(column(model, 0).tasks.first { $0.title == "First" })
        let second = try #require(column(model, 0).tasks.first { $0.title == "Second" })

        model.toggleSelection(of: first.id)
        #expect(model.selectedTaskID == first.id)

        // The same card again closes it.
        model.toggleSelection(of: first.id)
        #expect(model.selectedTaskID == nil)

        // A different card moves the inspector rather than closing it.
        model.toggleSelection(of: first.id)
        model.toggleSelection(of: second.id)
        #expect(model.selectedTaskID == second.id)
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

    // MARK: - The trash

    /// Trashing has to be reversible from the app. The board hides trashed
    /// cards, so finding one again means re-reading the board, not just
    /// filtering what was already on screen.
    @Test("A trashed card can be found again and put back")
    func trashRoundTrip() throws {
        let model = try loadedModel()
        let status = column(model, 0).status.id
        model.addTask(title: "Thrown away", toStatus: status)
        let task = try #require(column(model, 0).tasks.first)

        model.setTrashed(true, for: task.id)
        #expect(model.totalTaskCount == 0, "the board hides it")

        model.queryText = "is:trashed"
        #expect(model.visibleTaskCount == 1, "asking for the trash reads it back")
        let found = try #require(model.visibleColumns.flatMap(\.tasks).first)
        #expect(found.trashed)
        #expect(found.title == "Thrown away")

        model.restore(found.id)
        #expect(model.visibleTaskCount == 0, "it is no longer in the trash")

        model.queryText = ""
        #expect(model.totalTaskCount == 1, "and it is back on the board")
    }

    @Test("Clearing the query hides the trash again")
    func trashHidesAgain() throws {
        let model = try loadedModel()
        let status = column(model, 0).status.id
        model.addTask(title: "Kept", toStatus: status)
        model.addTask(title: "Binned", toStatus: status)
        let binned = try #require(column(model, 0).tasks.first { $0.title == "Binned" })
        model.setTrashed(true, for: binned.id)

        model.queryText = "is:trashed"
        #expect(model.visibleTaskCount == 1)

        model.queryText = ""
        #expect(model.totalTaskCount == 1)
        #expect(model.visibleColumns.flatMap(\.tasks).map(\.title) == ["Kept"])
    }

    @Test("A query that says nothing about the trash still excludes it")
    func ordinaryQueriesSkipTrash() throws {
        let model = try loadedModel()
        let status = column(model, 0).status.id
        model.addTask(title: "Findable", toStatus: status)
        model.addTask(title: "Findable too", toStatus: status)
        let gone = try #require(column(model, 0).tasks.first { $0.title == "Findable too" })
        model.setTrashed(true, for: gone.id)

        model.queryText = "title:findable"
        #expect(model.visibleColumns.flatMap(\.tasks).map(\.title) == ["Findable"])
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

    // MARK: - Filtering

    @Test("A query hides the cards it does not match, column by column")
    func filtering() throws {
        let model = try loadedModel()
        let toDo = column(model, 0).status.id
        model.addTask(title: "A bug", toStatus: toDo)
        model.addTask(title: "A story", toStatus: toDo)

        let bug = try #require(column(model, 0).tasks.first { $0.title == "A bug" })
        model.setType(.bug, for: bug.id)

        model.queryText = "type:bug"

        #expect(model.isFiltering)
        #expect(model.visibleColumns[0].tasks.map(\.title) == ["A bug"])
        #expect(model.visibleTaskCount == 1)
        #expect(model.totalTaskCount == 2)
    }

    @Test("Clearing the field shows everything again")
    func clearingQuery() throws {
        let model = try loadedModel()
        model.addTask(title: "Anything", toStatus: column(model, 0).status.id)

        model.queryText = "type:bug"
        #expect(model.visibleTaskCount == 0)

        model.queryText = ""
        #expect(model.isFiltering == false)
        #expect(model.visibleTaskCount == 1)
    }

    /// Half a query is a normal state of a field being typed into. It must not
    /// blank the board, and it must not raise the same alarm as a failed edit.
    @Test("An unfinished query is reported quietly and keeps the last result")
    func incompleteQuery() throws {
        let model = try loadedModel()
        let toDo = column(model, 0).status.id
        model.addTask(title: "A bug", toStatus: toDo)
        let bug = try #require(column(model, 0).tasks.first)
        model.setType(.bug, for: bug.id)

        model.queryText = "type:bug"
        #expect(model.visibleTaskCount == 1)

        model.queryText = "type:bug due <"

        #expect(model.queryFailure != nil)
        #expect(model.failure == nil, "a half-typed query is not a failed action")
        #expect(model.visibleTaskCount == 1, "the last good result stays on screen")
    }

    @Test("A filter survives a reload")
    func filterSurvivesReload() throws {
        let model = try loadedModel()
        let toDo = column(model, 0).status.id
        model.addTask(title: "Keep me", toStatus: toDo)
        model.addTask(title: "Hide me", toStatus: toDo)

        model.queryText = "title:keep"
        #expect(model.visibleTaskCount == 1)

        model.load()
        #expect(model.visibleTaskCount == 1)
        #expect(model.visibleColumns[0].tasks.map(\.title) == ["Keep me"])
    }

    // MARK: - People

    @Test("Adding someone makes them assignable")
    func people() throws {
        let model = try loadedModel()
        #expect(model.people.isEmpty)

        model.createPerson(named: "Ada")

        #expect(model.people.map(\.name) == ["Ada"])
        #expect(model.failure == nil)
    }

    @Test("A card can be assigned and unassigned")
    func assigning() throws {
        let model = try loadedModel()
        model.createPerson(named: "Ada")
        model.addTask(title: "Work", toStatus: column(model, 0).status.id)

        let ada = try #require(model.people.first)
        let task = try #require(column(model, 0).tasks.first)

        model.setAssignee(ada.id, for: task.id)
        #expect(column(model, 0).tasks.first?.assigneeID == ada.id)
        #expect(model.person(id: ada.id)?.name == "Ada")

        model.setAssignee(nil, for: task.id)
        #expect(column(model, 0).tasks.first?.assigneeID == nil)
    }

    /// Someone leaving should not take their work with them.
    @Test("Removing someone leaves their cards, unassigned")
    func removingPerson() throws {
        let model = try loadedModel()
        model.createPerson(named: "Ada")
        model.addTask(title: "Their work", toStatus: column(model, 0).status.id)

        let ada = try #require(model.people.first)
        let task = try #require(column(model, 0).tasks.first)
        model.setAssignee(ada.id, for: task.id)

        model.deletePerson(ada.id)

        #expect(model.people.isEmpty)
        #expect(model.totalTaskCount == 1)
        #expect(column(model, 0).tasks.first?.assigneeID == nil)
    }

    // MARK: - Saved views

    @Test("A query worth keeping can be saved and reopened")
    func savingAView() throws {
        let model = try loadedModel()
        let toDo = column(model, 0).status.id
        model.addTask(title: "A bug", toStatus: toDo)
        model.addTask(title: "A story", toStatus: toDo)
        let bug = try #require(column(model, 0).tasks.first { $0.title == "A bug" })
        model.setType(.bug, for: bug.id)

        model.queryText = "type:bug"
        #expect(model.canSaveCurrentQuery)
        model.saveCurrentQuery(named: "Bugs")

        #expect(model.savedViews.map(\.name) == ["Bugs"])

        // Reopening puts the question back in the field, not just the answer.
        model.queryText = ""
        #expect(model.visibleTaskCount == 2)

        let view = try #require(model.savedViews.first)
        model.apply(view)

        #expect(model.queryText == "type:bug")
        #expect(model.visibleColumns[0].tasks.map(\.title) == ["A bug"])
    }

    @Test("There is nothing to save until something parses")
    func cannotSaveNothing() throws {
        let model = try loadedModel()
        #expect(model.canSaveCurrentQuery == false)

        model.queryText = "   "
        #expect(model.canSaveCurrentQuery == false)

        model.queryText = "due <"
        #expect(model.canSaveCurrentQuery == false, "a query that does not parse is not worth keeping")

        model.queryText = "is:open"
        #expect(model.canSaveCurrentQuery)
    }

    @Test("A view can be deleted")
    func deletingAView() throws {
        let model = try loadedModel()
        model.queryText = "is:open"
        model.saveCurrentQuery(named: "Open")
        let view = try #require(model.savedViews.first)

        model.deleteSavedView(view.id)
        #expect(model.savedViews.isEmpty)
    }

    @Test("Views survive a reload")
    func viewsSurviveReload() throws {
        let model = try loadedModel()
        model.queryText = "is:overdue"
        model.saveCurrentQuery(named: "Late")

        model.load()
        #expect(model.savedViews.map(\.name) == ["Late"])
    }

    // MARK: - Reshaping

    @Test("A column can be added, renamed and removed from the board")
    func columns() throws {
        let model = try loadedModel()
        #expect(model.visibleColumns.map(\.name) == ["To Do", "In Progress", "Done"])

        model.addColumn(named: "Review", category: .inProgress)
        #expect(model.visibleColumns.map(\.name) == ["To Do", "In Progress", "Done", "Review"])

        let review = try #require(model.visibleColumns.last)
        model.renameColumn(review.id, to: "In Review")
        #expect(model.visibleColumns.map(\.name).last == "In Review")

        model.setWIPLimit(2, for: review.id)
        #expect(model.visibleColumns.last?.column.wipLimit == 2)

        model.deleteColumn(review.id, movingTasksTo: nil)
        #expect(model.visibleColumns.map(\.name) == ["To Do", "In Progress", "Done"])
        #expect(model.failure == nil)
    }

    /// Losing work to a tidy-up would be the worst kind of bug, so the cards
    /// move rather than going with the column.
    @Test("Deleting a column carries its cards to another one")
    func deletingColumnMovesCards() throws {
        let model = try loadedModel()
        model.addTask(title: "Still needed", toStatus: column(model, 1).status.id)

        let doomed = column(model, 1)
        model.deleteColumn(doomed.id, movingTasksTo: column(model, 0).status.id)

        #expect(model.visibleColumns.map(\.name) == ["To Do", "Done"])
        #expect(model.visibleColumns[0].tasks.map(\.title) == ["Still needed"])
    }

    @Test("A new project opens with its own board and columns")
    func projects() throws {
        let model = try loadedModel()
        model.addTask(title: "Old project card", toStatus: column(model, 0).status.id)

        model.createProject(named: "Second", key: "TWO")

        #expect(model.projects.count == 2)
        #expect(model.visibleColumns.map(\.name) == ["To Do", "In Progress", "Done"])
        #expect(model.totalTaskCount == 0, "the new project starts empty")
    }

    @Test("A second board over a project shows the same cards")
    func boards() throws {
        let model = try loadedModel()
        model.addTask(title: "Shared", toStatus: column(model, 0).status.id)
        let projectID = try #require(model.snapshot?.board.projectID)

        model.createBoard(named: "Planning", inProject: projectID)

        #expect(model.boards.count == 2)
        #expect(model.totalTaskCount == 1, "the cards belong to the project, not the board")
    }

    // MARK: - Labels, checklists, subtasks

    @Test("A label can be made, put on a card and taken off")
    func labels() throws {
        let model = try loadedModel()
        model.addTask(title: "A card", toStatus: column(model, 0).status.id)
        let task = try #require(column(model, 0).tasks.first)

        model.createLabel(named: "needs design")
        let label = try #require(model.labels.first)

        model.setLabel(label.id, on: task.id, attached: true)
        #expect(model.labels(for: try #require(column(model, 0).tasks.first)).map(\.name) == ["needs design"])

        model.setLabel(label.id, on: task.id, attached: false)
        #expect(model.labels(for: try #require(column(model, 0).tasks.first)).isEmpty)
    }

    @Test("A checklist counts down as its boxes are ticked")
    func checklist() throws {
        let model = try loadedModel()
        model.addTask(title: "With steps", toStatus: column(model, 0).status.id)
        let task = try #require(column(model, 0).tasks.first)
        model.selectedTaskID = task.id

        model.addChecklistItem("Write it", to: task.id)
        model.addChecklistItem("Test it", to: task.id)
        #expect(model.checklist.map(\.text) == ["Write it", "Test it"])

        let first = try #require(model.checklist.first)
        model.setChecklistItem(first.id, done: true)

        #expect(model.checklistProgress(for: task) == ChecklistProgress(done: 1, total: 2))

        model.deleteChecklistItem(first.id)
        #expect(model.checklist.count == 1)
    }

    @Test("Adding a subtask files a new card under this one")
    func subtasks() throws {
        let model = try loadedModel()
        model.addTask(title: "Parent", toStatus: column(model, 0).status.id)
        let parent = try #require(column(model, 0).tasks.first)
        model.selectedTaskID = parent.id

        model.addSubtask("A step of its own", to: parent.id)

        #expect(model.subtasks.map(\.title) == ["A step of its own"])
        #expect(model.subtaskProgress(for: parent) == ChecklistProgress(done: 0, total: 1))
        #expect(model.totalTaskCount == 2, "a subtask is a card, and appears on the board")
    }

    @Test("Work can be filed under an epic")
    func epics() throws {
        let model = try loadedModel()
        let status = column(model, 0).status.id
        model.addTask(title: "Milestone 3", toStatus: status)
        model.addTask(title: "Some work", toStatus: status)

        let epic = try #require(column(model, 0).tasks.first { $0.title == "Milestone 3" })
        let work = try #require(column(model, 0).tasks.first { $0.title == "Some work" })

        model.setType(.epic, for: epic.id)
        model.setEpic(epic.id, for: work.id)

        let filed = try #require(column(model, 0).tasks.first { $0.id == work.id })
        #expect(model.epic(for: filed)?.title == "Milestone 3")
        #expect(model.failure == nil)
    }

    /// The store refuses a loop; the model has to surface that rather than
    /// swallow it.
    @Test("A refused parent shows up as a failure")
    func cycleIsReported() throws {
        let model = try loadedModel()
        let status = column(model, 0).status.id
        model.addTask(title: "Only card", toStatus: status)
        let task = try #require(column(model, 0).tasks.first)

        model.setParent(task.id, for: task.id)

        #expect(model.failure != nil)
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
