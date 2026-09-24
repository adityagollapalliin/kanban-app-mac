import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("Saved views")
struct SavedViewRepositoryTests {

    private func fixture() throws -> (Database, SavedViewRepository, String) {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        return (database, SavedViewRepository(database: database), ids.project)
    }

    @Test("A view keeps the query text it was given")
    func storesTheQuery() throws {
        let (_, views, project) = try fixture()
        let view = try views.create(inProject: project, name: "This week", query: "due < +7d")

        #expect(view.name == "This week")
        #expect(view.query == "due < +7d")
        #expect(try views.views(inProject: project).map(\.name) == ["This week"])
    }

    /// A saved view that does not parse is a trap set for later. Better to
    /// refuse it while the person who wrote it is still looking at it.
    @Test("A query that does not parse is refused at save time")
    func refusesUnparseableQuery() throws {
        let (_, views, project) = try fixture()

        #expect(throws: QueryError.self) {
            try views.create(inProject: project, name: "Broken", query: "due < banana")
        }
        #expect(try views.views(inProject: project).isEmpty)
    }

    @Test("Editing a view's query is checked the same way")
    func refusesUnparseableEdit() throws {
        let (_, views, project) = try fixture()
        let view = try views.create(inProject: project, name: "Fine", query: "is:open")

        #expect(throws: QueryError.self) { try views.setQuery("priority >= sideways", for: view.id) }
        #expect(try views.view(id: view.id).query == "is:open")
    }

    @Test("Two views in one project cannot share a name")
    func namesAreUnique() throws {
        let (_, views, project) = try fixture()
        try views.create(inProject: project, name: "This week", query: "due < +7d")

        #expect(throws: LocalBoardError.self) {
            try views.create(inProject: project, name: "this week", query: "is:open")
        }
    }

    @Test("A view can be renamed, but not onto another's name")
    func renaming() throws {
        let (_, views, project) = try fixture()
        let first = try views.create(inProject: project, name: "One", query: "is:open")
        try views.create(inProject: project, name: "Two", query: "is:done")

        try views.rename(first.id, to: "Renamed")
        #expect(try views.view(id: first.id).name == "Renamed")

        #expect(throws: LocalBoardError.self) { try views.rename(first.id, to: "Two") }
    }

    @Test("Renaming a view to what it is already called is allowed")
    func renameToSameName() throws {
        let (_, views, project) = try fixture()
        let view = try views.create(inProject: project, name: "Mine", query: "is:open")

        try views.rename(view.id, to: "Mine")
        #expect(try views.view(id: view.id).name == "Mine")
    }

    @Test("A view can be deleted")
    func deleting() throws {
        let (_, views, project) = try fixture()
        let view = try views.create(inProject: project, name: "Temporary", query: "is:open")

        try views.delete(view.id)
        #expect(try views.views(inProject: project).isEmpty)
        #expect(throws: LocalBoardError.self) { try views.delete(view.id) }
    }

    @Test("A blank name is refused")
    func blankName() throws {
        let (_, views, project) = try fixture()
        #expect(throws: LocalBoardError.self) {
            try views.create(inProject: project, name: "  ", query: "is:open")
        }
    }

    /// The point of storing text rather than results: the same view answers
    /// differently as the board changes.
    @Test("A view re-asks its question rather than remembering an answer")
    func viewsAreQuestionsNotAnswers() throws {
        let (database, views, project) = try fixture()
        let ids = try database.query("SELECT id FROM status ORDER BY sort_order;").compactMap { $0.string("id") }
        let tasks = TaskRepository(database: database)
        let view = try views.create(inProject: project, name: "Bugs", query: "type:bug")

        #expect(try tasks.tasks(matching: view.query, inProject: project).isEmpty)

        let task = try tasks.create(inProject: project, statusID: ids[0], title: "A new bug", type: .bug)

        #expect(try tasks.tasks(matching: view.query, inProject: project).map(\.id) == [task.id])
    }
}
