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
                statuses: column.statuses,
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
    public private(set) var quickFilters: [QuickFilter] = []
    public private(set) var swimlanes: [Swimlane] = []
    public private(set) var versions: [Version] = []

    /// Which quick filters are pressed. Several at once mean all of them, so
    /// they narrow the board rather than competing for it.
    public var activeQuickFilterIDs: Set<String> = [] {
        didSet {
            guard activeQuickFilterIDs != oldValue else { return }
            applyQuery()
        }
    }

    /// The dropdowns beside the search field. Each is one more `AND`.
    public var facetAssigneeID: String? { didSet { facetChanged(facetAssigneeID, oldValue) } }
    public var facetEpicID: String? { didSet { facetChanged(facetEpicID, oldValue) } }
    public var facetLabelID: String? { didSet { facetChanged(facetLabelID, oldValue) } }
    public var facetType: TaskType? { didSet { facetChanged(facetType, oldValue) } }

    private func facetChanged<T: Equatable>(_ new: T?, _ old: T?) {
        guard new != old else { return }
        applyQuery()
    }

    /// The cards picked out for a bulk edit. Separate from `selectedTaskID`,
    /// which is the one card the inspector is showing: selecting twenty cards
    /// to assign them is a different act from opening one to read it.
    public private(set) var selectedTaskIDs: Set<String> = []

    /// What the last bulk edit replaced. One deep, because a bulk edit is an
    /// action you either take back straight away or live with.
    public private(set) var lastBulkEdit: TaskRepository.UndoRecord?

    /// Who this copy of the app belongs to, for `is:mine`.
    public private(set) var currentPersonID: String?

    /// The lanes the board is cut into, worked out after the query has run so
    /// that a lane counts only the cards actually on screen.
    public private(set) var lanes: [BoardLane] = []

    /// Which cards the board's colour view picked out, when cards are coloured
    /// by a saved view. Empty for every other colour rule.
    public private(set) var colorQueryMatches: Set<String> = []

    /// Git references already looked up, keyed by card tag. Cleared whenever
    /// the repository link changes.
    var gitReferenceCache: [String: [GitReferences.Reference]] = [:]

    private let database: Database
    private let boardRepository: BoardRepository
    private let taskRepository: TaskRepository
    private let personRepository: PersonRepository
    private let savedViewRepository: SavedViewRepository
    private let labelRepository: LabelRepository
    private let checklistRepository: ChecklistRepository
    let versionRepository: VersionRepository
    let presentationRepository: BoardPresentationRepository
    let analyticsRepository: AnalyticsRepository
    let settings: AppSettings

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.boardRepository = BoardRepository(database: database, clock: clock)
        self.taskRepository = TaskRepository(database: database, clock: clock)
        self.personRepository = PersonRepository(database: database, clock: clock)
        self.savedViewRepository = SavedViewRepository(database: database, clock: clock)
        self.labelRepository = LabelRepository(database: database)
        self.checklistRepository = ChecklistRepository(database: database, clock: clock)
        self.versionRepository = VersionRepository(database: database, clock: clock)
        self.presentationRepository = BoardPresentationRepository(database: database)
        self.analyticsRepository = AnalyticsRepository(database: database, clock: clock)
        self.settings = AppSettings(database: database)
    }

    /// The repositories the board's own screens reach for. Everything still
    /// goes through `perform`; these are handed out so that the analytics and
    /// version screens do not each need their own copy of the plumbing.
    var tasks: TaskRepository { taskRepository }
    var structure: BoardRepository { boardRepository }

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
                versions = try versionRepository.versions(inProject: projectID)
            }
            colorQueryMatches = try colorMatches()
            quickFilters = try presentationRepository.quickFilters(inBoard: selectedBoardID)
            swimlanes = try presentationRepository.swimlanes(inBoard: selectedBoardID)
            currentPersonID = try settings.currentPersonID

            // A selection outlives a reload only for cards that are still
            // there; one that has been trashed or moved off the board is no
            // longer something a bulk edit should silently include.
            let onBoard = Set(snapshot?.columns.flatMap { $0.tasks.map(\.id) } ?? [])
            selectedTaskIDs.formIntersection(onBoard)
        }
        loadSelectionDetails()
    }

    /// The cards the board's colour view selected.
    ///
    /// A view that no longer parses colours nothing rather than failing the
    /// whole load: the board is still perfectly usable in one colour.
    private func colorMatches() throws -> Set<String> {
        guard let board = snapshot?.board, board.colorRule == .query,
              let viewID = board.colorViewID,
              let view = try savedViewRepository.views(inProject: board.projectID)
                  .first(where: { $0.id == viewID })
        else { return [] }

        guard let found = try? taskRepository.tasks(matching: view.query, inProject: board.projectID)
        else { return [] }
        return Set(found.map(\.id))
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

    /// Everything narrowing the board at once: what is typed, which quick
    /// filters are pressed, and what the facet dropdowns are set to.
    ///
    /// They combine as text in the query language rather than as three
    /// separate passes over the result. That way there is exactly one thing
    /// the board is asking, it is written in a language the user already has,
    /// and it can be read back — which is what makes "why is this card
    /// hidden?" an answerable question.
    public var effectiveQuery: String {
        var parts: [String] = []

        let typed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append("(\(typed))") }

        for filter in quickFilters where activeQuickFilterIDs.contains(filter.id) {
            parts.append("(\(filter.query))")
        }

        if let person = person(id: facetAssigneeID) {
            parts.append("assignee = \(Self.quoted(person.name))")
        }
        if let epic = epics.first(where: { $0.id == facetEpicID }) {
            parts.append("epic = \(Self.quoted(epic.title))")
        }
        if let label = labels.first(where: { $0.id == facetLabelID }) {
            parts.append("label = \(Self.quoted(label.name))")
        }
        if let facetType {
            parts.append("type = \(Self.typeWord(facetType))")
        }

        return parts.joined(separator: " ")
    }

    /// A name with a space in it has to be quoted, or the parser reads the
    /// second word as a separate term.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "") + "\""
    }

    private static func typeWord(_ type: TaskType) -> String {
        switch type {
        case .epic: "epic"
        case .story: "story"
        case .task: "task"
        case .bug: "bug"
        }
    }

    /// Whether anything at all is narrowing the board.
    public var hasActiveFilters: Bool { !effectiveQuery.isEmpty }

    public func clearFilters() {
        queryText = ""
        activeQuickFilterIDs = []
        facetAssigneeID = nil
        facetEpicID = nil
        facetLabelID = nil
        facetType = nil
    }

    /// Runs the current query against the store and remembers which cards it
    /// matched. Called on every edit to the field and after every reload.
    private func applyQuery() {
        let combined = effectiveQuery

        guard !combined.isEmpty else {
            matchingTaskIDs = nil
            queryFailure = nil
            setShowsTrash(false)
            rebuildLanes()
            return
        }

        guard let projectID = snapshot?.board.projectID else { return }

        do {
            // The board hides trashed cards, so a query about them has to
            // change what was read, not just what is shown — otherwise
            // `is:trashed` filters a set the trash was never in.
            setShowsTrash(try TaskQueryParser.parse(combined).mentionsTrash)

            let matches = try taskRepository.tasks(matching: combined, inProject: projectID)
            matchingTaskIDs = Set(matches.map(\.id))
            queryFailure = nil
        } catch let error as QueryError {
            // Keep showing the last good result while the query is being
            // finished, rather than blanking the board on every keystroke.
            queryFailure = error.message
        } catch {
            queryFailure = error.localizedDescription
        }

        rebuildLanes()
    }

    /// Works out the lanes for the cards currently on screen.
    ///
    /// Each query lane is one more statement against the store, which is why
    /// this runs after filtering rather than per card: a board with four lanes
    /// costs four queries however many hundred cards it is showing.
    private func rebuildLanes() {
        guard let snapshot else {
            lanes = []
            return
        }

        let visible = visibleColumns.flatMap(\.tasks)
        guard !visible.isEmpty else {
            lanes = []
            return
        }

        // Only the lanes that can actually claim a card are worth asking about.
        let needed = swimlanes.filter { $0.pinned || snapshot.board.swimlaneMode == .query }

        var matches: [String: Set<String>] = [:]
        for lane in needed {
            guard let found = try? taskRepository.tasks(
                matching: lane.query, inProject: snapshot.board.projectID
            ) else {
                // A lane whose query has stopped parsing claims nothing rather
                // than everything, and the board carries on without it.
                continue
            }
            matches[lane.id] = Set(found.map(\.id))
        }

        lanes = SwimlaneGrouping.lanes(
            for: visible,
            mode: snapshot.board.swimlaneMode,
            swimlanes: swimlanes,
            queryMatches: matches,
            names: SwimlaneGrouping.Names(
                epics: Dictionary(epics.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }),
                people: Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                parents: Dictionary(
                    snapshot.columns.flatMap(\.tasks).map { ($0.id, $0.title) },
                    uniquingKeysWith: { first, _ in first }
                )
            )
        )
    }

    /// Whether the board is drawn in lanes at all.
    public var isLaned: Bool {
        guard let snapshot else { return false }
        return snapshot.board.swimlaneMode != .none || lanes.contains(where: \.isPinned)
    }

    /// One lane's columns, for drawing a row of the board.
    public func columns(in lane: BoardLane) -> [LoadedColumn] {
        visibleColumns.map { column in
            LoadedColumn(
                column: column.column,
                status: column.status,
                statuses: column.statuses,
                tasks: column.tasks.filter { lane.taskIDs.contains($0.id) }
            )
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

    /// Adds a card to a column, at the end or at the top.
    ///
    /// The top is where the next thing to be picked up goes on a board read
    /// downwards, so a column needs both — and creating at the top is a create
    /// followed by a move rather than a second insert path, so the sparse
    /// ordering and the history entry stay in one place.
    public func addTask(title: String, toStatus statusID: String, atTop: Bool = false) {
        guard let projectID = snapshot?.board.projectID else { return }
        perform {
            let created = try taskRepository.create(
                inProject: projectID, statusID: statusID, title: title
            )
            if atTop, let first = snapshot?.columns
                .first(where: { $0.statuses.contains { $0.id == statusID } })?
                .tasks.first, first.id != created.id {
                try taskRepository.move(created.id, toStatus: statusID, after: nil, before: first.id)
            }
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

// MARK: - Milestone 1.5

extension BoardViewModel {

    // MARK: Flags

    public func setFlag(_ flagged: Bool, reason: String = "", for taskID: String) {
        perform {
            try tasks.setFlag(flagged, reason: reason, for: taskID)
            reloadSnapshot()
        }
    }

    // MARK: Estimates and releases

    public func setEstimate(_ estimate: Double?, for taskID: String) {
        perform {
            try tasks.setEstimate(estimate, for: taskID)
            reloadSnapshot()
        }
    }

    public func setVersion(_ versionID: String?, for taskID: String) {
        perform {
            try tasks.setVersion(versionID, for: taskID)
            reloadSnapshot()
        }
    }

    public func version(id: String?) -> Version? {
        guard let id else { return nil }
        return versions.first { $0.id == id }
    }

    public func createVersion(named name: String, releaseDate: Date? = nil) {
        guard let projectID = snapshot?.board.projectID else { return }
        perform {
            try versionRepository.create(inProject: projectID, name: name, releaseDate: releaseDate)
            versions = try versionRepository.versions(inProject: projectID)
        }
    }

    public func setVersionReleased(_ released: Bool, for versionID: String) {
        guard let projectID = snapshot?.board.projectID else { return }
        perform {
            try versionRepository.setReleased(released, for: versionID)
            versions = try versionRepository.versions(inProject: projectID)
        }
    }

    public func deleteVersion(_ versionID: String) {
        guard let projectID = snapshot?.board.projectID else { return }
        perform {
            try versionRepository.delete(versionID)
            versions = try versionRepository.versions(inProject: projectID)
            reloadSnapshot()
        }
    }

    public func progress(ofVersion versionID: String) -> ReleaseProgress {
        (try? versionRepository.progress(ofVersion: versionID))
            ?? ReleaseProgress(total: 0, done: 0, points: 0, donePoints: 0)
    }

    // MARK: Who "me" is

    public func setCurrentPerson(_ personID: String?) {
        perform {
            try settings.setCurrentPerson(personID)
            currentPersonID = try settings.currentPersonID
            // `is:mine` means something different now, so anything asking it
            // has to be asked again.
            applyQuery()
        }
    }

    // MARK: Quick filters

    public func toggleQuickFilter(_ filterID: String) {
        if activeQuickFilterIDs.contains(filterID) {
            activeQuickFilterIDs.remove(filterID)
        } else {
            activeQuickFilterIDs.insert(filterID)
        }
    }

    public func createQuickFilter(named name: String, query: String) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try presentationRepository.createQuickFilter(inBoard: boardID, name: name, query: query)
            quickFilters = try presentationRepository.quickFilters(inBoard: boardID)
        }
    }

    public func updateQuickFilter(_ filterID: String, name: String, query: String) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try presentationRepository.updateQuickFilter(filterID, name: name, query: query)
            quickFilters = try presentationRepository.quickFilters(inBoard: boardID)
        }
    }

    public func deleteQuickFilter(_ filterID: String) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try presentationRepository.deleteQuickFilter(filterID)
            quickFilters = try presentationRepository.quickFilters(inBoard: boardID)
            activeQuickFilterIDs.remove(filterID)
        }
    }

    /// Keeps the current query as a quick filter, which is the fastest way to
    /// get one: find what you want by typing, then pin it to the board.
    public func saveCurrentQueryAsQuickFilter(named name: String) {
        createQuickFilter(named: name, query: queryText)
    }

    // MARK: Swimlanes

    public func setSwimlaneMode(_ mode: SwimlaneMode) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try presentationRepository.setSwimlaneMode(mode, for: boardID)
            reloadSnapshot()
        }
    }

    public func createSwimlane(named name: String, query: String) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try presentationRepository.createSwimlane(inBoard: boardID, name: name, query: query)
            swimlanes = try presentationRepository.swimlanes(inBoard: boardID)
            reloadSnapshot()
        }
    }

    public func updateSwimlane(_ laneID: String, name: String, query: String) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try presentationRepository.updateSwimlane(laneID, name: name, query: query)
            swimlanes = try presentationRepository.swimlanes(inBoard: boardID)
            reloadSnapshot()
        }
    }

    public func deleteSwimlane(_ laneID: String) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try presentationRepository.deleteSwimlane(laneID)
            swimlanes = try presentationRepository.swimlanes(inBoard: boardID)
            reloadSnapshot()
        }
    }

    // MARK: How the board looks

    public func setCardFields(_ fields: [CardField]) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try presentationRepository.setCardFields(fields, for: boardID)
            reloadSnapshot()
        }
    }

    /// Adds or removes one card row, keeping inside the three a card can hold.
    public func toggleCardField(_ field: CardField) {
        guard let board = snapshot?.board else { return }
        var fields = board.cardFields

        if let index = fields.firstIndex(of: field) {
            fields.remove(at: index)
        } else {
            guard fields.count < CardField.maximumPerBoard else {
                failure = .invalidInput(
                    field: "card fields",
                    detail: "A card shows at most \(CardField.maximumPerBoard) extra rows. Turn one off first."
                )
                return
            }
            fields.append(field)
        }
        setCardFields(fields)
    }

    public func setColorRule(_ rule: CardColorRule, viewID: String? = nil) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try presentationRepository.setColorRule(rule, viewID: viewID, for: boardID)
            reloadSnapshot()
        }
    }

    public func setStaleDays(_ days: Int) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try presentationRepository.setStaleDays(days, for: boardID)
            reloadSnapshot()
        }
    }

    public func setBoardQuery(_ query: String) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try presentationRepository.setFilterQuery(query, for: boardID)
            reloadSnapshot()
        }
    }

    // MARK: Columns

    public func setWIPMinimum(_ minimum: Int?, for columnID: String) {
        perform {
            try structure.setWIPMinimum(minimum, for: columnID)
            reloadSnapshot()
        }
    }

    public func setWIPMeasure(_ measure: WIPMeasure, for columnID: String) {
        perform {
            try structure.setWIPMeasure(measure, for: columnID)
            reloadSnapshot()
        }
    }

    public func setBacklog(_ isBacklog: Bool, for columnID: String) {
        perform {
            try structure.setBacklog(isBacklog, for: columnID)
            reloadSnapshot()
        }
    }

    public func mergeColumn(_ otherColumnID: String, into columnID: String) {
        guard let other = snapshot?.columns.first(where: { $0.id == otherColumnID }) else { return }
        perform {
            try structure.mapStatus(other.status.id, toColumn: columnID)
            reloadSnapshot()
        }
    }

    public func splitStatus(_ statusID: String, outOf columnID: String) {
        perform {
            try structure.unmapStatus(statusID, fromColumn: columnID)
            reloadSnapshot()
        }
    }

    // MARK: Selecting several cards

    public var hasSelection: Bool { !selectedTaskIDs.isEmpty }

    public func isPicked(_ taskID: String) -> Bool { selectedTaskIDs.contains(taskID) }

    /// ⌘-click: add this card to the selection, or take it out again.
    public func togglePicked(_ taskID: String) {
        if selectedTaskIDs.contains(taskID) {
            selectedTaskIDs.remove(taskID)
        } else {
            selectedTaskIDs.insert(taskID)
        }
    }

    /// Shift-click: everything between the last pick and this one, in the
    /// order the board is drawn rather than the order the ids happen to be in.
    public func extendPick(to taskID: String) {
        let ordered = visibleColumns.flatMap(\.tasks).map(\.id)
        guard let end = ordered.firstIndex(of: taskID) else { return }

        guard let anchor = selectedTaskIDs.compactMap({ ordered.firstIndex(of: $0) }).min() else {
            selectedTaskIDs = [taskID]
            return
        }
        let range = anchor <= end ? anchor...end : end...anchor
        selectedTaskIDs.formUnion(ordered[range])
    }

    public func pickAll() {
        selectedTaskIDs = Set(visibleColumns.flatMap(\.tasks).map(\.id))
    }

    public func clearPicks() {
        selectedTaskIDs = []
    }

    public var pickedTasks: [BoardTask] {
        visibleColumns.flatMap(\.tasks).filter { selectedTaskIDs.contains($0.id) }
    }

    // MARK: Bulk edits

    private func bulk(_ work: () throws -> TaskRepository.UndoRecord) {
        perform {
            lastBulkEdit = try work()
            reloadSnapshot()
        }
    }

    public func bulkMove(toStatus statusID: String) {
        let ids = orderedPicks
        bulk { try tasks.moveAll(ids, toStatus: statusID) }
    }

    public func bulkAssign(_ personID: String?) {
        let ids = orderedPicks
        bulk { try tasks.setAssigneeAll(personID, for: ids) }
    }

    public func bulkPriority(_ priority: Priority) {
        let ids = orderedPicks
        bulk { try tasks.setPriorityAll(priority, for: ids) }
    }

    public func bulkFlag(_ flagged: Bool, reason: String = "") {
        let ids = orderedPicks
        bulk { try tasks.setFlagAll(flagged, reason: reason, for: ids) }
    }

    public func bulkVersion(_ versionID: String?) {
        let ids = orderedPicks
        bulk { try tasks.setVersionAll(versionID, for: ids) }
    }

    public func bulkDueDate(_ due: Date?) {
        let ids = orderedPicks
        bulk { try tasks.setDueDateAll(due, for: ids) }
    }

    public func bulkTrash() {
        let ids = orderedPicks
        bulk { try tasks.setTrashedAll(true, for: ids) }
        clearPicks()
    }

    /// Board order, not set order: a bulk move should land the cards in the
    /// order they were picked up, and a `Set` has no order to preserve.
    private var orderedPicks: [String] {
        visibleColumns.flatMap(\.tasks).map(\.id).filter { selectedTaskIDs.contains($0) }
    }

    public func undoLastBulkEdit() {
        guard let record = lastBulkEdit else { return }
        perform {
            try tasks.restore(record)
            lastBulkEdit = nil
            reloadSnapshot()
        }
    }

    // MARK: Analytics

    public func cumulativeFlow(days: Int = 30) -> [FlowPoint] {
        guard let projectID = snapshot?.board.projectID else { return [] }
        return (try? analyticsRepository.cumulativeFlow(inProject: projectID, days: days)) ?? []
    }

    public func controlChart(days: Int = 90) -> [CycleTimePoint] {
        guard let projectID = snapshot?.board.projectID else { return [] }
        return (try? analyticsRepository.controlChart(inProject: projectID, days: days)) ?? []
    }

    public func burnup(taskIDs: Set<String>, days: Int = 60) -> [BurnupPoint] {
        (try? analyticsRepository.burnup(taskIDs: taskIDs, days: days)) ?? []
    }

    public func history(of taskID: String) -> [StatusChange] {
        (try? tasks.history(ofTask: taskID)) ?? []
    }

    public func statusName(_ statusID: String?) -> String {
        guard let statusID else { return "—" }
        return snapshot?.columns
            .flatMap(\.statuses)
            .first { $0.id == statusID }?.name ?? "Elsewhere"
    }
}

// MARK: - The optional link to a local checkout

extension BoardViewModel {

    public var repositoryLink: RepositoryLink? {
        guard let projectID = snapshot?.board.projectID else { return nil }
        return try? RepositoryLinkRepository(database: database).link(forProject: projectID)
    }

    public func linkRepository() {
        guard let projectID = snapshot?.board.projectID else { return }
        guard let chosen = RepositoryAccess.chooseFolder() else { return }

        perform {
            try RepositoryLinkRepository(database: database).setLink(
                projectID: projectID, path: chosen.url.path, bookmark: chosen.bookmark
            )
            gitReferenceCache = [:]
            reloadSnapshot()
        }
    }

    public func unlinkRepository() {
        guard let projectID = snapshot?.board.projectID else { return }
        perform {
            try RepositoryLinkRepository(database: database).removeLink(forProject: projectID)
            gitReferenceCache = [:]
            reloadSnapshot()
        }
    }

    /// The branches and commits naming this card.
    ///
    /// Read once per board load and kept, because scanning a checkout means
    /// touching the filesystem and the inspector asks on every redraw. The
    /// cache is thrown away whenever the link changes.
    public func gitReferences(for task: BoardTask) -> [GitReferences.Reference] {
        let tag = self.tag(for: task)

        if let cached = gitReferenceCache[tag] { return cached }
        guard let link = repositoryLink else { return [] }

        let found = RepositoryAccess.withAccess(to: link) { url in
            GitReferences.references(in: url, matching: [tag])
        } ?? []

        gitReferenceCache[tag] = found
        return found
    }
}
