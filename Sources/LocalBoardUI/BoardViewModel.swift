import Foundation
import Observation
import LocalBoardCore
import LocalBoardStore

/// The board's state, and the only place a view touches the database.
///
/// Reads are synchronous and run on the main actor. That is a deliberate choice
/// for a local SQLite file rather than an oversight: a board query is indexed,
/// returns at most a few thousand rows, and completes well inside a frame. The
/// day that stops being true, this is the one type that has to change.
@MainActor
@Observable
public final class BoardViewModel {

    public private(set) var workspaces: [Workspace] = []
    public private(set) var projects: [Project] = []
    public private(set) var boards: [Board] = []
    public private(set) var snapshot: BoardSnapshot?

    /// What went wrong with the last action. Shown, then dismissed by the next
    /// successful one — an error the user cannot clear is an error they learn
    /// to ignore.
    public private(set) var failure: LocalBoardError?

    public var selectedBoardID: String? {
        didSet {
            guard selectedBoardID != oldValue else { return }
            reloadSnapshot()
        }
    }

    /// What is typed in the search field. Empty means no filter at all,
    /// which is not the same as a filter that matches everything — an empty
    /// board and an unfiltered board should not look alike.
    public var queryText: String = "" {
        didSet {
            guard queryText != oldValue else { return }
            applyQuery()
        }
    }

    /// A query that does not parse yet. Held apart from `failure`: half a
    /// query is a normal state of a search field being typed into, not a
    /// failed action, and it must not raise the same alarm.
    public private(set) var queryFailure: String?

    /// Whether the board is currently reading trashed cards at all. Only true
    /// while the query asks about them.
    private var showsTrash = false

    /// `nil` when nothing is being filtered.
    private var matchingTaskIDs: Set<String>?

    /// The columns to draw: every card, or only those the query matched.
    public var visibleColumns: [LoadedColumn] {
        guard let snapshot else { return [] }
        guard let matchingTaskIDs else { return snapshot.columns }

        return snapshot.columns.map { column in
            LoadedColumn(
                column: column.column,
                status: column.status,
                tasks: column.tasks.filter { matchingTaskIDs.contains($0.id) }
            )
        }
    }

    public var isFiltering: Bool { matchingTaskIDs != nil }

    /// How many cards the query hid, for the "showing 3 of 12" line.
    public var totalTaskCount: Int { snapshot?.taskCount ?? 0 }

    public var visibleTaskCount: Int { visibleColumns.reduce(0) { $0 + $1.tasks.count } }

    /// The card open in the inspector. Cleared when the card leaves the board,
    /// so closing is never something the user has to do after a trash.
    public var selectedTaskID: String? {
        didSet {
            guard selectedTaskID != oldValue else { return }
            loadSelectionDetails()
        }
    }

    /// The open card's checklist and subtasks. Loaded when the selection
    /// changes rather than for every card on the board, because only one card
    /// is ever open.
    public private(set) var checklist: [ChecklistItem] = []
    public private(set) var subtasks: [BoardTask] = []

    /// Project-wide lists the inspector offers.
    public private(set) var labels: [CardLabel] = []
    public private(set) var epics: [BoardTask] = []

    /// Clicking a card opens it; clicking the open one closes it again. The
    /// card is the control, so it has to work in both directions — an
    /// inspector you can only open from here and must close somewhere else is
    /// a one-way door.
    public func toggleSelection(of taskID: String) {
        selectedTaskID = selectedTaskID == taskID ? nil : taskID
    }

    public var selectedTask: BoardTask? {
        guard let selectedTaskID else { return nil }
        return snapshot?.columns.lazy.flatMap(\.tasks).first { $0.id == selectedTaskID }
    }

    /// The statuses this board shows, in column order — what the inspector's
    /// status picker offers.
    public var statuses: [Status] {
        snapshot?.columns.map(\.status) ?? []
    }

    public private(set) var people: [Person] = []
    public private(set) var savedViews: [SavedView] = []

    private let database: Database
    private let boardRepository: BoardRepository
    private let taskRepository: TaskRepository
    private let personRepository: PersonRepository
    private let savedViewRepository: SavedViewRepository
    private let labelRepository: LabelRepository
    private let checklistRepository: ChecklistRepository

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.boardRepository = BoardRepository(database: database, clock: clock)
        self.taskRepository = TaskRepository(database: database, clock: clock)
        self.personRepository = PersonRepository(database: database, clock: clock)
        self.savedViewRepository = SavedViewRepository(database: database, clock: clock)
        self.labelRepository = LabelRepository(database: database)
        self.checklistRepository = ChecklistRepository(database: database, clock: clock)
    }

    // MARK: - Loading

    /// Called once when the board appears, and again whenever another process
    /// commits a change.
    public func load() {
        perform {
            // Idempotent: on an existing file this only finds the first board.
            let starter = try boardRepository.ensureStarterContent()
            workspaces = try boardRepository.workspaces()

            projects = try workspaces.flatMap { try boardRepository.projects(inWorkspace: $0.id) }
            boards = try projects.flatMap { try boardRepository.boards(inProject: $0.id) }

            // Keep the user where they were across a reload; fall back to the
            // starter board, then to whatever exists.
            if let current = selectedBoardID, boards.contains(where: { $0.id == current }) {
                reloadSnapshot()
            } else {
                selectedBoardID = starter?.id ?? boards.first?.id
            }
        }
    }

    private func reloadSnapshot() {
        loadSnapshot()
        applyQuery()
    }

    /// Reads the board without touching the query, so that `applyQuery` can
    /// ask for a reload without the two calling each other forever.
    private func loadSnapshot() {
        guard let selectedBoardID else {
            snapshot = nil
            return
        }
        perform {
            snapshot = try boardRepository.snapshot(boardID: selectedBoardID, includeTrashed: showsTrash)
            people = try personRepository.people()
            if let projectID = snapshot?.board.projectID {
                savedViews = try savedViewRepository.views(inProject: projectID)
                labels = try labelRepository.labels(inProject: projectID)
                epics = try taskRepository.epics(inProject: projectID)
            }
        }
        loadSelectionDetails()
    }

    private func loadSelectionDetails() {
        guard let selectedTaskID else {
            checklist = []
            subtasks = []
            return
        }
        perform {
            checklist = try checklistRepository.items(forTask: selectedTaskID)
            subtasks = try taskRepository.subtasks(of: selectedTaskID)
        }
    }

    /// Runs the current query against the store and remembers which cards it
    /// matched. Called on every edit to the field and after every reload.
    private func applyQuery() {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            matchingTaskIDs = nil
            queryFailure = nil
            setShowsTrash(false)
            return
        }

        guard let projectID = snapshot?.board.projectID else { return }

        do {
            // The board hides trashed cards, so a query about them has to
            // change what was read, not just what is shown — otherwise
            // `is:trashed` filters a set the trash was never in.
            setShowsTrash(try TaskQueryParser.parse(trimmed).mentionsTrash)

            let matches = try taskRepository.tasks(matching: trimmed, inProject: projectID)
            matchingTaskIDs = Set(matches.map(\.id))
            queryFailure = nil
        } catch let error as QueryError {
            // Keep showing the last good result while the query is being
            // finished, rather than blanking the board on every keystroke.
            queryFailure = error.message
        } catch {
            queryFailure = error.localizedDescription
        }
    }

    public func project(for board: Board) -> Project? {
        projects.first { $0.id == board.projectID }
    }

    /// The prefix shown on every card: WORK-14.
    public func tag(for task: BoardTask) -> String {
        let key = projects.first { $0.id == task.projectID }?.key ?? "TASK"
        return "\(key)-\(task.number)"
    }

    // MARK: - Acting

    public func addTask(title: String, toStatus statusID: String) {
        guard let projectID = snapshot?.columns.first?.status.projectID else { return }
        perform {
            try taskRepository.create(inProject: projectID, statusID: statusID, title: title)
            reloadSnapshot()
        }
    }

    /// Drops a card into a column, either above a specific card or at the end.
    public func move(_ taskID: String, toStatus statusID: String, before: String? = nil) {
        // Dropping a card onto itself is a no-op, not a move to nowhere.
        guard taskID != before else { return }

        perform {
            let after = try neighbourAbove(before: before, inStatus: statusID, moving: taskID)
            try taskRepository.move(taskID, toStatus: statusID, after: after, before: before)
            reloadSnapshot()
        }
    }

    /// The card a drop should land after: the one above `before` in the
    /// destination column, skipping the card being moved.
    private func neighbourAbove(before: String?, inStatus statusID: String, moving taskID: String) throws -> String? {
        let column = try taskRepository.tasks(
            inProject: snapshot?.board.projectID ?? "",
            statusID: statusID
        ).filter { $0.id != taskID }

        guard let before else { return column.last?.id }
        guard let index = column.firstIndex(where: { $0.id == before }), index > 0 else { return nil }
        return column[index - 1].id
    }

    public func setTrashed(_ trashed: Bool, for taskID: String) {
        perform {
            try taskRepository.setTrashed(trashed, for: taskID)
            if trashed, selectedTaskID == taskID { selectedTaskID = nil }
            reloadSnapshot()
        }
    }

    private func setShowsTrash(_ shows: Bool) {
        guard shows != showsTrash else { return }
        showsTrash = shows
        loadSnapshot()
    }

    /// Takes a card back out of the trash. The counterpart to `setTrashed`,
    /// without which trashing is a one-way door.
    public func restore(_ taskID: String) {
        setTrashed(false, for: taskID)
    }

    public func rename(_ taskID: String, to title: String) {
        perform {
            try taskRepository.setTitle(title, for: taskID)
            reloadSnapshot()
        }
    }

    public func setDescription(_ markdown: String, for taskID: String) {
        perform {
            try taskRepository.setDescription(markdown, for: taskID)
            reloadSnapshot()
        }
    }

    public func setType(_ type: TaskType, for taskID: String) {
        perform {
            try taskRepository.setType(type, for: taskID)
            reloadSnapshot()
        }
    }

    public func setPriority(_ priority: Priority, for taskID: String) {
        perform {
            try taskRepository.setPriority(priority, for: taskID)
            reloadSnapshot()
        }
    }

    public func setDueDate(_ due: Date?, for taskID: String) {
        perform {
            try taskRepository.setDueDate(due, for: taskID)
            reloadSnapshot()
        }
    }

    /// Sends a card to the end of another column — the inspector's equivalent
    /// of dragging it there.
    public func moveToEnd(of statusID: String, taskID: String) {
        move(taskID, toStatus: statusID, before: nil)
    }

    // MARK: - People

    public func createPerson(named name: String) {
        perform {
            try personRepository.create(name: name)
            people = try personRepository.people()
        }
    }

    public func renamePerson(_ personID: String, to name: String) {
        perform {
            try personRepository.rename(personID, to: name)
            people = try personRepository.people()
        }
    }

    /// Their cards stay; they simply become unassigned.
    public func deletePerson(_ personID: String) {
        perform {
            try personRepository.delete(personID)
            people = try personRepository.people()
            reloadSnapshot()
        }
    }

    public func setAssignee(_ personID: String?, for taskID: String) {
        perform {
            try taskRepository.setAssignee(personID, for: taskID)
            reloadSnapshot()
        }
    }

    public func person(id: String?) -> Person? {
        guard let id else { return nil }
        return people.first { $0.id == id }
    }

    // MARK: - Saved views

    /// Whether what is in the search field is worth keeping: something is
    /// typed, and it parses.
    public var canSaveCurrentQuery: Bool {
        !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && queryFailure == nil
    }

    public func saveCurrentQuery(named name: String) {
        guard let projectID = snapshot?.board.projectID else { return }
        perform {
            try savedViewRepository.create(inProject: projectID, name: name, query: queryText)
            savedViews = try savedViewRepository.views(inProject: projectID)
        }
    }

    /// Opening a view puts its question back in the search field, so it can be
    /// read and adjusted rather than being an opaque filter.
    public func apply(_ view: SavedView) {
        queryText = view.query
    }

    public func deleteSavedView(_ viewID: String) {
        perform {
            try savedViewRepository.delete(viewID)
            if let projectID = snapshot?.board.projectID {
                savedViews = try savedViewRepository.views(inProject: projectID)
            }
        }
    }

    public func renameSavedView(_ viewID: String, to name: String) {
        perform {
            try savedViewRepository.rename(viewID, to: name)
            if let projectID = snapshot?.board.projectID {
                savedViews = try savedViewRepository.views(inProject: projectID)
            }
        }
    }

    // MARK: - What a card carries

    public func labels(for task: BoardTask) -> [CardLabel] {
        snapshot?.labels[task.id] ?? []
    }

    public func checklistProgress(for task: BoardTask) -> ChecklistProgress? {
        snapshot?.checklists[task.id]
    }

    public func subtaskProgress(for task: BoardTask) -> ChecklistProgress? {
        snapshot?.subtasks[task.id]
    }

    public func epic(for task: BoardTask) -> BoardTask? {
        guard let epicID = task.epicID else { return nil }
        return epics.first { $0.id == epicID }
    }

    // MARK: - Labels

    public func createLabel(named name: String, color: String = "slate") {
        guard let projectID = snapshot?.board.projectID else { return }
        perform {
            try labelRepository.create(inProject: projectID, name: name, color: color)
            labels = try labelRepository.labels(inProject: projectID)
        }
    }

    public func setLabel(_ labelID: String, on taskID: String, attached: Bool) {
        perform {
            try labelRepository.setLabel(labelID, on: taskID, attached: attached)
            reloadSnapshot()
        }
    }

    public func deleteLabel(_ labelID: String) {
        guard let projectID = snapshot?.board.projectID else { return }
        perform {
            try labelRepository.delete(labelID)
            labels = try labelRepository.labels(inProject: projectID)
            reloadSnapshot()
        }
    }

    // MARK: - Checklists

    public func addChecklistItem(_ text: String, to taskID: String) {
        perform {
            try checklistRepository.add(toTask: taskID, text: text)
            reloadSnapshot()
        }
    }

    public func setChecklistItem(_ itemID: String, done: Bool) {
        perform {
            try checklistRepository.setDone(done, for: itemID)
            reloadSnapshot()
        }
    }

    public func setChecklistItem(_ itemID: String, text: String) {
        perform {
            try checklistRepository.setText(text, for: itemID)
            reloadSnapshot()
        }
    }

    public func deleteChecklistItem(_ itemID: String) {
        perform {
            try checklistRepository.delete(itemID)
            reloadSnapshot()
        }
    }

    // MARK: - Hierarchy

    public func setParent(_ parentID: String?, for taskID: String) {
        perform {
            try taskRepository.setParent(parentID, for: taskID)
            reloadSnapshot()
        }
    }

    public func setEpic(_ epicID: String?, for taskID: String) {
        perform {
            try taskRepository.setEpic(epicID, for: taskID)
            reloadSnapshot()
        }
    }

    /// Adds a card and files it under this one in a single action, since
    /// "add a subtask" is one thought.
    public func addSubtask(_ title: String, to parentID: String) {
        guard let parent = snapshot?.columns.lazy.flatMap(\.tasks).first(where: { $0.id == parentID })
        else { return }

        perform {
            let child = try taskRepository.create(
                inProject: parent.projectID,
                statusID: parent.statusID,
                title: title
            )
            try taskRepository.setParent(parentID, for: child.id)
            reloadSnapshot()
        }
    }

    // MARK: - Reshaping the board

    public func createProject(named name: String, key: String) {
        guard let workspaceID = workspaces.first?.id else { return }
        perform {
            let project = try boardRepository.createProject(inWorkspace: workspaceID, name: name, key: key)
            load()
            selectedBoardID = try boardRepository.boards(inProject: project.id).first?.id
        }
    }

    public func renameProject(_ projectID: String, to name: String) {
        perform {
            try boardRepository.renameProject(projectID, to: name)
            load()
        }
    }

    public func deleteProject(_ projectID: String) {
        perform {
            try boardRepository.deleteProject(projectID)
            selectedBoardID = nil
            load()
        }
    }

    public func createBoard(named name: String, inProject projectID: String) {
        perform {
            let board = try boardRepository.createBoard(inProject: projectID, name: name)
            load()
            selectedBoardID = board.id
        }
    }

    public func renameBoard(_ boardID: String, to name: String) {
        perform {
            try boardRepository.renameBoard(boardID, to: name)
            load()
        }
    }

    public func deleteBoard(_ boardID: String) {
        perform {
            try boardRepository.deleteBoard(boardID)
            if selectedBoardID == boardID { selectedBoardID = nil }
            load()
        }
    }

    public func addColumn(named name: String, category: StatusCategory = .toDo) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try boardRepository.addColumn(toBoard: boardID, name: name, category: category)
            reloadSnapshot()
        }
    }

    public func renameColumn(_ columnID: String, to name: String) {
        perform {
            try boardRepository.renameColumn(columnID, to: name)
            reloadSnapshot()
        }
    }

    public func setWIPLimit(_ limit: Int?, for columnID: String) {
        perform {
            try boardRepository.setWIPLimit(limit, for: columnID)
            reloadSnapshot()
        }
    }

    public func setCategory(_ category: StatusCategory, for columnID: String) {
        perform {
            try boardRepository.setCategory(category, for: columnID)
            reloadSnapshot()
        }
    }

    public func deleteColumn(_ columnID: String, movingTasksTo destinationStatusID: String?) {
        perform {
            try boardRepository.deleteColumn(columnID, movingTasksTo: destinationStatusID)
            reloadSnapshot()
        }
    }

    public func moveColumn(_ columnID: String, after: String?, before: String?) {
        perform {
            try boardRepository.moveColumn(columnID, after: after, before: before)
            reloadSnapshot()
        }
    }

    // MARK: - Error handling

    /// Every database call the views make comes through here, so no view has a
    /// `try` in it and no failure can reach the user as a crash.
    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            failure = nil
        } catch let error as LocalBoardError {
            failure = error
            Log.app.error("Board action failed: \(String(describing: error.errorDescription), privacy: .public)")
        } catch {
            failure = .databaseQueryFailed(detail: error.localizedDescription)
            Log.app.error("Board action failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func dismissFailure() {
        failure = nil
    }
}
