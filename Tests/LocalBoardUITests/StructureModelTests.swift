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
@Suite("Lists on a live board")
struct ListModelTests {

    @Test("A starter file has one list, and new cards land in it")
    func starterHasOneList() throws {
        let model = try board()
        #expect(model.lists.count == 1)

        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Homed", toStatus: status)

        let task = try #require(model.visibleTasks.first { $0.title == "Homed" })
        #expect(task.listID == model.lists[0].id)
    }

    /// A list is a place, not a filter: standing in one narrows the board
    /// without putting anything in the search field.
    @Test("Choosing a list narrows the board without typing a query")
    func selectingAListNarrows() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Here", toStatus: status)
        model.createList(named: "Elsewhere")

        let elsewhere = try #require(model.lists.first { $0.name == "Elsewhere" })
        let card = try #require(model.visibleTasks.first { $0.title == "Here" })

        model.selectedListID = elsewhere.id
        #expect(model.queryText.isEmpty)
        #expect(model.visibleTasks.isEmpty)

        model.setHomeList(elsewhere.id, forTask: card.id)
        #expect(model.visibleTasks.map(\.title) == ["Here"])

        model.selectedListID = nil
        #expect(model.visibleTasks.map(\.title) == ["Here"])
    }

    /// Both narrow. A query asked while standing in a list is asked of that
    /// list, not of the whole space.
    @Test("A query inside a list is asked of the list")
    func queryAndListCombine() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Keep me", toStatus: status)
        model.addTask(title: "Keep me too", toStatus: status)
        model.createList(named: "Elsewhere")

        let elsewhere = try #require(model.lists.first { $0.name == "Elsewhere" })
        let first = try #require(model.visibleTasks.first { $0.title == "Keep me" })
        model.setHomeList(elsewhere.id, forTask: first.id)

        model.selectedListID = elsewhere.id
        model.queryText = "Keep"
        #expect(model.visibleTasks.map(\.title) == ["Keep me"])
    }

    @Test("A card shown in another list appears in both")
    func borrowedCardsAppear() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Shared", toStatus: status)
        model.createList(named: "This week")

        let week = try #require(model.lists.first { $0.name == "This week" })
        let card = try #require(model.visibleTasks.first)
        model.addTask(card.id, toList: week.id)

        model.selectedListID = week.id
        #expect(model.visibleTasks.map(\.title) == ["Shared"])

        model.selectedListID = model.lists.first { $0.id != week.id }?.id
        #expect(model.visibleTasks.map(\.title) == ["Shared"])
    }

    /// Deleting a list cannot leave its cards without a home, and the trash is
    /// somewhere they come back from.
    @Test("Deleting a list moves its cards where you said")
    func deletingAList() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Rehomed", toStatus: status)
        model.createList(named: "Elsewhere")

        let home = try #require(model.lists.first { $0.name != "Elsewhere" })
        let elsewhere = try #require(model.lists.first { $0.name == "Elsewhere" })

        model.deleteList(home.id, movingCardsTo: elsewhere.id)
        #expect(model.lists.map(\.name) == ["Elsewhere"])
        #expect(model.visibleTasks.first?.listID == elsewhere.id)
    }

    @Test("A folder tidies lists without owning their cards")
    func folders() throws {
        let model = try board()
        model.createFolder(named: "Platform")
        let folder = try #require(model.folders.first)
        model.createList(named: "Parser", inFolder: folder.id)

        #expect(model.lists(inFolder: folder.id).map(\.name) == ["Parser"])
        #expect(model.looseLists.contains { $0.name == "Parser" } == false)

        model.deleteFolder(folder.id)
        #expect(model.folders.isEmpty)
        #expect(model.looseLists.contains { $0.name == "Parser" })
    }
}

@MainActor
@Suite("Several people on a card")
struct AssigneeModelTests {

    @Test("Adding people keeps the first as the card's own assignee")
    func firstIsPrimary() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Shared", toStatus: status)
        model.createPerson(named: "Ada")
        model.createPerson(named: "Grace")

        let card = try #require(model.visibleTasks.first)
        let ada = try #require(model.people.first { $0.name == "Ada" })
        let grace = try #require(model.people.first { $0.name == "Grace" })

        model.addAssignee(ada.id, to: card.id)
        model.addAssignee(grace.id, to: card.id)

        let reloaded = try #require(model.task(id: card.id))
        #expect(model.people(on: reloaded).map(\.name) == ["Ada", "Grace"])
        #expect(reloaded.assigneeID == ada.id)
    }

    /// Adding somebody is an ordinary edit, so it undoes like one.
    @Test("Adding an assignee can be undone")
    func undoable() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Shared", toStatus: status)
        model.createPerson(named: "Ada")

        let card = try #require(model.visibleTasks.first)
        let ada = try #require(model.people.first)
        model.addAssignee(ada.id, to: card.id)

        #expect(model.canUndo)
        model.undo()
        #expect(try #require(model.task(id: card.id)).assigneeID == nil)
    }
}

@MainActor
@Suite("The sidebar's shortcuts")
struct ShortcutModelTests {

    @Test("A list can be favourited and unfavourited")
    func favourites() throws {
        let model = try board()
        let list = try #require(model.lists.first)

        model.toggleFavorite(.list, id: list.id, label: list.name)
        #expect(model.isFavorite(.list, id: list.id))
        #expect(model.favorites.map(\.label) == [list.name])

        model.toggleFavorite(.list, id: list.id, label: list.name)
        #expect(model.isFavorite(.list, id: list.id) == false)
    }

    /// Visiting the same list ten times is one trail entry, not ten.
    @Test("Recents are a trail, not a log")
    func recents() throws {
        let model = try board()
        model.createList(named: "Second")
        let first = try #require(model.lists.first)
        let second = try #require(model.lists.first { $0.name == "Second" })

        model.selectedListID = first.id
        model.selectedListID = second.id
        model.selectedListID = first.id

        #expect(model.recents.count == 2)
        #expect(model.recents.first?.targetID == first.id)
    }

    /// A shortcut to something that has gone says so rather than doing
    /// nothing, which would read as the app ignoring the click.
    @Test("Opening a shortcut to something deleted explains itself")
    func deadShortcut() throws {
        let model = try board()
        model.createList(named: "Doomed")
        let doomed = try #require(model.lists.first { $0.name == "Doomed" })
        model.toggleFavorite(.list, id: doomed.id, label: doomed.name)

        let shortcut = try #require(model.favorites.first)
        model.deleteList(doomed.id, movingCardsTo: model.lists.first { $0.id != doomed.id }?.id)

        model.open(shortcut)
        #expect(model.failure != nil)
    }
}

@MainActor
@Suite("What each view remembers")
struct ViewConfigModelTests {

    /// The table you set up on one list must not rearrange the table on
    /// another: they show different work.
    @Test("Settings are kept per place")
    func perPlace() throws {
        let model = try board()
        model.createList(named: "Second")
        let first = try #require(model.lists.first)
        let second = try #require(model.lists.first { $0.name == "Second" })

        model.selectedListID = first.id
        var config = model.viewConfig(.table)
        config.groupBy = "status"
        config.columns = ["key", "title", "days"]
        model.save(config)

        model.selectedListID = second.id
        #expect(model.viewConfig(.table).groupBy.isEmpty)

        model.selectedListID = first.id
        #expect(model.viewConfig(.table).groupBy == "status")
        #expect(model.viewConfig(.table).columns == ["key", "title", "days"])
    }

    @Test("A view nobody has configured still opens")
    func defaults() throws {
        let model = try board()
        let config = model.viewConfig(.workload)
        #expect(config.viewKind == .workload)
        #expect(config.columns.isEmpty)
    }
}

@MainActor
@Suite("Recurrence on a live board")
struct RecurrenceModelTests {

    @Test("A rule is saved with the card and read back")
    func savedAndRead() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Weekly report", toStatus: status)
        let card = try #require(model.visibleTasks.first)

        model.setRecurrence(
            RecurrenceRule(frequency: .monthly, weekdays: [3], weekOfMonth: 2, mode: .completion),
            for: card.id
        )

        let saved = try #require(model.recurrence(of: card.id))
        #expect(saved.rule.summary == "The 2nd Tuesday of every month")
        #expect(saved.rule.mode == .completion)

        model.clearRecurrence(for: card.id)
        #expect(model.recurrence(of: card.id) == nil)
    }

    /// Finishing a repeating card leaves the finished one alone and adds the
    /// next, which is what keeps the history readable.
    @Test("Finishing one adds the next to the board")
    func completingSpawns() throws {
        let model = try board()
        let columns = model.visibleColumns
        try #require(columns.count >= 3)
        model.addTask(title: "Water the plants", toStatus: columns[0].status.id)
        let card = try #require(model.visibleTasks.first)
        model.setDueDate(.now, for: card.id)
        model.setRecurrence(RecurrenceRule(frequency: .weekly, mode: .completion), for: card.id)

        model.move(card.id, toStatus: columns[2].status.id)

        #expect(model.visibleTasks.filter { $0.title == "Water the plants" }.count == 2)
        #expect(model.visibleTasks.contains { $0.title == "Water the plants" && $0.completedAt == nil })
    }
}

@MainActor
@Suite("The trash")
struct TrashModelTests {

    @Test("A trashed card can be put back, and the bin can be emptied")
    func restoreAndEmpty() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Thrown away", toStatus: status)
        let card = try #require(model.visibleTasks.first)

        model.setTrashed(true, for: card.id)
        #expect(model.trashedTasks.map(\.title) == ["Thrown away"])
        #expect(model.daysLeftInTrash(model.trashedTasks[0]) == 30)

        model.restoreFromTrash(card.id)
        #expect(model.trashedTasks.isEmpty)

        model.setTrashed(true, for: card.id)
        model.emptyTrash()
        #expect(model.trashedTasks.isEmpty)
        #expect(model.task(id: card.id) == nil)
    }
}
