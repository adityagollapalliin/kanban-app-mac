import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("Comments")
struct CommentTests {

    @Test("An edited comment says it was edited")
    func editing() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let details = CardDetailRepository(database: database)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Talked about")
        let comment = try details.addComment(toTask: task.id, body: "First thought")
        #expect(comment.editedAt == nil)

        try details.editComment(comment.id, body: "Second thought")

        let loaded = try #require(try details.comments(forTask: task.id).first)
        #expect(loaded.bodyMarkdown == "Second thought")
        #expect(loaded.editedAt != nil)
    }

    @Test("An empty comment is refused")
    func emptyRefused() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let details = CardDetailRepository(database: database)
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Quiet")

        #expect(throws: LocalBoardError.self) {
            try details.addComment(toTask: task.id, body: "   ")
        }
    }

    @Test("Deleting a card takes its comments with it")
    func cascade() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let details = CardDetailRepository(database: database)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Doomed")
        try details.addComment(toTask: task.id, body: "Something")

        try database.execute("DELETE FROM task WHERE id = ?;", [task.id])
        #expect(try database.count("SELECT COUNT(*) FROM comment;") == 0)
    }
}

@Suite("Links between cards")
struct TaskLinkTests {

    private func twoCards() throws -> (Database, CardDetailRepository, BoardTask, BoardTask) {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let first = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "First")
        let second = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Second")
        return (database, CardDetailRepository(database: database), first, second)
    }

    /// One row, read from both ends. This is the whole reason the inverse is
    /// derived rather than stored: two rows could disagree, and one cannot.
    @Test("A link reads as its inverse from the other card")
    func inverseIsDerived() throws {
        let (_, details, first, second) = try twoCards()
        try details.link(first.id, .blocks, to: second.id)

        let fromFirst = try details.links(forTask: first.id)
        #expect(fromFirst.count == 1)
        #expect(fromFirst[0].kind == .blocks)
        #expect(fromFirst[0].otherID == second.id)

        let fromSecond = try details.links(forTask: second.id)
        #expect(fromSecond.count == 1)
        #expect(fromSecond[0].kind == .blockedBy)
        #expect(fromSecond[0].otherID == first.id)
        // And it is the same row, so unlinking from either end removes both.
        #expect(fromSecond[0].link.id == fromFirst[0].link.id)
    }

    @Test("Relates-to is its own inverse")
    func symmetric() throws {
        let (_, details, first, second) = try twoCards()
        try details.link(first.id, .relatesTo, to: second.id)

        #expect(try details.links(forTask: second.id).first?.kind == .relatesTo)
    }

    @Test("A card cannot be linked to itself")
    func noSelfLink() throws {
        let (_, details, first, _) = try twoCards()
        #expect(throws: LocalBoardError.self) {
            try details.link(first.id, .blocks, to: first.id)
        }
    }

    @Test("Making the same link twice leaves one")
    func idempotent() throws {
        let (database, details, first, second) = try twoCards()
        try details.link(first.id, .blocks, to: second.id)
        try details.link(first.id, .blocks, to: second.id)

        #expect(try database.count("SELECT COUNT(*) FROM task_link;") == 1)
    }

    @Test("Unlinking from one end removes it from both")
    func unlink() throws {
        let (_, details, first, second) = try twoCards()
        let link = try details.link(first.id, .blocks, to: second.id)

        try details.unlink(link.id)

        #expect(try details.links(forTask: first.id).isEmpty)
        #expect(try details.links(forTask: second.id).isEmpty)
    }
}

@Suite("Attachments")
struct AttachmentTests {

    @Test("Attaching copies the file and records it")
    func attaching() throws {
        let container = try TemporaryContainer()
        defer { container.remove() }

        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let details = CardDetailRepository(database: database, paths: container.paths)

        let source = container.paths.dataDirectory.appending(path: "notes.txt")
        try "the original".write(to: source, atomically: true, encoding: .utf8)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "With a file")
        let attachment = try details.attach(source, toTask: task.id)

        #expect(attachment.filename == "notes.txt")
        #expect(attachment.byteSize > 0)

        // A copy: removing the original leaves the attachment alone, which is
        // the point of copying rather than referencing.
        try FileManager.default.removeItem(at: source)
        let stored = try #require(details.url(of: attachment))
        #expect(try String(contentsOf: stored, encoding: .utf8) == "the original")
    }

    /// The path has to be relative to the attachments folder, because the
    /// folder's absolute path differs between the sandboxed app and the CLI.
    @Test("The stored path is relative, not absolute")
    func relativePath() throws {
        let container = try TemporaryContainer()
        defer { container.remove() }

        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let details = CardDetailRepository(database: database, paths: container.paths)

        let source = container.paths.dataDirectory.appending(path: "notes.txt")
        try "x".write(to: source, atomically: true, encoding: .utf8)
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "With a file")

        let attachment = try details.attach(source, toTask: task.id)
        #expect(!attachment.relativePath.hasPrefix("/"))
        #expect(attachment.relativePath.hasPrefix(task.id))
    }

    @Test("Two files of the same name can both be attached")
    func sameNameTwice() throws {
        let container = try TemporaryContainer()
        defer { container.remove() }

        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let details = CardDetailRepository(database: database, paths: container.paths)

        let source = container.paths.dataDirectory.appending(path: "shot.png")
        try "one".write(to: source, atomically: true, encoding: .utf8)
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Two shots")

        try details.attach(source, toTask: task.id)
        try details.attach(source, toTask: task.id)

        let attachments = try details.attachments(forTask: task.id)
        #expect(attachments.count == 2)
        #expect(attachments[0].filename == attachments[1].filename)
        #expect(attachments[0].relativePath != attachments[1].relativePath)
    }

    @Test("Removing an attachment removes the file too")
    func removing() throws {
        let container = try TemporaryContainer()
        defer { container.remove() }

        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let details = CardDetailRepository(database: database, paths: container.paths)

        let source = container.paths.dataDirectory.appending(path: "notes.txt")
        try "x".write(to: source, atomically: true, encoding: .utf8)
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Temporary")
        let attachment = try details.attach(source, toTask: task.id)
        let stored = try #require(details.url(of: attachment))

        try details.removeAttachment(attachment.id)

        #expect(try details.attachments(forTask: task.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stored.path))
    }
}

@Suite("The work log")
struct WorkLogTests {

    @Test("Time logged adds up")
    func totals() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let details = CardDetailRepository(database: database)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Worked on")
        try details.logWork(onTask: task.id, minutes: 90, note: "Morning")
        try details.logWork(onTask: task.id, minutes: 30, note: "After lunch")

        #expect(try details.totalMinutes(forTask: task.id) == 120)
        #expect(try details.workLog(forTask: task.id).count == 2)
    }

    @Test("Logging no time at all is refused")
    func zeroRefused() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let details = CardDetailRepository(database: database)
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Untouched")

        #expect(throws: LocalBoardError.self) {
            try details.logWork(onTask: task.id, minutes: 0)
        }
    }

    /// The day work happened and the day it was written down differ constantly,
    /// and only the first is any use in a report.
    @Test("The day worked is kept apart from the day recorded")
    func workedOnIsItsOwnDay() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database, clock: clock)
        let details = CardDetailRepository(database: database, clock: clock)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "Yesterday's work")
        let yesterday = clock.now.addingTimeInterval(-86_400)

        let entry = try details.logWork(onTask: task.id, minutes: 60, workedOn: yesterday)

        #expect(entry.workedOn == yesterday)
        #expect(entry.createdAt == clock.now)
    }

    @Test("Durations read the way people say them")
    func duration() {
        func entry(_ minutes: Int) -> WorkLogEntry {
            WorkLogEntry(id: "", taskID: "", personID: nil, minutes: minutes,
                         workedOn: .now, createdAt: .now)
        }
        #expect(entry(45).duration == "45m")
        #expect(entry(60).duration == "1h")
        #expect(entry(90).duration == "1h 30m")
        #expect(entry(125).duration == "2h 5m")
    }
}
