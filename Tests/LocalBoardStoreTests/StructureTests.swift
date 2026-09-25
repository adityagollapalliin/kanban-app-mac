import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("Spaces, folders and lists")
struct StructureTests {

    @Test("An upgraded file has one list holding everything it had")
    func migrationGivesEveryProjectAList() throws {
        let database = try Database(location: .memory)
        try database.migrate(using: Migration.all.filter { $0.version <= 5 })
        let ids = try database.seedBoardProject()
        try database.insertTask(project: ids.project, status: ids.toDo, number: 1, title: "Already here")

        try database.migrate()

        let lists = try StructureRepository(database: database).lists(inSpace: ids.project)
        #expect(lists.count == 1)
        #expect(lists[0].name == "Work")

        // And the card it already had lives in it.
        let homed = try database.query("SELECT list_id FROM task;").compactMap { $0.string("list_id") }
        #expect(homed == [lists[0].id])
    }

    @Test("A list can sit in the space or in a folder")
    func listsWithAndWithoutFolders() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let structure = StructureRepository(database: database)

        let folder = try structure.createFolder(inSpace: ids.project, name: "Platform")
        let inFolder = try structure.createList(inSpace: ids.project, folderID: folder.id, name: "Parser")
        let loose = try structure.createList(inSpace: ids.project, name: "Odd jobs")

        let arrangement = try structure.listsByFolder(inSpace: ids.project)
        #expect(arrangement.foldered[folder.id]?.map(\.id) == [inFolder.id])
        #expect(arrangement.loose.contains { $0.id == loose.id })
    }

    /// Tidying a sidebar must not be destructive: the lists survive and fall
    /// back into the space, which is an ordinary place for a list to be.
    @Test("Deleting a folder keeps its lists")
    func deletingAFolderKeepsLists() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let structure = StructureRepository(database: database)

        let folder = try structure.createFolder(inSpace: ids.project, name: "Platform")
        let list = try structure.createList(inSpace: ids.project, folderID: folder.id, name: "Parser")

        try structure.deleteFolder(folder.id)

        let survivor = try structure.list(id: list.id)
        #expect(survivor.folderID == nil)
    }

    /// Nothing in the app destroys work outright: a list deleted without
    /// somewhere for its cards to go trashes them, and the trash is a place
    /// they come back from.
    @Test("Deleting a list either moves its cards or trashes them")
    func deletingAListHandlesItsCards() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let structure = StructureRepository(database: database)
        let tasks = TaskRepository(database: database)

        let home = try #require(try structure.lists(inSpace: ids.project).first)
        let other = try structure.createList(inSpace: ids.project, name: "Elsewhere")
        let moved = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Moves")
        let doomed = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Trashed")
        try MembershipRepository(database: database).setHomeList(other.id, forTask: doomed.id)

        try structure.deleteList(home.id, movingCardsTo: other.id)
        #expect(try tasks.task(id: moved.id).listID == other.id)

        try structure.deleteList(other.id, movingCardsTo: nil)
        #expect(try tasks.task(id: doomed.id).trashed)
        #expect(try tasks.task(id: doomed.id).trashedAt != nil)
    }

    /// Inheritance is the absence of rows rather than a flag, so there is no
    /// state where a list claims to override and overrides nothing.
    @Test("A list uses its space's statuses until it says otherwise")
    func statusesInheritThenOverride() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let structure = StructureRepository(database: database)
        let list = try #require(try structure.lists(inSpace: ids.project).first)

        #expect(try structure.statuses(forList: list.id).count == 3)
        #expect(try structure.overridesStatuses(list.id) == false)

        try structure.setStatuses([ids.toDo, ids.done], forList: list.id)
        #expect(try structure.statuses(forList: list.id).map(\.id) == [ids.toDo, ids.done])
        #expect(try structure.overridesStatuses(list.id))

        // Emptying the override is how a list goes back — the same action,
        // not a separate verb that could disagree with the rows.
        try structure.setStatuses([], forList: list.id)
        #expect(try structure.statuses(forList: list.id).count == 3)
    }

    @Test("A new space starts with a list to put cards in")
    func newSpaceHasAList() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let boards = BoardRepository(database: database)

        let space = try boards.createProject(inWorkspace: ids.workspace, name: "Second", key: "TWO")
        let lists = try StructureRepository(database: database).lists(inSpace: space.id)
        #expect(lists.count == 1)

        // And a card added to it lands there without being told which.
        let task = try TaskRepository(database: database).create(
            inProject: space.id,
            statusID: try #require(try database.queryOne(
                "SELECT id FROM status WHERE project_id = ? ORDER BY sort_order LIMIT 1;", [space.id]
            )?.string("id")),
            title: "Homed"
        )
        #expect(task.listID == lists[0].id)
    }
}

@Suite("Several people, and several lists")
struct MembershipTests {

    @Test("The first assignee is the one the card already knew about")
    func firstAssigneeIsThePrimary() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let people = PersonRepository(database: database)
        let membership = MembershipRepository(database: database)

        let ada = try people.create(name: "Ada")
        let grace = try people.create(name: "Grace")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Shared")

        try membership.addAssignee(ada.id, to: task.id)
        try membership.addAssignee(grace.id, to: task.id)

        #expect(try membership.assignees(ofTask: task.id).count == 2)
        // Everything written before this table existed reads `assignee_id`,
        // and it still says something true.
        #expect(try tasks.task(id: task.id).assigneeID == ada.id)

        try membership.removeAssignee(ada.id, from: task.id)
        #expect(try tasks.task(id: task.id).assigneeID == grace.id)

        try membership.removeAssignee(grace.id, from: task.id)
        #expect(try tasks.task(id: task.id).assigneeID == nil)
    }

    @Test("An upgraded file keeps the assignee it already had")
    func migrationCarriesAssignees() throws {
        let database = try Database(location: .memory)
        try database.migrate(using: Migration.all.filter { $0.version <= 5 })
        let ids = try database.seedBoardProject()
        let now = Date().timeIntervalSince1970
        try database.execute(
            "INSERT INTO person (id, name, color, sort_order, created_at) VALUES ('ada', 'Ada', 'red', 1000.0, ?);",
            [now]
        )
        try database.insertTask(project: ids.project, status: ids.toDo, number: 1, title: "Assigned")
        try database.execute("UPDATE task SET assignee_id = 'ada';")

        try database.migrate()

        let taskID = try #require(try database.queryOne("SELECT id FROM task;")?.string("id"))
        #expect(try MembershipRepository(database: database).assignees(ofTask: taskID).map(\.personID) == ["ada"])
    }

    @Test("A card has one home and can be shown in other lists")
    func tasksInMultipleLists() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let structure = StructureRepository(database: database)
        let membership = MembershipRepository(database: database)
        let tasks = TaskRepository(database: database)

        let home = try #require(try structure.lists(inSpace: ids.project).first)
        let other = try structure.createList(inSpace: ids.project, name: "This week")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Borrowed")

        try membership.addTask(task.id, toList: other.id)

        #expect(try membership.tasks(inList: home.id).map(\.id) == [task.id])
        #expect(try membership.tasks(inList: other.id).map(\.id) == [task.id])
        #expect(try membership.extraLists(ofTask: task.id).map(\.id) == [other.id])
        #expect(try membership.borrowedTaskIDs(inList: other.id) == [task.id])
        #expect(try membership.borrowedTaskIDs(inList: home.id).isEmpty)
    }

    /// Adding a card to the list it already lives in would show it twice.
    @Test("A card cannot be added to its own home list")
    func homeListIsNotAlsoAMembership() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let membership = MembershipRepository(database: database)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Home")
        let home = try #require(task.listID)

        try membership.addTask(task.id, toList: home)
        #expect(try membership.extraLists(ofTask: task.id).isEmpty)
        #expect(try membership.tasks(inList: home).count == 1)
    }

    /// A card that has moved house is still on the same noticeboards.
    @Test("Moving home keeps the other lists it appears in")
    func movingHomeKeepsMemberships() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let structure = StructureRepository(database: database)
        let membership = MembershipRepository(database: database)
        let tasks = TaskRepository(database: database)

        let second = try structure.createList(inSpace: ids.project, name: "Second")
        let third = try structure.createList(inSpace: ids.project, name: "Third")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Travelling")

        try membership.addTask(task.id, toList: second.id)
        try membership.addTask(task.id, toList: third.id)
        try membership.setHomeList(second.id, forTask: task.id)

        #expect(try tasks.task(id: task.id).listID == second.id)
        // The membership it no longer needs is gone; the other stays.
        #expect(try membership.extraLists(ofTask: task.id).map(\.id) == [third.id])
    }
}
