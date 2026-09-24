import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("Labels, checklists and hierarchy")
struct CardDetailTests {

    private struct Fixture {
        let database: Database
        let tasks: TaskRepository
        let labels: LabelRepository
        let checklists: ChecklistRepository
        let boards: BoardRepository
        let ids: (workspace: String, project: String, board: String, toDo: String, inProgress: String, done: String)
    }

    private func fixture() throws -> Fixture {
        let database = try Database.inMemoryMigrated()
        return Fixture(
            database: database,
            tasks: TaskRepository(database: database),
            labels: LabelRepository(database: database),
            checklists: ChecklistRepository(database: database),
            boards: BoardRepository(database: database),
            ids: try database.seedBoardProject()
        )
    }

    // MARK: - Labels

    @Test("A label goes on a card and comes off again")
    func labelsOnCards() throws {
        let f = try fixture()
        let label = try f.labels.create(inProject: f.ids.project, name: "needs design")
        let task = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "A card")

        try f.labels.setLabel(label.id, on: task.id, attached: true)
        #expect(try f.labels.labels(forTask: task.id).map(\.name) == ["needs design"])

        // Putting the same label on twice is one label, not an error.
        try f.labels.setLabel(label.id, on: task.id, attached: true)
        #expect(try f.labels.labels(forTask: task.id).count == 1)

        try f.labels.setLabel(label.id, on: task.id, attached: false)
        #expect(try f.labels.labels(forTask: task.id).isEmpty)
    }

    @Test("Label names are unique within a project")
    func labelNames() throws {
        let f = try fixture()
        try f.labels.create(inProject: f.ids.project, name: "bug")
        #expect(throws: LocalBoardError.self) {
            try f.labels.create(inProject: f.ids.project, name: "BUG")
        }
    }

    /// Deleting a label is about the label, not the work that carried it.
    @Test("Deleting a label leaves its cards alone")
    func deletingLabel() throws {
        let f = try fixture()
        let label = try f.labels.create(inProject: f.ids.project, name: "temporary")
        let task = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "A card")
        try f.labels.setLabel(label.id, on: task.id, attached: true)

        try f.labels.delete(label.id)

        #expect(try f.labels.labels(forTask: task.id).isEmpty)
        #expect(try f.database.count("SELECT COUNT(*) FROM task;") == 1)
    }

    @Test("label = name finds the cards carrying it")
    func queryByLabel() throws {
        let f = try fixture()
        let design = try f.labels.create(inProject: f.ids.project, name: "needs design")
        let tagged = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Tagged")
        try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Plain")
        try f.labels.setLabel(design.id, on: tagged.id, attached: true)

        let matching = { (query: String) in
            try f.tasks.tasks(matching: query, inProject: f.ids.project).map(\.title).sorted()
        }

        #expect(try matching("label = \"needs design\"") == ["Tagged"])
        #expect(try matching("label != \"needs design\"") == ["Plain"])
        #expect(try matching("is:labelled") == ["Tagged"])
        #expect(try matching("label = none") == ["Plain"])
    }

    @Test("A whole board's labels come back in one query")
    func labelsByTask() throws {
        let f = try fixture()
        let bug = try f.labels.create(inProject: f.ids.project, name: "bug")
        let ui = try f.labels.create(inProject: f.ids.project, name: "ui")
        let task = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Both")
        try f.labels.setLabel(bug.id, on: task.id, attached: true)
        try f.labels.setLabel(ui.id, on: task.id, attached: true)

        let snapshot = try f.boards.snapshot(boardID: f.ids.board)
        #expect(snapshot.labels[task.id]?.map(\.name) == ["bug", "ui"])
    }

    // MARK: - Checklists

    @Test("A checklist counts what is done")
    func checklists() throws {
        let f = try fixture()
        let task = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "With steps")

        let first = try f.checklists.add(toTask: task.id, text: "Write it")
        try f.checklists.add(toTask: task.id, text: "Test it")

        #expect(try f.checklists.items(forTask: task.id).map(\.text) == ["Write it", "Test it"])

        try f.checklists.setDone(true, for: first.id)

        let progress = try f.boards.snapshot(boardID: f.ids.board).checklists[task.id]
        #expect(progress == ChecklistProgress(done: 1, total: 2))
        #expect(progress?.isComplete == false)
    }

    @Test("An empty checklist item is refused")
    func blankChecklistItem() throws {
        let f = try fixture()
        let task = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "A card")
        #expect(throws: LocalBoardError.self) { try f.checklists.add(toTask: task.id, text: "  ") }
    }

    /// Ticking a box changes the card, so the card's stamp should say so.
    @Test("Ticking a box moves the card's updated stamp")
    func checklistTouchesTask() throws {
        let database = try Database.inMemoryMigrated()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let tasks = TaskRepository(database: database, clock: clock)
        let checklists = ChecklistRepository(database: database, clock: clock)
        let ids = try database.seedBoardProject()

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "A card")
        let item = try checklists.add(toTask: task.id, text: "A step")

        clock.advance(by: 3_600)
        try checklists.setDone(true, for: item.id)

        #expect(try tasks.task(id: task.id).updatedAt == clock.now)
    }

    @Test("Deleting a card takes its checklist with it")
    func checklistCascades() throws {
        let f = try fixture()
        let task = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "A card")
        try f.checklists.add(toTask: task.id, text: "A step")

        try f.database.execute("DELETE FROM task WHERE id = ?;", [task.id])
        #expect(try f.database.count("SELECT COUNT(*) FROM checklist_item;") == 0)
    }

    // MARK: - Subtasks

    @Test("A card can be made a subtask of another")
    func subtasks() throws {
        let f = try fixture()
        let parent = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Parent")
        let child = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Child")

        try f.tasks.setParent(parent.id, for: child.id)

        #expect(try f.tasks.subtasks(of: parent.id).map(\.title) == ["Child"])
        #expect(try f.tasks.tasks(matching: "is:subtask", inProject: f.ids.project).map(\.title) == ["Child"])
    }

    /// Without the guard a card could become its own ancestor, and every walk
    /// of the tree afterwards would run forever.
    @Test("A card cannot be made its own ancestor")
    func noCycles() throws {
        let f = try fixture()
        let a = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "A")
        let b = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "B")
        let c = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "C")

        try f.tasks.setParent(a.id, for: b.id)
        try f.tasks.setParent(b.id, for: c.id)

        #expect(throws: LocalBoardError.self) { try f.tasks.setParent(a.id, for: a.id) }
        #expect(throws: LocalBoardError.self) { try f.tasks.setParent(c.id, for: a.id) }

        // The tree is unchanged by the refusals.
        #expect(try f.tasks.subtasks(of: a.id).map(\.title) == ["B"])
    }

    @Test("Subtask progress counts the finished ones")
    func subtaskProgress() throws {
        let f = try fixture()
        let parent = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Parent")
        let one = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "One")
        let two = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Two")
        try f.tasks.setParent(parent.id, for: one.id)
        try f.tasks.setParent(parent.id, for: two.id)

        _ = try f.tasks.move(one.id, toStatus: f.ids.done)

        #expect(try f.boards.snapshot(boardID: f.ids.board).subtasks[parent.id] == ChecklistProgress(done: 1, total: 2))
    }

    @Test("Deleting a parent takes its subtasks")
    func subtasksCascade() throws {
        let f = try fixture()
        let parent = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Parent")
        let child = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Child")
        try f.tasks.setParent(parent.id, for: child.id)

        try f.database.execute("DELETE FROM task WHERE id = ?;", [parent.id])
        #expect(try f.database.count("SELECT COUNT(*) FROM task;") == 0)
    }

    // MARK: - Epics

    @Test("Work can be filed under an epic, and only under an epic")
    func epics() throws {
        let f = try fixture()
        let epic = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Milestone 3", type: .epic)
        let work = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Some work")
        let notAnEpic = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Ordinary")

        try f.tasks.setEpic(epic.id, for: work.id)
        #expect(try f.tasks.tasks(inEpic: epic.id).map(\.title) == ["Some work"])
        #expect(try f.tasks.epics(inProject: f.ids.project).map(\.title) == ["Milestone 3"])

        #expect(throws: LocalBoardError.self) { try f.tasks.setEpic(notAnEpic.id, for: work.id) }
    }

    /// An epic is a heading work is filed under, not a container it lives in.
    @Test("Deleting an epic unfiles its work rather than deleting it")
    func deletingEpic() throws {
        let f = try fixture()
        let epic = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Epic", type: .epic)
        let work = try f.tasks.create(inProject: f.ids.project, statusID: f.ids.toDo, title: "Work")
        try f.tasks.setEpic(epic.id, for: work.id)

        try f.database.execute("DELETE FROM task WHERE id = ?;", [epic.id])

        #expect(try f.tasks.task(id: work.id).epicID == nil)
        #expect(try f.database.count("SELECT COUNT(*) FROM task;") == 1)
    }
}
