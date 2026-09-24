import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("People")
struct PersonRepositoryTests {

    @Test("People come back in the order they were added")
    func ordering() throws {
        let database = try Database.inMemoryMigrated()
        let people = PersonRepository(database: database)

        try people.create(name: "Sam")
        try people.create(name: "Ada")

        #expect(try people.people().map(\.name) == ["Sam", "Ada"])
    }

    @Test("Names are trimmed, and a blank one is refused")
    func names() throws {
        let database = try Database.inMemoryMigrated()
        let people = PersonRepository(database: database)

        let person = try people.create(name: "  Ada  ")
        #expect(person.name == "Ada")

        #expect(throws: LocalBoardError.self) { try people.create(name: "   ") }
    }

    @Test("A person can be renamed")
    func renaming() throws {
        let database = try Database.inMemoryMigrated()
        let people = PersonRepository(database: database)
        let person = try people.create(name: "Ada")

        try people.rename(person.id, to: "Ada Lovelace")
        #expect(try people.person(id: person.id).name == "Ada Lovelace")
    }

    /// Someone leaving should not take their work with them.
    @Test("Deleting a person unassigns their cards instead of deleting them")
    func deletingUnassigns() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let people = PersonRepository(database: database)
        let tasks = TaskRepository(database: database)

        let person = try people.create(name: "Ada")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Assigned work")
        try tasks.setAssignee(person.id, for: task.id)
        #expect(try tasks.task(id: task.id).assigneeID == person.id)

        try people.delete(person.id)

        #expect(try people.people().isEmpty)
        #expect(try tasks.task(id: task.id).assigneeID == nil)
        #expect(try database.count("SELECT COUNT(*) FROM task;") == 1)
    }

    @Test("Deleting someone who is not there is an error")
    func deletingMissing() throws {
        let database = try Database.inMemoryMigrated()
        #expect(throws: LocalBoardError.self) {
            try PersonRepository(database: database).delete(UUID().uuidString)
        }
    }

    @Test("assignee = \"name\" finds their cards")
    func queryByAssignee() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let people = PersonRepository(database: database)
        let tasks = TaskRepository(database: database)

        let ada = try people.create(name: "Ada")
        let mine = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Ada's card")
        try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Nobody's card")
        try tasks.setAssignee(ada.id, for: mine.id)

        #expect(try tasks.tasks(matching: "assignee = Ada", inProject: ids.project).map(\.title) == ["Ada's card"])
        #expect(try tasks.tasks(matching: "is:unassigned", inProject: ids.project).map(\.title) == ["Nobody's card"])
        #expect(try tasks.tasks(matching: "is:assigned", inProject: ids.project).map(\.title) == ["Ada's card"])
    }
}
