import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

private func fixture() throws -> (
    Database, StoppedClock,
    (workspace: String, project: String, board: String, toDo: String, inProgress: String, done: String)
) {
    let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
    let database = try Database.inMemoryMigrated()
    return (database, clock, try database.seedBoardProject())
}

@Suite("The words a project uses")
struct VocabularyTests {

    @Test("Every project starts with the four kinds of card it always had")
    func seededIssueTypes() throws {
        let (database, clock, ids) = try fixture()
        let types = try VocabularyRepository(database: database, clock: clock)
            .issueTypes(inProject: ids.project)

        #expect(types.map(\.name) == ["Epic", "Story", "Task", "Bug"])
        // Under exactly the numbers the cards already hold, which is what lets
        // `task.type` stay an integer nobody had to rewrite.
        #expect(types.map(\.code) == [0, 1, 2, 3])
        #expect(types.map(\.builtIn) == [.epic, .story, .task, .bug])
        // Epic sits a level above the rest.
        #expect(types.first { $0.name == "Epic" }?.level == 1)
        #expect(types.first { $0.name == "Bug" }?.level == 0)
    }

    @Test("A new kind of card takes the next free number, and cards can be it")
    func addingAnIssueType() throws {
        let (database, clock, ids) = try fixture()
        let vocabulary = VocabularyRepository(database: database, clock: clock)
        let tasks = TaskRepository(database: database, clock: clock)

        let initiative = try vocabulary.addIssueType(
            inProject: ids.project, name: "Initiative", symbol: "flag", level: 2
        )
        #expect(initiative.code == 4)
        #expect(initiative.builtIn == nil)

        // A card can be that kind, and still loads — the raw code is kept,
        // and the built-in enumeration reads it as ordinary work rather than
        // refusing the row.
        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Q3 push")
        try database.execute("UPDATE task SET type = ? WHERE id = ?;", [initiative.code, card.id])

        let loaded = try tasks.task(id: card.id)
        #expect(loaded.typeCode == 4)
        #expect(loaded.type == .task)
    }

    @Test("A duplicate name is refused")
    func duplicateIssueType() throws {
        let (database, clock, ids) = try fixture()
        let vocabulary = VocabularyRepository(database: database, clock: clock)
        #expect(throws: (any Error).self) {
            try vocabulary.addIssueType(inProject: ids.project, name: "bug")
        }
    }

    @Test("A kind still in use cannot be deleted")
    func deletingAKindInUse() throws {
        let (database, clock, ids) = try fixture()
        let vocabulary = VocabularyRepository(database: database, clock: clock)
        let tasks = TaskRepository(database: database, clock: clock)

        let kind = try vocabulary.addIssueType(inProject: ids.project, name: "Spike")
        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Investigate")
        try database.execute("UPDATE task SET type = ? WHERE id = ?;", [kind.code, card.id])

        // Moving those cards elsewhere is a decision about somebody's work.
        #expect(throws: (any Error).self) {
            try vocabulary.deleteIssueType(code: kind.code, inProject: ids.project)
        }

        try database.execute("UPDATE task SET type = 2 WHERE id = ?;", [card.id])
        try vocabulary.deleteIssueType(code: kind.code, inProject: ids.project)
        #expect(try vocabulary.issueTypes(inProject: ids.project).count == 4)
    }

    @Test("A trashed card still holds its kind, so the kind cannot be deleted")
    func trashedCardsCount() throws {
        let (database, clock, ids) = try fixture()
        let vocabulary = VocabularyRepository(database: database, clock: clock)
        let tasks = TaskRepository(database: database, clock: clock)

        let kind = try vocabulary.addIssueType(inProject: ids.project, name: "Spike")
        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Investigate")
        try database.execute("UPDATE task SET type = ? WHERE id = ?;", [kind.code, card.id])
        try tasks.setTrashed(true, for: card.id)

        // A trashed card can be brought back, and a code handed to a different
        // kind in the meantime would silently relabel it.
        #expect(throws: (any Error).self) {
            try vocabulary.deleteIssueType(code: kind.code, inProject: ids.project)
        }
    }

    @Test("The priority scale starts with ranks equal to codes")
    func seededPriorities() throws {
        let (database, clock, ids) = try fixture()
        let values = try VocabularyRepository(database: database, clock: clock)
            .priorities(inProject: ids.project)

        #expect(values.map(\.name) == ["Lowest", "Low", "Normal", "High", "Highest"])
        // This is what makes `priority >= high` still compile to an integer
        // comparison against the code.
        #expect(PriorityValue.ranksMatchCodes(values))
    }

    @Test("A priority can be renamed and recoloured")
    func renamingAPriority() throws {
        let (database, clock, ids) = try fixture()
        let vocabulary = VocabularyRepository(database: database, clock: clock)

        var highest = try #require(try vocabulary.priorities(inProject: ids.project).last)
        highest.name = "Drop everything"
        highest.color = "purple"
        try vocabulary.updatePriority(highest)

        let after = try #require(try vocabulary.priorities(inProject: ids.project).last)
        #expect(after.name == "Drop everything")
        #expect(after.rank == 4)
    }

    @Test("Link types are pairs, read from whichever end you are standing on")
    func seededLinkTypes() throws {
        let (database, clock, ids) = try fixture()
        let types = try VocabularyRepository(database: database, clock: clock)
            .linkTypes(inProject: ids.project)

        #expect(types.map(\.outward) == ["Blocks", "Relates to", "Duplicates"])
        let blocks = try #require(types.first)
        #expect(blocks.label(outward: true) == "Blocks")
        #expect(blocks.label(outward: false) == "Is blocked by")
        #expect(!blocks.isSymmetric)

        let relates = try #require(types.first { $0.outward == "Relates to" })
        #expect(relates.isSymmetric)
    }

    @Test("A new link pair steps over the numbers the old inverses used")
    func addingALinkType() throws {
        let (database, clock, ids) = try fixture()
        let added = try VocabularyRepository(database: database, clock: clock)
            .addLinkType(inProject: ids.project, outward: "Causes", inward: "Is caused by")
        // 1 and 4 were the inverse-only spellings and may still be on links
        // written before v9.
        #expect(added.code >= 5)
    }

    @Test("Every project starts with the four resolutions, one of them default")
    func seededResolutions() throws {
        let (database, clock, ids) = try fixture()
        let vocabulary = VocabularyRepository(database: database, clock: clock)
        let all = try vocabulary.resolutions(inProject: ids.project)

        #expect(all.map(\.name) == ["Done", "Won't Do", "Duplicate", "Cannot Reproduce"])
        #expect(try vocabulary.defaultResolution(inProject: ids.project)?.name == "Done")
    }

    @Test("Exactly one resolution is the default")
    func oneDefaultResolution() throws {
        let (database, clock, ids) = try fixture()
        let vocabulary = VocabularyRepository(database: database, clock: clock)
        let duplicate = try #require(
            try vocabulary.resolutions(inProject: ids.project).first { $0.name == "Duplicate" }
        )

        try vocabulary.setDefaultResolution(duplicate.id)
        let all = try vocabulary.resolutions(inProject: ids.project)
        #expect(all.filter(\.isDefault).map(\.name) == ["Duplicate"])
    }

    @Test("The default resolution cannot be deleted out from under the project")
    func cannotDeleteDefault() throws {
        let (database, clock, ids) = try fixture()
        let vocabulary = VocabularyRepository(database: database, clock: clock)
        let done = try #require(try vocabulary.defaultResolution(inProject: ids.project))
        #expect(throws: (any Error).self) { try vocabulary.deleteResolution(done.id) }
    }
}

@Suite("Why a card was closed")
struct ResolutionTests {

    @Test("Finishing a card gives it the default resolution and a date")
    func resolvingOnMove() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Ship it")
        #expect(try components.resolution(forTask: card.id) == nil)

        try tasks.move(card.id, toStatus: ids.done)
        #expect(try components.resolution(forTask: card.id)?.name == "Done")
        #expect(try tasks.task(id: card.id).completedAt != nil)
    }

    @Test("Reopening clears it, because an open card has no reason for being closed")
    func reopeningClears() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Ship it")
        try tasks.move(card.id, toStatus: ids.done)
        try tasks.move(card.id, toStatus: ids.inProgress)

        #expect(try components.resolution(forTask: card.id) == nil)
    }

    @Test("A resolution somebody chose is not overwritten by the default")
    func chosenResolutionSurvives() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)
        let vocabulary = VocabularyRepository(database: database, clock: clock)

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "A duplicate")
        let duplicate = try #require(
            try vocabulary.resolutions(inProject: ids.project).first { $0.name == "Duplicate" }
        )
        try components.setResolution(duplicate.id, forTask: card.id)
        try tasks.move(card.id, toStatus: ids.done)

        #expect(try components.resolution(forTask: card.id)?.name == "Duplicate")
    }

    @Test("It follows the column's category, not its name")
    func categoryNotName() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        // A last column called something else entirely.
        try database.execute("UPDATE status SET name = 'Shipped' WHERE id = ?;", [ids.done])
        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Ship it")
        try tasks.move(card.id, toStatus: ids.done)

        #expect(try components.resolution(forTask: card.id)?.name == "Done")
    }

    @Test("Cards already finished were given the default when the schema arrived")
    func migrationBackfill() throws {
        // v9 interprets a finished card as resolved "Done" on the day it was
        // finished. Nobody was asked; it is the only defensible reading, and
        // it is recorded as a reading rather than a fact.
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Old work")
        try tasks.move(card.id, toStatus: ids.done)

        let row = try #require(try database.queryOne(
            "SELECT resolved_at, completed_at FROM task WHERE id = ?;", [card.id]
        ))
        #expect(row.date("resolved_at") != nil)
    }
}

@Suite("Components, and the versions a card touches")
struct ComponentTests {

    @Test("A component's default assignee catches work nobody assigned")
    func defaultAssignee() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let people = PersonRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        let ada = try people.create(name: "Ada Lovelace")
        let parser = try components.create(
            inProject: ids.project, name: "Parser", defaultAssigneeID: ada.id
        )

        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Fix the lexer")
        try components.add(parser.id, toTask: card.id)

        #expect(try tasks.task(id: card.id).assigneeID == ada.id)
    }

    @Test("A card somebody already assigned is left alone")
    func doesNotOverrideAnAssignee() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let people = PersonRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        let ada = try people.create(name: "Ada Lovelace")
        let grace = try people.create(name: "Grace Hopper")
        let parser = try components.create(
            inProject: ids.project, name: "Parser", defaultAssigneeID: ada.id
        )

        let card = try tasks.create(
            inProject: ids.project, statusID: ids.toDo, title: "Fix the lexer", assigneeID: grace.id
        )
        try components.add(parser.id, toTask: card.id)

        // Somebody already chose.
        #expect(try tasks.task(id: card.id).assigneeID == grace.id)
    }

    @Test("A card can be in several components")
    func severalComponents() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        let parser = try components.create(inProject: ids.project, name: "Parser")
        let ui = try components.create(inProject: ids.project, name: "UI")
        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Both")

        try components.add(parser.id, toTask: card.id)
        try components.add(ui.id, toTask: card.id)
        #expect(try components.components(forTask: card.id).map(\.name) == ["Parser", "UI"])

        try components.remove(parser.id, fromTask: card.id)
        #expect(try components.components(forTask: card.id).map(\.name) == ["UI"])
    }

    @Test("Deleting a component takes the tag off cards and nothing else")
    func deletingAComponent() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        let parser = try components.create(inProject: ids.project, name: "Parser")
        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Tagged")
        try components.add(parser.id, toTask: card.id)

        try components.delete(parser.id)
        #expect(try components.components(forTask: card.id).isEmpty)
        #expect(try tasks.task(id: card.id).title == "Tagged")
    }

    @Test("The first fix version stays on the card, as the assignee does")
    func firstFixVersionIsMirrored() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let versions = VersionRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        let one = try versions.create(inProject: ids.project, name: "1.0")
        let two = try versions.create(inProject: ids.project, name: "1.1")
        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Fixed")

        try components.add(one.id, toTask: card.id, as: .fix)
        try components.add(two.id, toTask: card.id, as: .fix)

        // Everything that reads `task.version_id` — the badge, the release
        // report, `version = "1.0"` — carries on working.
        #expect(try tasks.task(id: card.id).versionID == one.id)
        #expect(try components.versions(forTask: card.id, role: .fix).count == 2)

        try components.remove(one.id, fromTask: card.id, as: .fix)
        #expect(try tasks.task(id: card.id).versionID == two.id)
    }

    @Test("Affects and fix versions are kept apart")
    func affectsIsSeparate() throws {
        let (database, clock, ids) = try fixture()
        let tasks = TaskRepository(database: database, clock: clock)
        let versions = VersionRepository(database: database, clock: clock)
        let components = ComponentRepository(database: database, clock: clock)

        let one = try versions.create(inProject: ids.project, name: "1.0")
        let card = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "A bug")

        try components.add(one.id, toTask: card.id, as: .affects)
        #expect(try components.versions(forTask: card.id, role: .affects).map(\.name) == ["1.0"])
        #expect(try components.versions(forTask: card.id, role: .fix).isEmpty)
        // An affects version is not a fix version, so the card's own column
        // stays empty.
        #expect(try tasks.task(id: card.id).versionID == nil)
    }
}
