import Foundation
import Testing
import LocalBoardCore
import LocalBoardStore
@testable import LocalBoardUI

@MainActor
private func boardWithColumns() throws -> BoardViewModel {
    let model = BoardViewModel(database: try makeDatabase())
    model.load()
    return model
}

@MainActor
@Suite("The keyboard on a live board")
struct KeyboardNavigationTests {

    @Test("Focus starts at the first card and travels without opening anything")
    func focusTravels() throws {
        let model = try boardWithColumns()
        let first = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "One", toStatus: first)
        model.addTask(title: "Two", toStatus: first)

        #expect(model.moveFocus(.down))
        #expect(model.focusedTask?.title == "One")

        #expect(model.moveFocus(.down))
        #expect(model.focusedTask?.title == "Two")

        // The point of a third thing: nothing was opened and nothing picked.
        #expect(model.selectedTaskID == nil)
        #expect(model.selectedTaskIDs.isEmpty)
    }

    /// The board ends where it ends, and an unhandled press is what lets the
    /// scroll view have the key instead.
    @Test("A press that goes nowhere says so")
    func edgeReportsUnhandled() throws {
        let model = try boardWithColumns()
        let first = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Only", toStatus: first)

        #expect(model.moveFocus(.down))
        #expect(model.moveFocus(.up) == false)
    }

    /// Clicking a card is where the keyboard picks up from, so arrows continue
    /// from what was last touched rather than jumping back to the top left.
    @Test("Focus resumes from the open card")
    func resumesFromSelection() throws {
        let model = try boardWithColumns()
        let first = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "One", toStatus: first)
        model.addTask(title: "Two", toStatus: first)

        let second = try #require(model.visibleColumns.first?.tasks.last?.id)
        model.selectedTaskID = second
        #expect(model.moveFocus(.down))
        #expect(model.focusedTaskID == second)
    }

    @Test("Return opens the focused card, space picks it")
    func openAndPick() throws {
        let model = try boardWithColumns()
        let first = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "One", toStatus: first)
        model.moveFocus(.down)

        model.openFocused()
        #expect(model.selectedTaskID == model.focusedTaskID)

        model.togglePickFocused()
        #expect(model.selectedTaskIDs == [model.focusedTaskID])
    }

    @Test("⌘→ moves the card itself into the next column")
    func movesCardSideways() throws {
        let model = try boardWithColumns()
        let columns = model.visibleColumns
        try #require(columns.count >= 2)
        model.addTask(title: "Travelling", toStatus: columns[0].status.id)
        model.moveFocus(.down)

        model.moveFocusedCard(step: 1)

        #expect(model.visibleColumns[0].tasks.isEmpty)
        #expect(model.visibleColumns[1].tasks.map(\.title) == ["Travelling"])
        // The keyboard followed the card rather than staying where it was.
        #expect(model.focusedTask?.title == "Travelling")
    }

    @Test("⌘↓ reorders within the column")
    func reordersInPlace() throws {
        let model = try boardWithColumns()
        let first = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "One", toStatus: first)
        model.addTask(title: "Two", toStatus: first)
        model.addTask(title: "Three", toStatus: first)

        model.focus(model.visibleColumns[0].tasks[0].id)
        model.reorderFocusedCard(offset: 1)
        #expect(model.visibleColumns[0].tasks.map(\.title) == ["Two", "One", "Three"])

        model.reorderFocusedCard(offset: 1)
        #expect(model.visibleColumns[0].tasks.map(\.title) == ["Two", "Three", "One"])

        // Already last: the press does nothing rather than something surprising.
        model.reorderFocusedCard(offset: 1)
        #expect(model.visibleColumns[0].tasks.map(\.title) == ["Two", "Three", "One"])
    }

    /// ⌘N opens the field where the keyboard already is: someone working in
    /// Review wants the new card in Review.
    @Test("The new-card shortcut aims at the column the keyboard is in")
    func quickAddFollowsFocus() throws {
        let model = try boardWithColumns()
        let columns = model.visibleColumns
        try #require(columns.count >= 2)
        model.addTask(title: "Here", toStatus: columns[1].status.id)

        model.requestQuickAdd()
        #expect(model.quickAddStatusID == columns[0].status.id)

        model.focus(model.visibleColumns[1].tasks[0].id)
        model.requestQuickAdd()
        #expect(model.quickAddStatusID == columns[1].status.id)
    }

    /// A flag rather than a token would make the second press do nothing,
    /// which reads as the shortcut being broken.
    @Test("Asking twice is two requests")
    func quickAddTokenAdvances() throws {
        let model = try boardWithColumns()
        let before = model.quickAddToken
        model.requestQuickAdd()
        model.requestQuickAdd()
        #expect(model.quickAddToken == before + 2)
    }
}

@MainActor
@Suite("The list and the calendar read the same board")
struct FlatViewTests {

    /// The three views are the same cards. A quick filter applied on the board
    /// has to mean the same thing in the list, or "showing 3 of 12" is a lie
    /// on two screens out of three.
    @Test("A filter hides the same cards in the list as on the board")
    func filteringAgrees() throws {
        let model = try boardWithColumns()
        let first = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Keep me", toStatus: first)
        model.addTask(title: "Hide me", toStatus: first)

        #expect(model.visibleTasks.count == 2)

        model.queryText = "Keep"
        #expect(model.visibleTasks.map(\.title) == ["Keep me"])
        #expect(model.visibleTasks.count == model.visibleTaskCount)
    }

    @Test("A row carries the column's name, not the status id")
    func rowsNameTheirColumn() throws {
        let model = try boardWithColumns()
        let column = try #require(model.visibleColumns.first)
        model.addTask(title: "Somewhere", toStatus: column.status.id)

        let task = try #require(model.visibleTasks.first)
        #expect(model.columnName(for: task) == column.name)

        let row = ListRow(task: task, model: model)
        #expect(row.status == column.name)
        #expect(row.key == model.tag(for: task))
    }

    /// "No date" is not early and it is not late, so an undated card sorts
    /// last whichever way the column is pointed — and it is still in the list.
    @Test("Undated cards sort last rather than first")
    func undatedSortsLast() throws {
        let model = try boardWithColumns()
        let first = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Dated", toStatus: first)
        model.addTask(title: "Undated", toStatus: first)

        let dated = try #require(model.visibleTasks.first { $0.title == "Dated" })
        model.setDueDate(Date(timeIntervalSince1970: 1_700_000_000), for: dated.id)

        let rows = model.visibleTasks.map { ListRow(task: $0, model: model) }
        let sorted = rows.sorted(using: [KeyPathComparator(\ListRow.dueSort)])
        #expect(sorted.map(\.title) == ["Dated", "Undated"])
        #expect(sorted.last?.due == "—")
    }

    @Test("A start date can be set as well as a due date")
    func startDatesAreEditable() throws {
        let model = try boardWithColumns()
        let first = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Scheduled", toStatus: first)
        let task = try #require(model.visibleTasks.first)

        let day = Date(timeIntervalSince1970: 1_700_000_000)
        model.setStartDate(day, for: task.id)
        #expect(model.task(id: task.id)?.startDate == day)

        // And taken away again — a calendar has to be able to undo a drag.
        model.setStartDate(nil, for: task.id)
        #expect(model.task(id: task.id)?.startDate == nil)
    }

    /// Changing a date from the calendar goes through the same undo stack as
    /// every other single-card edit.
    @Test("A date changed on the calendar can be undone")
    func dateChangesAreUndoable() throws {
        let model = try boardWithColumns()
        let first = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Movable", toStatus: first)
        let task = try #require(model.visibleTasks.first)

        model.setDueDate(Date(timeIntervalSince1970: 1_700_000_000), for: task.id)
        #expect(model.canUndo)

        model.undo()
        #expect(model.task(id: task.id)?.dueDate == nil)
    }
}

@MainActor
@Suite("Light, dark, or the Mac's own")
struct AppearanceModelTests {

    @Test("An appearance chosen on the board is remembered by the file")
    func remembered() throws {
        let database = try makeDatabase()
        let model = BoardViewModel(database: database)
        model.load()

        #expect(model.appearance == .system)
        model.appearance = .dark

        let reopened = BoardViewModel(database: database)
        reopened.load()
        #expect(reopened.appearance == .dark)
    }

    /// `system` has to mean "no opinion" all the way down, or the app would
    /// freeze in whichever mode it was in when it launched.
    @Test("System leaves the colour scheme to the Mac")
    func systemDefersToTheMac() {
        #expect(Appearance.system.colorScheme == nil)
        #expect(Appearance.light.colorScheme == .light)
        #expect(Appearance.dark.colorScheme == .dark)
    }
}
