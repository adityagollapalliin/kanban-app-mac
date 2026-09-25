import Foundation
import LocalBoardCore
import LocalBoardStore

/// The day in front of you, the things written beside the work, and the
/// panels you have set aside.
@MainActor
extension BoardViewModel {

    // MARK: - My work

    public func myWork(now: Date = .now) -> PersonalRepository.MyWork {
        (try? personalRepository.myWork(for: currentPersonID, now: now)) ?? .init()
    }

    /// Whether the day's list is one person's or everybody's. Shown on screen
    /// rather than assumed, because "my work" with nobody set as me is a
    /// different list and saying so is cheaper than being wrong about it.
    public var knowsWhoIAm: Bool { currentPersonID != nil }

    public func planForToday(_ taskID: String) {
        editing([taskID], "Plan for Today") {
            try personalRepository.planForToday(taskID)
        }
    }

    public func unplan(_ taskID: String) {
        editing([taskID], "Take Off Today") {
            try personalRepository.unplan(taskID)
        }
    }

    public func candidatesForToday() -> [BoardTask] {
        (try? personalRepository.candidatesForToday(personID: currentPersonID)) ?? []
    }

    /// Dragging work between the sections of a day reschedules it. Overdue
    /// takes no drops — you cannot decide to have been late — and the view
    /// simply does not offer it as a target.
    public func reschedule(_ taskID: String, into section: WorkSection) {
        guard let due = WorkPlanner.dueDate(forDropInto: section, now: .now) else { return }
        editing([taskID], "Reschedule") {
            try taskRepository.setDueDate(due, for: taskID)
            if section != .today { try personalRepository.unplan(taskID) }
        }
    }

    // MARK: - Snoozing

    public func snooze(_ taskID: String, _ option: SnoozeOption) {
        snooze(taskID, until: option.until(from: .now))
    }

    public func snooze(_ taskID: String, until: Date) {
        editing([taskID], "Snooze") {
            try personalRepository.snooze(taskID, until: until)
        }
    }

    public func wake(_ taskID: String) {
        editing([taskID], "Wake") {
            try personalRepository.wake(taskID)
        }
    }

    // MARK: - Reminders

    public func loadReminders() {
        perform { reminders = try personalRepository.reminders(includeDone: true) }
    }

    public func addReminder(_ text: String) {
        // The same parser as quick-add: "ring the dentist tomorrow 3pm" is a
        // sentence somebody types once, and it should mean the same thing
        // wherever they type it.
        let parsed = QuickAddParser.parse(text)
        perform {
            try personalRepository.createReminder(title: parsed.title, dueAt: parsed.dueDate)
            loadReminders()
        }
    }

    public func setReminderDone(_ done: Bool, for id: String) {
        perform {
            try personalRepository.setReminderDone(done, for: id)
            loadReminders()
        }
    }

    public func snoozeReminder(_ id: String, _ option: SnoozeOption) {
        perform {
            try personalRepository.snoozeReminder(id, until: option.until(from: .now))
            loadReminders()
        }
    }

    public func updateReminder(_ id: String, title: String, notes: String, dueAt: Date?) {
        perform {
            try personalRepository.updateReminder(id, title: title, notes: notes, dueAt: dueAt)
            loadReminders()
        }
    }

    public func deleteReminder(_ id: String) {
        perform {
            try personalRepository.deleteReminder(id)
            loadReminders()
        }
    }

    public func dueReminders(now: Date = .now) -> [Reminder] {
        (try? personalRepository.dueReminders(now: now)) ?? []
    }

    // MARK: - The notepad

    public func loadNotepad() {
        perform { notepad = try personalRepository.notepad() }
    }

    public func saveNotepad(_ body: String) {
        notepad = body
        perform { try personalRepository.setNotepad(body) }
    }

    /// Turns one line of the pad into a card, and ticks it off in the pad so
    /// the same line cannot quietly become two cards.
    public func makeCard(fromNotepadLine line: String) {
        let text = line
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "- [ ] ", with: "")
            .replacingOccurrences(of: "- ", with: "")
        guard !text.isEmpty, let status = visibleColumns.first?.status.id else { return }

        quickAdd(text, toStatus: status)

        let replaced = notepad.replacingOccurrences(of: line, with: "- [x] \(text)")
        saveNotepad(replaced)
    }

    // MARK: - Quick add, in a sentence

    /// Creates a card from one typed line, understanding what it can of it.
    ///
    /// Everything the parser recognises is applied; a name or tag that matches
    /// nothing is ignored rather than invented, because a card quietly
    /// assigned to a person who does not exist is worse than one not assigned.
    @discardableResult
    public func quickAdd(_ text: String, toStatus statusID: String, atTop: Bool = false) -> String? {
        let parsed = QuickAddParser.parse(text)
        guard !parsed.title.isEmpty else { return nil }

        var created: String?
        perform {
            let task = try taskRepository.create(
                inProject: try projectID(), statusID: statusID, title: parsed.title,
                priority: parsed.priority ?? .normal,
                dueDate: parsed.dueDate,
                listID: selectedListID
            )
            created = task.id

            for name in parsed.assignees {
                guard let person = people.first(where: {
                    $0.name.lowercased().hasPrefix(name.lowercased())
                }) else { continue }
                try membershipRepository.addAssignee(person.id, to: task.id)
            }

            for name in parsed.labels {
                guard let label = labels.first(where: {
                    $0.name.lowercased() == name.lowercased()
                }) else { continue }
                try labelRepository.setLabel(label.id, on: task.id, attached: true)
            }

            if atTop { try taskRepository.move(task.id, toStatus: statusID, before: nil) }
            reloadSnapshot()
        }
        return created
    }

    private func projectID() throws -> String {
        guard let currentProjectID else {
            throw LocalBoardError.notFound(entity: "a project to add this to")
        }
        return currentProjectID
    }

    /// What quick-add would do with this text, for the line of hints shown
    /// under the field while it is being typed.
    public func preview(_ text: String) -> QuickAddResult {
        QuickAddParser.parse(text)
    }

    // MARK: - The tray

    /// Sets a card aside rather than closing it. The tray is how several
    /// cards stay to hand at once without a window each.
    public func addToTray(_ taskID: String) {
        guard !trayTaskIDs.contains(taskID) else { return }
        trayTaskIDs.append(taskID)
        if selectedTaskID == taskID { selectedTaskID = nil }
    }

    public func removeFromTray(_ taskID: String) {
        trayTaskIDs.removeAll { $0 == taskID }
    }

    /// Bringing one back out of the tray opens it and takes it off the shelf:
    /// a card cannot be both set aside and open.
    public func restoreFromTray(_ taskID: String) {
        removeFromTray(taskID)
        selectedTaskID = taskID
    }

    public func clearTray() {
        trayTaskIDs.removeAll()
    }

    // MARK: - Action items

    public func setActionItem(_ isAction: Bool, assignee personID: String?, for commentID: String) {
        perform {
            try cardDetailRepository.setActionItem(isAction, assignee: personID, for: commentID)
            loadSelectionDetails()
        }
    }

    public func setActionDone(_ done: Bool, for commentID: String) {
        perform {
            try cardDetailRepository.setActionDone(done, for: commentID)
            loadSelectionDetails()
        }
    }

    public func loadMyActionItems() {
        guard let currentPersonID else {
            myActionItems = []
            return
        }
        perform { myActionItems = try cardDetailRepository.actionItems(for: currentPersonID) }
    }

    // MARK: - Documents

    public func docs() -> [Doc] {
        (try? docRepository.allDocs()) ?? []
    }

    public func childDocs(of parentID: String?) -> [Doc] {
        (try? docRepository.children(of: parentID)) ?? []
    }

    @discardableResult
    public func createDoc(titled title: String, parent parentID: String? = nil) -> Doc? {
        var made: Doc?
        perform {
            made = try docRepository.create(
                title: title, inProject: parentID == nil ? currentProjectID : nil, parent: parentID
            )
        }
        return made
    }

    public func saveDoc(_ docID: String, title: String, body: String) {
        perform { try docRepository.save(docID, title: title, body: body) }
    }

    public func deleteDoc(_ docID: String) {
        perform { try docRepository.delete(docID) }
    }

    public func moveDoc(_ docID: String, under parentID: String?) {
        perform { try docRepository.move(docID, under: parentID) }
    }

    public func linkedTasks(ofDoc docID: String) -> [BoardTask] {
        (try? docRepository.linkedTasks(ofDoc: docID)) ?? []
    }

    public func loadBacklinks(forTask taskID: String) {
        perform { backlinks = try docRepository.backlinks(ofTask: taskID) }
    }

    /// Makes a card out of selected text in a document, and leaves a mention
    /// of it behind — so the document still says what was decided, and now
    /// says where it went.
    public func makeCard(fromDocText text: String, in docID: String, body: String, title docTitle: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let status = visibleColumns.first?.status.id else { return }
        guard let taskID = quickAdd(trimmed, toStatus: status), let task = task(id: taskID) else { return }

        let mention = "\(trimmed) (@\(tag(for: task)))"
        saveDoc(docID, title: docTitle, body: body.replacingOccurrences(of: trimmed, with: mention))
    }

    // MARK: - Whiteboards

    public func whiteboards() -> [Whiteboard] {
        (try? whiteboardRepository.boards(inProject: currentProjectID)) ?? []
    }

    @discardableResult
    public func createWhiteboard(named name: String) -> Whiteboard? {
        var made: Whiteboard?
        perform { made = try whiteboardRepository.create(named: name, inProject: currentProjectID) }
        return made
    }

    public func deleteWhiteboard(_ boardID: String) {
        perform { try whiteboardRepository.delete(boardID) }
    }

    public func items(onWhiteboard boardID: String) -> [WhiteboardItem] {
        (try? whiteboardRepository.items(onBoard: boardID)) ?? []
    }

    public func add(_ item: WhiteboardItem) {
        perform { try whiteboardRepository.add(item) }
    }

    public func moveItem(_ itemID: String, to x: Double, _ y: Double) {
        perform { try whiteboardRepository.move(itemID, to: x, y) }
    }

    public func setItemText(_ text: String, for itemID: String) {
        perform { try whiteboardRepository.setText(text, for: itemID) }
    }

    public func setItemColor(_ color: String, for itemID: String) {
        perform { try whiteboardRepository.setColor(color, for: itemID) }
    }

    public func deleteItem(_ itemID: String) {
        perform { try whiteboardRepository.delete(item: itemID) }
    }

    public func resizeItem(_ itemID: String, width: Double, height: Double) {
        perform { try whiteboardRepository.resize(itemID, width: width, height: height) }
    }

    /// A sticky becomes a card in the first column of the space the board
    /// belongs to.
    public func convertStickyToTask(_ itemID: String) {
        guard let projectID = currentProjectID, let status = visibleColumns.first?.status.id else { return }
        perform {
            try whiteboardRepository.convertToTask(
                itemID, inProject: projectID, statusID: status, listID: selectedListID
            )
            reloadSnapshot()
        }
    }
}
