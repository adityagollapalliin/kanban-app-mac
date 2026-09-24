import Foundation
import Testing
import LocalBoardCore
import LocalBoardStore
@testable import LocalBoardUI

/// A loaded board with three columns and whatever cards the test adds.
@MainActor
private func loadedModel() throws -> BoardViewModel {
    let model = BoardViewModel(database: try makeDatabase())
    model.load()
    return model
}

@MainActor
@Suite("Filters combine rather than compete")
struct EffectiveQueryTests {

    @Test("Nothing set is no query at all")
    func empty() throws {
        let model = try loadedModel()
        #expect(model.effectiveQuery.isEmpty)
        #expect(!model.hasActiveFilters)
    }

    /// The rule that makes the filter row trustworthy: turning a second filter
    /// on narrows what is showing, it does not replace it.
    @Test("Two quick filters mean both, not the second one")
    func filtersAnd() throws {
        let model = try loadedModel()
        let flagged = try #require(model.quickFilters.first { $0.name == "Flagged" })
        let recent = try #require(model.quickFilters.first { $0.name == "Recently Updated" })

        model.toggleQuickFilter(flagged.id)
        model.toggleQuickFilter(recent.id)

        let query = model.effectiveQuery
        #expect(query.contains("is:flagged"))
        #expect(query.contains("updated >= -3d"))
    }

    @Test("What is typed and what is pressed combine")
    func typedAndPressed() throws {
        let model = try loadedModel()
        let flagged = try #require(model.quickFilters.first { $0.name == "Flagged" })

        model.queryText = "priority >= high"
        model.toggleQuickFilter(flagged.id)

        #expect(model.effectiveQuery == "(priority >= high) (is:flagged)")
    }

    /// A name with a space in it has to survive the round trip, or the parser
    /// reads its second word as a separate term and the facet quietly widens.
    @Test("A facet quotes a name with a space in it")
    func facetQuoting() throws {
        let model = try loadedModel()
        model.createPerson(named: "Ada Lovelace")
        let person = try #require(model.people.first)

        model.facetAssigneeID = person.id

        #expect(model.effectiveQuery == "assignee = \"Ada Lovelace\"")
        // And it parses, which is the part that matters.
        #expect(throws: Never.self) { try TaskQueryParser.parse(model.effectiveQuery) }
    }

    @Test("Clearing turns everything off at once")
    func clearing() throws {
        let model = try loadedModel()
        let flagged = try #require(model.quickFilters.first { $0.name == "Flagged" })

        model.queryText = "is:open"
        model.toggleQuickFilter(flagged.id)
        model.facetType = .bug
        #expect(model.hasActiveFilters)

        model.clearFilters()

        #expect(!model.hasActiveFilters)
        #expect(model.queryText.isEmpty)
        #expect(model.activeQuickFilterIDs.isEmpty)
        #expect(model.facetType == nil)
    }

    @Test("A facet actually hides the cards it excludes")
    func facetFilters() throws {
        let model = try loadedModel()
        let column = try #require(model.visibleColumns.first)
        model.addTask(title: "A bug", toStatus: column.status.id)
        model.addTask(title: "A chore", toStatus: column.status.id)

        let bug = try #require(model.visibleColumns.first?.tasks.first { $0.title == "A bug" })
        model.setType(.bug, for: bug.id)

        model.facetType = .bug

        #expect(model.visibleTaskCount == 1)
        #expect(model.totalTaskCount == 2)
    }
}

@MainActor
@Suite("Picking several cards")
struct SelectionTests {

    private func boardWithCards(_ count: Int) throws -> BoardViewModel {
        let model = try loadedModel()
        let column = try #require(model.visibleColumns.first)
        for index in 1...count {
            model.addTask(title: "Card \(index)", toStatus: column.status.id)
        }
        return model
    }

    @Test("Picking and unpicking one card")
    func toggle() throws {
        let model = try boardWithCards(2)
        let first = try #require(model.visibleColumns.first?.tasks.first)

        model.togglePicked(first.id)
        #expect(model.isPicked(first.id))
        #expect(model.hasSelection)

        model.togglePicked(first.id)
        #expect(!model.hasSelection)
    }

    /// Shift-click takes everything between, in the order the board is drawn —
    /// not the order the ids happen to come out of a set.
    @Test("Extending takes the whole run between")
    func extend() throws {
        let model = try boardWithCards(5)
        let tasks = try #require(model.visibleColumns.first?.tasks)

        model.togglePicked(tasks[1].id)
        model.extendPick(to: tasks[3].id)

        #expect(model.selectedTaskIDs == Set([tasks[1].id, tasks[2].id, tasks[3].id]))
    }

    @Test("Extending backwards works the same way")
    func extendBackwards() throws {
        let model = try boardWithCards(5)
        let tasks = try #require(model.visibleColumns.first?.tasks)

        model.togglePicked(tasks[3].id)
        model.extendPick(to: tasks[1].id)

        #expect(model.selectedTaskIDs == Set([tasks[1].id, tasks[2].id, tasks[3].id]))
    }

    /// A card that has left the board must leave the selection with it, or a
    /// bulk edit would silently act on work that is no longer there.
    @Test("A trashed card drops out of the selection")
    func trashedCardLeavesSelection() throws {
        let model = try boardWithCards(3)
        let tasks = try #require(model.visibleColumns.first?.tasks)

        model.pickAll()
        #expect(model.selectedTaskIDs.count == 3)

        model.setTrashed(true, for: tasks[0].id)

        #expect(model.selectedTaskIDs.count == 2)
        #expect(!model.isPicked(tasks[0].id))
    }

    @Test("A bulk edit can be taken back")
    func bulkUndo() throws {
        let model = try boardWithCards(3)
        let tasks = try #require(model.visibleColumns.first?.tasks)

        model.setPriority(.high, for: tasks[0].id)
        model.pickAll()
        model.bulkPriority(.lowest)

        #expect(model.visibleColumns.first?.tasks.allSatisfy { $0.priority == .lowest } == true)
        #expect(model.lastBulkEdit != nil)

        model.undoLastBulkEdit()

        let after = try #require(model.visibleColumns.first?.tasks)
        #expect(after.first { $0.id == tasks[0].id }?.priority == .high)
        #expect(after.filter { $0.priority == .normal }.count == 2)
        #expect(model.lastBulkEdit == nil)
    }

    @Test("A bulk move lands every picked card in the new column")
    func bulkMove() throws {
        let model = try boardWithCards(3)
        let columns = model.visibleColumns
        let destination = try #require(columns.dropFirst().first)

        model.pickAll()
        model.bulkMove(toStatus: destination.status.id)

        #expect(model.visibleColumns.first?.tasks.isEmpty == true)
        #expect(model.visibleColumns[1].tasks.count == 3)
    }
}

@MainActor
@Suite("Lanes on a live board")
struct LaneTests {

    @Test("A board with no grouping and no pinned matches has one lane")
    func plainBoard() throws {
        let model = BoardViewModel(database: try makeDatabase())
        model.load()
        let column = try #require(model.visibleColumns.first)
        model.addTask(title: "Ordinary", toStatus: column.status.id)

        #expect(!model.isLaned)
        #expect(model.lanes.count == 1)
    }

    /// The Expedite lane is seeded on every board and matches nothing until
    /// something is urgent — at which point the board rearranges itself.
    @Test("An urgent card pulls the board into lanes")
    func expediteAppears() throws {
        let model = BoardViewModel(database: try makeDatabase())
        model.load()
        let column = try #require(model.visibleColumns.first)
        model.addTask(title: "Ordinary", toStatus: column.status.id)
        model.addTask(title: "On fire", toStatus: column.status.id)

        #expect(!model.isLaned)

        let urgent = try #require(model.visibleColumns.first?.tasks.first { $0.title == "On fire" })
        model.setPriority(.highest, for: urgent.id)

        #expect(model.isLaned)
        #expect(model.lanes.first?.name == "Expedite")
        #expect(model.lanes.first?.taskIDs == [urgent.id])
        // And the ordinary card is still on the board, below it.
        #expect(model.lanes.count == 2)
    }

    @Test("Grouping by assignee draws a lane each and one for nobody")
    func groupedByAssignee() throws {
        let model = BoardViewModel(database: try makeDatabase())
        model.load()
        let column = try #require(model.visibleColumns.first)
        model.createPerson(named: "Ada")
        let ada = try #require(model.people.first)

        model.addTask(title: "Hers", toStatus: column.status.id)
        model.addTask(title: "Nobody's", toStatus: column.status.id)
        let hers = try #require(model.visibleColumns.first?.tasks.first { $0.title == "Hers" })
        model.setAssignee(ada.id, for: hers.id)

        model.setSwimlaneMode(.assignee)

        #expect(model.lanes.map(\.name) == ["Ada", "Unassigned"])
        #expect(model.columns(in: model.lanes[0]).first?.tasks.count == 1)
    }

    /// The heading's count and the cards drawn beneath it come from two
    /// different places, and this is the contract that they agree. It is worth
    /// saying out loud because they once did not: a `LazyVStack` nested in the
    /// board's two-way scroll view decided none of itself was visible, and
    /// lanes counted cards they then failed to draw. That was a rendering
    /// fault this test could not have caught — but the contract is still the
    /// thing the rendering has to honour.
    @Test("A lane's columns hold exactly the cards its heading counted")
    func laneColumnsMatchTheCount() throws {
        let model = BoardViewModel(database: try makeDatabase())
        model.load()
        let columns = model.visibleColumns
        model.addTask(title: "Urgent", toStatus: columns[1].status.id)
        model.addTask(title: "Ordinary", toStatus: columns[0].status.id)

        let urgent = try #require(model.visibleColumns[1].tasks.first)
        model.setPriority(.highest, for: urgent.id)

        let lane = try #require(model.lanes.first { $0.isPinned })
        let drawn = model.columns(in: lane).flatMap(\.tasks)

        #expect(lane.taskIDs.count == 1)
        #expect(drawn.map(\.id) == [urgent.id])
    }

    @Test("A lane counts only the cards a filter left showing")
    func lanesFollowTheFilter() throws {
        let model = BoardViewModel(database: try makeDatabase())
        model.load()
        let column = try #require(model.visibleColumns.first)
        model.addTask(title: "Keep", toStatus: column.status.id)
        model.addTask(title: "Hide", toStatus: column.status.id)

        model.setSwimlaneMode(.priority)
        #expect(model.lanes.first?.taskIDs.count == 2)

        model.queryText = "Keep"
        #expect(model.lanes.first?.taskIDs.count == 1)
    }
}

@MainActor
@Suite("The board's own settings")
struct BoardPresentationTests {

    @Test("A board shows at most three card rows, and says so rather than ignoring the fourth")
    func cardFieldCap() throws {
        let model = try loadedModel()
        model.setCardFields([.dueDate, .labels, .points])

        model.toggleCardField(.assignee)

        #expect(model.snapshot?.board.cardFields.count == 3)
        #expect(model.failure != nil)
    }

    @Test("Turning a row off makes room for another")
    func toggleOffThenOn() throws {
        let model = try loadedModel()
        model.setCardFields([.dueDate, .labels, .points])

        model.toggleCardField(.labels)
        model.toggleCardField(.assignee)

        let fields = try #require(model.snapshot?.board.cardFields)
        #expect(fields.contains(.assignee))
        #expect(!fields.contains(.labels))
    }

    /// Colouring by a view and then switching away must forget the view, or
    /// switching back would silently restore a choice already moved on from.
    @Test("Changing the colour rule away from a view forgets it")
    func colorRuleForgetsView() throws {
        let model = try loadedModel()
        model.queryText = "is:open"
        model.saveCurrentQuery(named: "Open")
        let view = try #require(model.savedViews.first)

        model.setColorRule(.query, viewID: view.id)
        #expect(model.snapshot?.board.colorViewID == view.id)

        model.setColorRule(.priority)
        #expect(model.snapshot?.board.colorViewID == nil)
    }

    @Test("A card added at the top goes to the top")
    func addAtTop() throws {
        let model = try loadedModel()
        let column = try #require(model.visibleColumns.first)
        model.addTask(title: "First added", toStatus: column.status.id)
        model.addTask(title: "Added at the top", toStatus: column.status.id, atTop: true)

        #expect(model.visibleColumns.first?.tasks.map(\.title)
                == ["Added at the top", "First added"])
    }
}

@MainActor
@Suite("Reading time the way people write it")
struct WorkLogParsingTests {

    /// A bare number is minutes. `30` far more often means half an hour than
    /// thirty hours, and the ambiguous case is the one worth getting right.
    @Test("A bare number is minutes")
    func bareNumber() {
        #expect(WorkLogSection.minutes(from: "30") == 30)
        #expect(WorkLogSection.minutes(from: "90") == 90)
    }

    @Test("Hours and minutes together")
    func compound() {
        #expect(WorkLogSection.minutes(from: "1h 30m") == 90)
        #expect(WorkLogSection.minutes(from: "1h30m") == 90)
        #expect(WorkLogSection.minutes(from: "2h") == 120)
        #expect(WorkLogSection.minutes(from: "45m") == 45)
    }

    @Test("A fractional hour is read as one")
    func fractional() {
        #expect(WorkLogSection.minutes(from: "1.5h") == 90)
    }

    @Test("A trailing number after an hour is minutes")
    func trailingMinutes() {
        #expect(WorkLogSection.minutes(from: "1h 30") == 90)
    }

    @Test("Nonsense and nothing both come back empty rather than as zero")
    func rejected() {
        #expect(WorkLogSection.minutes(from: "") == nil)
        #expect(WorkLogSection.minutes(from: "ages") == nil)
        #expect(WorkLogSection.minutes(from: "0") == nil)
        #expect(WorkLogSection.minutes(from: "0m") == nil)
    }
}
