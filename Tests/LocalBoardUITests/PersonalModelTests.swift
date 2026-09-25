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
@Suite("Typing a card in one line, on a live board")
struct QuickAddModelTests {

    @Test("A sentence becomes a card with its date, priority and people")
    func fullSentence() throws {
        let model = try board()
        model.createPerson(named: "Ada Lovelace")
        model.createLabel(named: "backend")
        let status = try #require(model.visibleColumns.first?.status.id)

        model.quickAdd("Fix login bug tomorrow !high #backend @Ada", toStatus: status)

        let card = try #require(model.visibleTasks.first { $0.title == "Fix login bug" })
        #expect(card.priority == .high)
        #expect(card.dueDate != nil)
        #expect(model.people(on: card).map(\.name) == ["Ada Lovelace"])
        #expect(model.labels(for: card).map(\.name) == ["backend"])
    }

    /// A card quietly assigned to a person who does not exist is worse than
    /// one not assigned at all.
    @Test("A name that matches nobody is left off rather than invented")
    func unknownNamesAreIgnored() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)

        model.quickAdd("Write it up @Nobody #nothing", toStatus: status)

        let card = try #require(model.visibleTasks.first { $0.title == "Write it up" })
        #expect(model.people(on: card).isEmpty)
        #expect(model.labels(for: card).isEmpty)
        #expect(model.people.isEmpty)
    }

    @Test("A plain line still makes a card")
    func plainLine() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)

        model.quickAdd("Just a card", toStatus: status)
        #expect(model.visibleTasks.contains { $0.title == "Just a card" })
    }
}

@MainActor
@Suite("My work, on a live board")
struct MyWorkModelTests {

    @Test("Sections fill from the board, and planning moves nothing but the plan")
    func sectionsAndPlanning() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Someday", toStatus: status)
        let card = try #require(model.visibleTasks.first { $0.title == "Someday" })

        #expect(model.myWork().unscheduled.contains { $0.id == card.id })

        model.planForToday(card.id)
        #expect(model.myWork().today.map(\.id) == [card.id])
        #expect(model.task(id: card.id)?.dueDate == nil)

        model.unplan(card.id)
        #expect(model.myWork().unscheduled.contains { $0.id == card.id })
    }

    /// The date is a promise to other people; a snooze is five minutes'
    /// peace.
    @Test("Snoozing takes something out of the day without moving its date")
    func snoozing() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Not now", toStatus: status)
        let card = try #require(model.visibleTasks.first)
        model.setDueDate(.now, for: card.id)

        model.snooze(card.id, .tomorrow)
        let work = model.myWork()
        #expect(work.today.isEmpty)
        #expect(work.snoozed.map(\.id) == [card.id])
        #expect(model.task(id: card.id)?.dueDate != nil)

        model.wake(card.id)
        #expect(model.myWork().snoozed.isEmpty)
    }

    /// Dragging between sections reschedules; Overdue is not a place you can
    /// drop something, because you cannot decide to have been late.
    @Test("Dropping into a section reschedules, except into Overdue")
    func rescheduling() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Movable", toStatus: status)
        let card = try #require(model.visibleTasks.first)

        model.reschedule(card.id, into: .today)
        #expect(model.myWork().today.map(\.id) == [card.id])

        model.reschedule(card.id, into: .unscheduled)
        #expect(model.task(id: card.id)?.dueDate == nil)

        // Overdue changes nothing at all.
        model.reschedule(card.id, into: .overdue)
        #expect(model.task(id: card.id)?.dueDate == nil)
    }
}

@MainActor
@Suite("Reminders, the notepad and the tray")
struct PersonalModelTests {

    @Test("A reminder can be typed as a sentence")
    func remindersParseToo() throws {
        let model = try board()
        model.addReminder("Ring the dentist tomorrow 3pm")

        let reminder = try #require(model.reminders.first)
        #expect(reminder.title == "Ring the dentist")
        #expect(reminder.dueAt != nil)

        model.setReminderDone(true, for: reminder.id)
        #expect(model.reminders.first?.isDone == true)
    }

    /// A line becomes a card and is ticked off in the pad, so the same line
    /// cannot quietly become two cards.
    @Test("A notepad line becomes a card and is ticked off")
    func notepadLines() throws {
        let model = try board()
        model.saveNotepad("- [ ] think about the parser\nsome prose")

        model.makeCard(fromNotepadLine: "- [ ] think about the parser")

        #expect(model.visibleTasks.contains { $0.title == "think about the parser" })
        #expect(model.notepad.contains("- [x] think about the parser"))
    }

    @Test("A card set aside can be brought back")
    func theTray() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Set aside", toStatus: status)
        let card = try #require(model.visibleTasks.first)

        model.selectedTaskID = card.id
        model.addToTray(card.id)

        #expect(model.trayTaskIDs == [card.id])
        // A card cannot be both open and set aside.
        #expect(model.selectedTaskID == nil)

        model.restoreFromTray(card.id)
        #expect(model.trayTaskIDs.isEmpty)
        #expect(model.selectedTaskID == card.id)
    }

    @Test("Setting the same card aside twice keeps one of it")
    func trayIsASet() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "Once", toStatus: status)
        let card = try #require(model.visibleTasks.first)

        model.addToTray(card.id)
        model.addToTray(card.id)
        #expect(model.trayTaskIDs.count == 1)
    }
}

@MainActor
@Suite("Documents on a live board")
struct DocModelTests {

    @Test("A page mentioning a card shows up on that card")
    func backlinks() throws {
        let model = try board()
        let status = try #require(model.visibleColumns.first?.status.id)
        model.addTask(title: "The work", toStatus: status)
        let card = try #require(model.visibleTasks.first)

        let doc = try #require(model.createDoc(titled: "Plan"))
        model.saveDoc(doc.id, title: "Plan", body: "We agreed @\(model.tag(for: card)) comes first.")

        #expect(model.linkedTasks(ofDoc: doc.id).map(\.id) == [card.id])

        model.loadBacklinks(forTask: card.id)
        #expect(model.backlinks.map(\.title) == ["Plan"])
    }

    /// The page still says what was decided, and now says where it went.
    @Test("Turning a sentence into a card leaves a mention behind")
    func textToCard() throws {
        let model = try board()
        let doc = try #require(model.createDoc(titled: "Notes"))
        let body = "We should rewrite the parser before the release."
        model.saveDoc(doc.id, title: "Notes", body: body)

        model.makeCard(fromDocText: "rewrite the parser", in: doc.id, body: body, title: "Notes")

        #expect(model.visibleTasks.contains { $0.title == "rewrite the parser" })
        let updated = try #require(model.docs().first { $0.id == doc.id })
        #expect(updated.bodyMarkdown.contains("(@"))
        #expect(model.linkedTasks(ofDoc: doc.id).count == 1)
    }
}

@MainActor
@Suite("Whiteboards on a live board")
struct WhiteboardModelTests {

    @Test("A sticky becomes a card and says so afterwards")
    func stickyToCard() throws {
        let model = try board()
        let whiteboard = try #require(model.createWhiteboard(named: "Kickoff"))

        let sticky = WhiteboardItem(
            id: UUID().uuidString, boardID: whiteboard.id, kind: .sticky,
            text: "Rewrite the parser", sortOrder: 1000, createdAt: .now
        )
        model.add(sticky)
        model.convertStickyToTask(sticky.id)

        #expect(model.visibleTasks.contains { $0.title == "Rewrite the parser" })
        #expect(model.items(onWhiteboard: whiteboard.id).first?.taskID != nil)
    }

    @Test("Things move and are removed")
    func items() throws {
        let model = try board()
        let whiteboard = try #require(model.createWhiteboard(named: "Sketch"))

        let item = WhiteboardItem(
            id: UUID().uuidString, boardID: whiteboard.id, kind: .shape,
            x: 10, y: 10, sortOrder: 1000, createdAt: .now
        )
        model.add(item)
        model.moveItem(item.id, to: 100, 200)
        #expect(model.items(onWhiteboard: whiteboard.id).first?.x == 100)

        model.deleteItem(item.id)
        #expect(model.items(onWhiteboard: whiteboard.id).isEmpty)
    }
}
