import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ text: String) -> Date {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 9))!
}

@Suite("The day in front of you")
struct MyWorkTests {

    private func seed() throws -> (Database, StoppedClock, String, (String, String, String)) {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let clock = StoppedClock(day("2026-01-15"))
        let person = try PersonRepository(database: database, clock: clock).create(name: "Ada")
        return (database, clock, person.id, (ids.project, ids.toDo, ids.done))
    }

    @Test("Work falls into overdue, today, the next week, and unscheduled")
    func sections() throws {
        let (database, clock, personID, ids) = try seed()
        let tasks = TaskRepository(database: database, clock: clock)
        let membership = MembershipRepository(database: database, clock: clock)

        func card(_ title: String, due: String?) throws -> BoardTask {
            let task = try tasks.create(inProject: ids.0, statusID: ids.1, title: title)
            if let due { try tasks.setDueDate(day(due), for: task.id) }
            try membership.addAssignee(personID, to: task.id)
            return task
        }

        _ = try card("Late", due: "2026-01-13")
        _ = try card("Due today", due: "2026-01-15")
        _ = try card("Soon", due: "2026-01-19")
        _ = try card("Far off", due: "2026-03-01")
        _ = try card("No date", due: nil)

        let work = try PersonalRepository(database: database, clock: clock, calendar: utc)
            .myWork(for: personID)

        #expect(work.overdue.map(\.title) == ["Late"])
        #expect(work.today.map(\.title) == ["Due today"])
        #expect(work.next.map(\.title) == ["Soon"])
        #expect(work.unscheduled.map(\.title) == ["No date"])
        // Far off is in none of them: the sections are a week, not a life.
        #expect(work.count == 4)
    }

    /// "I am doing this today" and "this is due today" are different
    /// statements, and the day's list is made of the first.
    @Test("Planning a card for today puts it in today without moving its date")
    func planning() throws {
        let (database, clock, personID, ids) = try seed()
        let tasks = TaskRepository(database: database, clock: clock)
        let membership = MembershipRepository(database: database, clock: clock)
        let personal = PersonalRepository(database: database, clock: clock, calendar: utc)

        let task = try tasks.create(inProject: ids.0, statusID: ids.1, title: "Due next week")
        try tasks.setDueDate(day("2026-01-20"), for: task.id)
        try membership.addAssignee(personID, to: task.id)

        #expect(try personal.myWork(for: personID).next.map(\.title) == ["Due next week"])

        try personal.planForToday(task.id)
        let work = try personal.myWork(for: personID)

        #expect(work.today.map(\.title) == ["Due next week"])
        #expect(work.next.isEmpty)
        // And the promise to other people is untouched.
        #expect(try tasks.task(id: task.id).dueDate == day("2026-01-20"))
    }

    /// Choosing to do something today does not undo the fact that it was due
    /// last week.
    @Test("Planning an overdue card leaves it overdue")
    func planningDoesNotHideLateness() throws {
        let (database, clock, personID, ids) = try seed()
        let tasks = TaskRepository(database: database, clock: clock)
        let membership = MembershipRepository(database: database, clock: clock)
        let personal = PersonalRepository(database: database, clock: clock, calendar: utc)

        let task = try tasks.create(inProject: ids.0, statusID: ids.1, title: "Late")
        try tasks.setDueDate(day("2026-01-10"), for: task.id)
        try membership.addAssignee(personID, to: task.id)
        try personal.planForToday(task.id)

        #expect(try personal.myWork(for: personID).overdue.map(\.title) == ["Late"])
    }

    /// The date is a promise to other people; a snooze is five minutes'
    /// peace. Rewriting one with the other quietly rewrites the plan.
    @Test("Snoozing hides something without moving its due date")
    func snoozing() throws {
        let (database, clock, personID, ids) = try seed()
        let tasks = TaskRepository(database: database, clock: clock)
        let membership = MembershipRepository(database: database, clock: clock)
        let personal = PersonalRepository(database: database, clock: clock, calendar: utc)

        let task = try tasks.create(inProject: ids.0, statusID: ids.1, title: "Not now")
        try tasks.setDueDate(day("2026-01-15"), for: task.id)
        try membership.addAssignee(personID, to: task.id)

        try personal.snooze(task.id, until: day("2026-01-17"))
        var work = try personal.myWork(for: personID)
        #expect(work.today.isEmpty)
        #expect(work.snoozed.map(\.title) == ["Not now"])
        #expect(try tasks.task(id: task.id).dueDate == day("2026-01-15"))

        // It comes back on its own, without anything being run.
        clock.now = day("2026-01-18")
        work = try personal.myWork(for: personID)
        #expect(work.overdue.map(\.title) == ["Not now"])
        #expect(work.snoozed.isEmpty)
    }

    @Test("Finished work is in no section")
    func doneWorkDisappears() throws {
        let (database, clock, personID, ids) = try seed()
        let tasks = TaskRepository(database: database, clock: clock)
        let membership = MembershipRepository(database: database, clock: clock)

        let task = try tasks.create(inProject: ids.0, statusID: ids.1, title: "Finished")
        try tasks.setDueDate(day("2026-01-15"), for: task.id)
        try membership.addAssignee(personID, to: task.id)
        try tasks.move(task.id, toStatus: ids.2)

        let work = try PersonalRepository(database: database, clock: clock, calendar: utc)
            .myWork(for: personID)
        #expect(work.count == 0)
    }

    /// The card's own `assignee_id` and the several-assignees table are both
    /// ways of being on a card, and my work has to read both.
    @Test("Work reaches me through either kind of assignment")
    func bothKindsOfAssignment() throws {
        let (database, clock, personID, ids) = try seed()
        let tasks = TaskRepository(database: database, clock: clock)

        let direct = try tasks.create(inProject: ids.0, statusID: ids.1, title: "Straight to me")
        try tasks.setAssignee(personID, for: direct.id)

        let shared = try tasks.create(inProject: ids.0, statusID: ids.1, title: "Shared with me")
        try MembershipRepository(database: database, clock: clock).addAssignee(personID, to: shared.id)

        let work = try PersonalRepository(database: database, clock: clock, calendar: utc)
            .myWork(for: personID)
        #expect(Set(work.unscheduled.map(\.title)) == ["Straight to me", "Shared with me"])
    }
}

@Suite("Reminders, which are not tasks")
struct ReminderTests {

    @Test("A reminder is made, finished and put back")
    func lifecycle() throws {
        let database = try Database.inMemoryMigrated()
        let clock = StoppedClock(day("2026-01-15"))
        let personal = PersonalRepository(database: database, clock: clock, calendar: utc)

        let reminder = try personal.createReminder(title: "Ring the dentist", dueAt: day("2026-01-16"))
        #expect(try personal.reminders().map(\.title) == ["Ring the dentist"])

        try personal.setReminderDone(true, for: reminder.id)
        #expect(try personal.reminders().isEmpty)
        #expect(try personal.reminders(includeDone: true).count == 1)

        try personal.setReminderDone(false, for: reminder.id)
        #expect(try personal.reminders().count == 1)
    }

    @Test("A reminder with no words is refused")
    func needsWords() throws {
        let database = try Database.inMemoryMigrated()
        #expect(throws: LocalBoardError.self) {
            try PersonalRepository(database: database).createReminder(title: "   ")
        }
    }

    @Test("Only reminders that are due, awake and unfinished ring")
    func ringing() throws {
        let database = try Database.inMemoryMigrated()
        let clock = StoppedClock(day("2026-01-15"))
        let personal = PersonalRepository(database: database, clock: clock, calendar: utc)

        let due = try personal.createReminder(title: "Due", dueAt: day("2026-01-14"))
        _ = try personal.createReminder(title: "Later", dueAt: day("2026-01-20"))
        _ = try personal.createReminder(title: "No date")

        #expect(try personal.dueReminders().map(\.title) == ["Due"])

        try personal.snoozeReminder(due.id, until: day("2026-01-16"))
        #expect(try personal.dueReminders().isEmpty)

        clock.now = day("2026-01-17")
        #expect(try personal.dueReminders().map(\.title) == ["Due"])
    }

    /// A thing that is done has nothing left to come back for.
    @Test("Finishing a reminder cancels its snooze")
    func finishingClearsSnooze() throws {
        let database = try Database.inMemoryMigrated()
        let clock = StoppedClock(day("2026-01-15"))
        let personal = PersonalRepository(database: database, clock: clock, calendar: utc)

        let reminder = try personal.createReminder(title: "Ring back", dueAt: day("2026-01-15"))
        try personal.snoozeReminder(reminder.id, until: day("2026-01-20"))
        try personal.setReminderDone(true, for: reminder.id)

        #expect(try personal.reminder(id: reminder.id).snoozedUntil == nil)
    }

    @Test("Snooze options land where they say")
    func snoozeOptions() {
        let now = utc.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 14, minute: 30))!

        #expect(SnoozeOption.laterToday.until(from: now, calendar: utc)
                == now.addingTimeInterval(3 * 60 * 60))

        let tomorrow = SnoozeOption.tomorrow.until(from: now, calendar: utc)
        #expect(utc.component(.day, from: tomorrow) == 16)
        #expect(utc.component(.hour, from: tomorrow) == 9)

        let week = SnoozeOption.nextWeek.until(from: now, calendar: utc)
        #expect(utc.component(.day, from: week) == 22)
    }
}

@Suite("The notepad")
struct NotepadTests {

    /// A scratch pad you have to create before writing in is not a scratch
    /// pad.
    @Test("The pad always exists")
    func alwaysThere() throws {
        let database = try Database.inMemoryMigrated()
        let personal = PersonalRepository(database: database)

        #expect(try personal.notepad().isEmpty)

        try personal.setNotepad("- [ ] think about it")
        #expect(try personal.notepad() == "- [ ] think about it")

        try personal.setNotepad("changed")
        #expect(try personal.notepad() == "changed")
    }
}

@Suite("Documents and what they mention")
struct DocTests {

    @Test("Pages nest, and deleting one takes its pages with it")
    func nesting() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let docs = DocRepository(database: database)

        let parent = try docs.create(title: "Handbook", inProject: ids.project)
        let child = try docs.create(title: "Onboarding", inProject: ids.project, parent: parent.id)
        _ = try docs.create(title: "Day one", inProject: ids.project, parent: child.id)

        #expect(try docs.children(of: parent.id).map(\.title) == ["Onboarding"])

        try docs.delete(parent.id)
        #expect(try docs.allDocs().isEmpty)
    }

    /// A ring in the tree would hang every walk of it.
    @Test("A page cannot be moved inside itself")
    func noRings() throws {
        let database = try Database.inMemoryMigrated()
        let docs = DocRepository(database: database)

        let parent = try docs.create(title: "Parent")
        let child = try docs.create(title: "Child", parent: parent.id)

        #expect(throws: LocalBoardError.self) { try docs.move(parent.id, under: child.id) }
        #expect(throws: LocalBoardError.self) { try docs.move(parent.id, under: parent.id) }
    }

    /// The backlinks come from what the document says, so the two cannot
    /// disagree.
    @Test("Mentioning a card links the document to it, and un-mentioning unlinks")
    func backlinks() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let docs = DocRepository(database: database)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "The work")
        let doc = try docs.create(title: "Plan", body: "We agreed @WORK-\(task.number) comes first.")

        #expect(try docs.linkedTasks(ofDoc: doc.id).map(\.id) == [task.id])
        #expect(try docs.backlinks(ofTask: task.id).map(\.title) == ["Plan"])

        try docs.save(doc.id, title: "Plan", body: "We changed our minds.")
        #expect(try docs.backlinks(ofTask: task.id).isEmpty)
    }

    /// Loosening the pattern would catch every email address in a document.
    @Test("A mention is a key and a number, not any at-sign")
    func mentionPattern() {
        #expect(DocRepository.mentionedKeys(in: "see @WORK-14 and @TASK-2.") == ["WORK-14", "TASK-2"])
        #expect(DocRepository.mentionedKeys(in: "email ada@example.com").isEmpty)
        #expect(DocRepository.mentionedKeys(in: "ask @ada about it").isEmpty)
    }

    @Test("A mention of a card that does not exist links to nothing")
    func unknownMention() throws {
        let database = try Database.inMemoryMigrated()
        try database.seedBoardProject()
        let docs = DocRepository(database: database)

        let doc = try docs.create(title: "Plan", body: "@WORK-999 will save us")
        #expect(try docs.linkedTasks(ofDoc: doc.id).isEmpty)
    }
}

@Suite("Whiteboards")
struct WhiteboardTests {

    @Test("Things go on a board and come off it")
    func items() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let boards = WhiteboardRepository(database: database)

        let board = try boards.create(named: "Kickoff", inProject: ids.project)
        let sticky = try boards.add(WhiteboardItem(
            id: UUID().uuidString, boardID: board.id, kind: .sticky,
            x: 10, y: 20, text: "An idea", sortOrder: 1000, createdAt: .now
        ))

        #expect(try boards.items(onBoard: board.id).count == 1)

        try boards.move(sticky.id, to: 50, 60)
        #expect(try boards.item(id: sticky.id).x == 50)

        try boards.delete(item: sticky.id)
        #expect(try boards.items(onBoard: board.id).isEmpty)
    }

    /// Nothing written on the canvas is lost in the move: the first line is
    /// the title and the rest becomes the card's notes.
    @Test("A sticky becomes a card, keeping everything it said")
    func stickyToCard() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let boards = WhiteboardRepository(database: database)

        let board = try boards.create(named: "Kickoff", inProject: ids.project)
        let sticky = try boards.add(WhiteboardItem(
            id: UUID().uuidString, boardID: board.id, kind: .sticky,
            text: "Rewrite the parser\nit keeps choking on quotes",
            sortOrder: 1000, createdAt: .now
        ))

        let task = try boards.convertToTask(sticky.id, inProject: ids.project, statusID: ids.toDo)
        #expect(task.title == "Rewrite the parser")
        #expect(task.descriptionMarkdown == "it keeps choking on quotes")

        // And it remembers, so the canvas offers to open it rather than to
        // make a second one.
        #expect(try boards.item(id: sticky.id).taskID == task.id)
        let again = try boards.convertToTask(sticky.id, inProject: ids.project, statusID: ids.toDo)
        #expect(again.id == task.id)
    }

    @Test("An empty sticky has nothing to make a card out of")
    func emptySticky() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let boards = WhiteboardRepository(database: database)

        let board = try boards.create(named: "Kickoff", inProject: ids.project)
        let sticky = try boards.add(WhiteboardItem(
            id: UUID().uuidString, boardID: board.id, kind: .sticky, sortOrder: 1000, createdAt: .now
        ))

        #expect(throws: LocalBoardError.self) {
            try boards.convertToTask(sticky.id, inProject: ids.project, statusID: ids.toDo)
        }
    }

    @Test("A stroke survives being written down and read back")
    func strokes() throws {
        let database = try Database.inMemoryMigrated()
        let boards = WhiteboardRepository(database: database)
        let board = try boards.create(named: "Sketch", inProject: nil)

        let stroke = try boards.add(WhiteboardItem(
            id: UUID().uuidString, boardID: board.id, kind: .ink,
            strokeValues: [0, 0, 10, 12, 20, 8], sortOrder: 1000, createdAt: .now
        ))

        let read = try boards.item(id: stroke.id)
        #expect(read.strokeValues == [0, 0, 10, 12, 20, 8])
        #expect(read.points.count == 3)
    }
}

@Suite("Comments that ask for something")
struct ActionItemTests {

    @Test("A remark becomes a request and keeps its words")
    func actionItems() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let people = PersonRepository(database: database)
        let details = CardDetailRepository(database: database)

        let ada = try people.create(name: "Ada")
        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "The work")
        let comment = try details.addComment(
            toTask: task.id, body: "Could somebody check the migration?", authorID: nil
        )

        try details.setActionItem(true, assignee: ada.id, for: comment.id)
        let asked = try #require(try details.comments(forTask: task.id).first)
        #expect(asked.isActionItem)
        #expect(asked.actionAssigneeID == ada.id)
        #expect(asked.bodyMarkdown == "Could somebody check the migration?")

        #expect(try details.actionItems(for: ada.id).count == 1)

        try details.setActionDone(true, for: comment.id)
        #expect(try details.actionItems(for: ada.id).isEmpty)
        #expect(try details.openActionItems(inProject: ids.project).isEmpty)
    }

    /// Deleting what somebody wrote because it stopped being a task would be
    /// startling.
    @Test("Un-asking leaves the remark in the thread")
    func unaskingKeepsTheComment() throws {
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let tasks = TaskRepository(database: database)
        let details = CardDetailRepository(database: database)

        let task = try tasks.create(inProject: ids.project, statusID: ids.toDo, title: "The work")
        let comment = try details.addComment(toTask: task.id, body: "Just a thought", authorID: nil)

        try details.setActionItem(true, assignee: nil, for: comment.id)
        try details.setActionItem(false, assignee: nil, for: comment.id)

        let remark = try #require(try details.comments(forTask: task.id).first)
        #expect(remark.isActionItem == false)
        #expect(remark.bodyMarkdown == "Just a thought")
    }
}
