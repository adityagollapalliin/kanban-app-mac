import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

/// The round trip the brief asks for: a project written out and read back has
/// to be the same work.
@Suite("Export and import")
struct ProjectArchiveTests {

    /// Builds a project with something of everything the format promises to
    /// carry, so a field that silently stops round-tripping fails here.
    @discardableResult
    private func seedRichProject(in database: Database) throws -> (project: String, toDo: String) {
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let people = PersonRepository(database: database)
        let labels = LabelRepository(database: database)
        let checklists = ChecklistRepository(database: database)

        let ada = try people.create(name: "Ada Lovelace")
        let urgent = try labels.create(inProject: ids.project, name: "urgent", color: "red")

        let epic = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "The epic")
        try tasks.setType(.epic, for: epic.id)

        let story = try tasks.create(inProject: ids.project, statusID: ids.inProgress, title: "The story")
        try tasks.setAssignee(ada.id, for: story.id)
        try tasks.setPriority(.highest, for: story.id)
        try tasks.setDueDate(Date(timeIntervalSince1970: 1_700_000_000), for: story.id)
        try tasks.setEstimate(5, for: story.id)
        try tasks.setFlag(true, reason: "waiting on review", for: story.id)
        try tasks.setEpic(epic.id, for: story.id)
        try labels.setLabel(urgent.id, on: story.id, attached: true)
        try checklists.add(toTask: story.id, text: "Write it down")

        _ = try tasks.create(inProject: ids.project, statusID: ids.done, title: "Finished")
        return (ids.project, ids.toDo)
    }

    @Test("A project exported and imported is the same work")
    func roundTrip() throws {
        let database = try Database.inMemoryMigrated()
        let seeded = try seedRichProject(in: database)

        let archive = try ProjectArchive.export(projectID: seeded.project, from: database)
        let data = try archive.encoded()
        let restored = try ProjectArchive.decoded(from: data).restore(into: database)

        let imported = try ProjectArchive.export(projectID: restored.project.id, from: database)

        #expect(imported.tasks.count == archive.tasks.count)
        #expect(Set(imported.tasks.map(\.title)) == Set(archive.tasks.map(\.title)))
        #expect(Set(imported.statuses.map(\.name)) == Set(archive.statuses.map(\.name)))

        // The fields a card would quietly lose one at a time.
        let story = try #require(imported.tasks.first { $0.title == "The story" })
        let original = try #require(archive.tasks.first { $0.title == "The story" })
        #expect(story.number == original.number)
        #expect(story.priority == .highest)
        #expect(story.estimate == 5)
        #expect(story.dueDate == original.dueDate)
        #expect(story.flagged)
        #expect(story.flagReason == "waiting on review")
        #expect(story.assigneeID != nil)

        // The links between cards are remapped, not carried over verbatim.
        let epic = try #require(imported.tasks.first { $0.title == "The epic" })
        #expect(story.epicID == epic.id)
        #expect(story.epicID != original.epicID)

        #expect(imported.labels.map(\.name) == ["urgent"])
        #expect(imported.taskLabels.count == 1)
        #expect(imported.checklists.map(\.text) == ["Write it down"])
        #expect(imported.people.map(\.name) == ["Ada Lovelace"])
    }

    /// Ids are regenerated so an archive can be imported back into the file it
    /// came from, which is the case a backup is actually used in.
    @Test("Importing into the same file leaves the original alone")
    func importsAlongsideItself() throws {
        let database = try Database.inMemoryMigrated()
        let seeded = try seedRichProject(in: database)
        let before = try ProjectArchive.export(projectID: seeded.project, from: database)

        let restored = try before.restore(into: database)
        let after = try ProjectArchive.export(projectID: seeded.project, from: database)

        #expect(restored.project.id != seeded.project)
        #expect(after.tasks.count == before.tasks.count)
        #expect(Set(after.tasks.map(\.id)) == Set(before.tasks.map(\.id)))
    }

    /// Two projects cannot share a key, and an import that stopped over three
    /// letters would have wasted the user's time on something the app can
    /// settle itself.
    @Test("A key already in use gets a digit rather than a refusal")
    func keyCollision() throws {
        let database = try Database.inMemoryMigrated()
        let seeded = try seedRichProject(in: database)
        let archive = try ProjectArchive.export(projectID: seeded.project, from: database)

        let first = try archive.restore(into: database)
        let second = try archive.restore(into: database)

        #expect(first.project.key == "WORK1")
        #expect(second.project.key == "WORK2")
    }

    /// A person belongs to the file, not to one project: importing a project
    /// that names Ada twice must not produce two Adas.
    @Test("Assignees are matched to people already here, by name")
    func peopleMatchedByName() throws {
        let database = try Database.inMemoryMigrated()
        let seeded = try seedRichProject(in: database)
        let archive = try ProjectArchive.export(projectID: seeded.project, from: database)

        let restored = try archive.restore(into: database)
        #expect(restored.reusedPeople == 1)
        #expect(try PersonRepository(database: database).people().count == 1)
    }

    /// An archive from an older build has none of the fields added since, and
    /// it still has to import: that is what "optional on the way in" buys.
    @Test("A file without the newer fields still imports")
    func olderFileStillImports() throws {
        let database = try Database.inMemoryMigrated()
        let seeded = try seedRichProject(in: database)
        let archive = try ProjectArchive.export(projectID: seeded.project, from: database)

        var trimmed = try #require(
            try JSONSerialization.jsonObject(with: try archive.encoded()) as? [String: Any]
        )
        for key in ["people", "labels", "taskLabels", "checklists"] { trimmed.removeValue(forKey: key) }
        let data = try JSONSerialization.data(withJSONObject: trimmed)

        let restored = try ProjectArchive.decoded(from: data).restore(into: database)
        #expect(restored.taskCount == archive.tasks.count)
        // The cards arrive; the assignee it could not name does not.
        let imported = try ProjectArchive.export(projectID: restored.project.id, from: database)
        #expect(imported.tasks.allSatisfy { $0.assigneeID == nil })
    }

    /// The opposite direction is a refusal, because a newer file may describe
    /// things this build has no column for, and half an import is worse than
    /// none.
    @Test("An archive from a newer build is refused, with a reason")
    func newerFileRefused() throws {
        let database = try Database.inMemoryMigrated()
        let seeded = try seedRichProject(in: database)
        let archive = try ProjectArchive.export(projectID: seeded.project, from: database)

        let future = ProjectArchive(
            schemaVersion: Migration.latestVersion + 1,
            exportedAt: archive.exportedAt,
            project: archive.project,
            statuses: archive.statuses,
            tasks: archive.tasks
        )
        #expect(throws: LocalBoardError.self) { try future.restore(into: database) }
    }

    @Test("Something that is not an archive is refused readably")
    func garbageRefused() throws {
        #expect(throws: LocalBoardError.self) {
            try ProjectArchive.decoded(from: Data("not json".utf8))
        }
    }

    /// Analytics read `status_change`, and a project imported without any
    /// would draw as though none of its cards had ever existed.
    @Test("Imported cards arrive with a history to read")
    func historyIsWritten() throws {
        let database = try Database.inMemoryMigrated()
        let seeded = try seedRichProject(in: database)
        let archive = try ProjectArchive.export(projectID: seeded.project, from: database)

        let restored = try archive.restore(into: database)
        let changes = try database.count(
            """
            SELECT COUNT(*) FROM status_change
            JOIN task ON task.id = status_change.task_id
            WHERE task.project_id = ?;
            """,
            [restored.project.id]
        )
        #expect(changes == restored.taskCount)
    }

    @Test("Trashed cards stay out unless asked for")
    func trashedExcluded() throws {
        let database = try Database.inMemoryMigrated()
        let seeded = try seedRichProject(in: database)
        let tasks = TaskRepository(database: database)
        let doomed = try tasks.create(inProject: seeded.project, statusID: seeded.toDo, title: "Thrown away")
        try tasks.setTrashed(true, for: doomed.id)

        let without = try ProjectArchive.export(projectID: seeded.project, from: database)
        let with = try ProjectArchive.export(projectID: seeded.project, from: database, includeTrashed: true)

        #expect(!without.tasks.contains { $0.title == "Thrown away" })
        #expect(with.tasks.contains { $0.title == "Thrown away" })
    }
}
