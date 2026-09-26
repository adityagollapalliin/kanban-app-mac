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

    public internal(set) var workspaces: [Workspace] = []
    public internal(set) var projects: [Project] = []
    public internal(set) var boards: [Board] = []
    public private(set) var snapshot: BoardSnapshot?

    /// What went wrong with the last action. Shown, then dismissed by the next
    /// successful one — an error the user cannot clear is an error they learn
    /// to ignore.
    public internal(set) var failure: LocalBoardError?

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

    public internal(set) var people: [Person] = []
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

    /// What the last bulk edit replaced, for the bulk bar's own Undo button.
    public private(set) var lastBulkEdit: TaskRepository.UndoRecord?

    /// Undo and redo for every card edit, bulk or not.
    private var history = EditHistory()

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    public var undoLabel: String? { history.undoLabel }
    public var redoLabel: String? { history.redoLabel }

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

    let database: Database
    let boardRepository: BoardRepository
    let taskRepository: TaskRepository
    let personRepository: PersonRepository
    let savedViewRepository: SavedViewRepository
    let labelRepository: LabelRepository
    let checklistRepository: ChecklistRepository
    let versionRepository: VersionRepository
    let presentationRepository: BoardPresentationRepository
    let analyticsRepository: AnalyticsRepository
    let settings: AppSettings
    let cardDetailRepository: CardDetailRepository
    let customFieldRepository: CustomFieldRepository
    let sprintRepository: SprintRepository
    let workflowRepository: WorkflowRepository
    let automationRepository: AutomationRepository
    let templateRepository: TemplateRepository
    let structureRepository: StructureRepository
    let membershipRepository: MembershipRepository
    let recurrenceRepository: RecurrenceRepository
    let sidebarRepository: SidebarRepository
    let viewConfigRepository: ViewConfigRepository
    let activityRepository: ActivityRepository
    let workloadRepository: WorkloadRepository
    let personalRepository: PersonalRepository
    let docRepository: DocRepository
    let whiteboardRepository: WhiteboardRepository
    let goalRepository: GoalRepository
    let dashboardRepository: DashboardRepository
    let dashboardDataRepository: DashboardDataRepository
    let computedFieldRepository: ComputedFieldRepository
    let timeRepository: TimeRepository
    let vocabularyRepository: VocabularyRepository
    let componentRepository: ComponentRepository
    let transitionRuleRepository: TransitionRuleRepository
    let fieldConfigRepository: FieldConfigRepository

    /// The project's own fields, and what every card on the board has put in
    /// them — gathered in one query rather than one per card.
    public private(set) var customFields: [CustomField] = []
    public private(set) var customValues: [String: [String: CustomFieldValue]] = [:]

    /// The fields nobody fills in — formulas, rollups and progress counted off
    /// the subtasks. Worked out on load rather than stored, so a figure on a
    /// card is never one that was right an hour ago.
    public internal(set) var computedValues: [String: [String: FormulaValue]] = [:]

    /// Goals, the folders they sit in, and the dashboards over them.
    public internal(set) var goals: [Goal] = []
    public internal(set) var goalFolders: [GoalFolder] = []
    public internal(set) var dashboards: [Dashboard] = []

    /// The words this project uses for its own work — the kinds of card, the
    /// priority scale, the link pairs, the resolutions — and its components.
    public internal(set) var issueTypes: [IssueType] = []
    public internal(set) var priorityValues: [PriorityValue] = []
    public internal(set) var linkTypes: [LinkType] = []
    public internal(set) var resolutions: [Resolution] = []
    public internal(set) var components: [Component] = []
    public internal(set) var componentsByTask: [String: [Component]] = [:]

    /// The rules on each transition, and what each kind of card asks for.
    public internal(set) var transitionRules: [String: [TransitionRule]] = [:]
    public internal(set) var fieldConfigs: [Int: [FieldConfiguration]] = [:]

    /// A move that is waiting for the person to fill something in.
    ///
    /// A transition can be configured to stop and ask. Rather than each place
    /// that moves a card knowing about that, `move` parks the move here and
    /// the board presents it — so a drag, a menu and the card's own status
    /// picker all behave the same way without any of them being told.
    public internal(set) var pendingTransition: PendingTransition?

    /// Bumped whenever a dashboard's widgets or the time log change.
    ///
    /// The widgets and the timesheet are read on demand rather than held in
    /// the model — a dashboard of a dozen widgets is a dozen queries, and
    /// running them on every board reload would be paying for a screen nobody
    /// is looking at. The counter is what tells the view to ask again.
    public internal(set) var dashboardRevision = 0
    public internal(set) var timeRevision = 0

    public private(set) var sprints: [Sprint] = []
    public private(set) var activeSprint: Sprint?
    public private(set) var automations: [Automation] = []
    public private(set) var transitions: [WorkflowTransition] = []
    public private(set) var cardTemplates: [Template] = []
    public private(set) var projectTemplates: [Template] = []

    /// The timer, if one is running. Read on every load, because it may have
    /// been started by another window or left running from last time.
    public private(set) var runningTimer: RunningTimer?

    /// How many cards the last completed sprint carried over. Shown once and
    /// then cleared: "the sprint is done" and "four things did not fit" are
    /// different news, and only the second needs acting on.
    public var carriedOverCount: Int?

    /// How much room the board gives each card, and the accent it draws in.
    /// Stored with the file rather than with the Mac, like everything else
    /// about how a board looks.
    public var density: Density = .comfortable {
        didSet {
            guard density != oldValue else { return }
            perform { try settings.setDensity(density) }
        }
    }

    public var accentName: String = "" {
        didSet {
            guard accentName != oldValue else { return }
            perform { try settings.setAccent(accentName.isEmpty ? nil : accentName) }
        }
    }

    /// Light, dark, or whatever the Mac is doing.
    public var appearance: Appearance = .system {
        didSet {
            guard appearance != oldValue else { return }
            perform { try settings.setAppearance(appearance) }
        }
    }

    /// The card the keyboard is on, which is not the same as the card that is
    /// open or the cards that are picked. Focus is where the next arrow key
    /// starts from; it moves without changing anything.
    public var focusedTaskID: String?

    /// Bumped by ⌘N. A column watches it rather than a flag, so pressing it
    /// twice opens the field twice rather than the second press doing nothing.
    public internal(set) var quickAddToken = 0
    /// The column ⌘N should open in: the one the keyboard is in, or the first.
    public internal(set) var quickAddStatusID: String?

    /// The open card's conversation, files, links and hours. Loaded with the
    /// selection rather than for the whole board, because only one card is
    /// ever open and four more queries per card would be four hundred on a
    /// board of a hundred.
    public private(set) var comments: [Comment] = []
    public private(set) var attachments: [Attachment] = []
    public private(set) var links: [(link: TaskLink, kind: LinkKind, otherID: String)] = []
    public private(set) var workLog: [WorkLogEntry] = []

    /// Badge counts for every card on the board, gathered in two queries.
    public private(set) var commentCounts: [String: Int] = [:]
    public private(set) var attachmentCounts: [String: Int] = [:]

    /// Every link in the project, gathered once per load. The timeline draws
    /// an arrow per dependency and cannot afford a query per card per redraw.
    private var linksByTask: [String: [(link: TaskLink, kind: LinkKind, otherID: String)]] = [:]

    // MARK: - The hierarchy

    /// The folders and lists of the space on screen, and which list — if any —
    /// the board is narrowed to. `nil` means the whole space, which is what a
    /// board has always shown.
    public internal(set) var folders: [Folder] = []
    public internal(set) var lists: [TaskList] = []
    public var selectedListID: String? {
        didSet {
            guard selectedListID != oldValue else { return }
            applyQuery()
            if let selectedListID, let list = lists.first(where: { $0.id == selectedListID }) {
                perform { try sidebarRepository.recordVisit(.list, id: list.id, label: list.name) }
                loadSidebar()
            }
        }
    }

    /// Everyone on each card, and where else each card appears. Both gathered
    /// once per load, for the same reason every other per-card fact is.
    public internal(set) var assigneesByTask: [String: [TaskAssignee]] = [:]
    public internal(set) var extraListsByTask: [String: [TaskList]] = [:]

    /// The sidebar's shortcuts, and the things that have been put away.
    public internal(set) var favorites: [Shortcut] = []
    public internal(set) var pinnedViews: [Shortcut] = []
    public internal(set) var recents: [Shortcut] = []
    public internal(set) var trashedTasks: [BoardTask] = []
    public internal(set) var archivedLists: [TaskList] = []
    public internal(set) var archivedFolders: [Folder] = []

    /// Reminders, the notepad, and the cards open in their own windows.
    public internal(set) var reminders: [Reminder] = []
    public var notepad: String = ""
    /// Cards put in the tray: open panels set aside rather than closed, so
    /// several can be kept to hand and swapped between.
    public internal(set) var trayTaskIDs: [String] = []
    /// The documents that mention the open card.
    public internal(set) var backlinks: [Doc] = []
    /// Action items asked of whoever "me" is.
    public internal(set) var myActionItems: [Comment] = []

    /// The open card's recurrence rule, loaded with the selection.
    public internal(set) var recurrence: Recurrence?
    public internal(set) var extraLists: [TaskList] = []
    public internal(set) var assignees: [TaskAssignee] = []

    public init(
        database: Database,
        clock: any ClockProvider = SystemClock(),
        paths: ContainerPaths? = nil
    ) {
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
        self.cardDetailRepository = CardDetailRepository(
            database: database, clock: clock, paths: paths
        )
        self.customFieldRepository = CustomFieldRepository(database: database, clock: clock)
        self.sprintRepository = SprintRepository(database: database, clock: clock)
        self.workflowRepository = WorkflowRepository(database: database, clock: clock)
        self.automationRepository = AutomationRepository(database: database, clock: clock)
        self.templateRepository = TemplateRepository(database: database, clock: clock)
        self.structureRepository = StructureRepository(database: database, clock: clock)
        self.membershipRepository = MembershipRepository(database: database, clock: clock)
        self.recurrenceRepository = RecurrenceRepository(database: database, clock: clock)
        self.sidebarRepository = SidebarRepository(database: database, clock: clock)
        self.viewConfigRepository = ViewConfigRepository(database: database, clock: clock)
        self.activityRepository = ActivityRepository(database: database)
        self.workloadRepository = WorkloadRepository(database: database)
        self.personalRepository = PersonalRepository(database: database, clock: clock)
        self.docRepository = DocRepository(database: database, clock: clock)
        self.whiteboardRepository = WhiteboardRepository(database: database, clock: clock)
        self.goalRepository = GoalRepository(database: database, clock: clock)
        self.dashboardRepository = DashboardRepository(database: database, clock: clock)
        self.dashboardDataRepository = DashboardDataRepository(database: database, clock: clock)
        self.computedFieldRepository = ComputedFieldRepository(database: database, clock: clock)
        self.timeRepository = TimeRepository(database: database, clock: clock)
        self.vocabularyRepository = VocabularyRepository(database: database, clock: clock)
        self.componentRepository = ComponentRepository(database: database, clock: clock)
        self.transitionRuleRepository = TransitionRuleRepository(database: database, clock: clock)
        self.fieldConfigRepository = FieldConfigRepository(database: database, clock: clock)
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

    func reloadSnapshot() {
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

                let counts = try cardDetailRepository.countsByTask(inProject: projectID)
                commentCounts = counts.comments
                attachmentCounts = counts.attachments
                linksByTask = try cardDetailRepository.linksByTask(inProject: projectID)

                customFields = try customFieldRepository.fields(inProject: projectID)
                customValues = try customFieldRepository.valuesByTask(inProject: projectID)
                computedValues = try computedFieldRepository.values(inProject: projectID)
                goals = try goalRepository.goals(inProject: projectID)
                goalFolders = try goalRepository.folders(inProject: projectID)
                dashboards = try dashboardRepository.dashboards(inProject: projectID)
                issueTypes = try vocabularyRepository.issueTypes(inProject: projectID)
                priorityValues = try vocabularyRepository.priorities(inProject: projectID)
                linkTypes = try vocabularyRepository.linkTypes(inProject: projectID)
                resolutions = try vocabularyRepository.resolutions(inProject: projectID)
                components = try componentRepository.components(inProject: projectID)
                componentsByTask = try componentRepository.componentsByTask(inProject: projectID)
                transitionRules = try transitionRuleRepository.rulesByTransition(inProject: projectID)
                fieldConfigs = try fieldConfigRepository.configurationsByType(inProject: projectID)
                sprints = try sprintRepository.sprints(inProject: projectID)
                activeSprint = try sprintRepository.activeSprint(inProject: projectID)
                automations = try automationRepository.automations(inProject: projectID)
                transitions = try workflowRepository.transitions(inProject: projectID)
                cardTemplates = try templateRepository.cardTemplates(inProject: projectID)
            }
            projectTemplates = try templateRepository.projectTemplates()
            runningTimer = try cardDetailRepository.runningTimer()
            density = try settings.density
            accentName = try settings.accent ?? ""
            appearance = try settings.appearance
            colorQueryMatches = try colorMatches()
            quickFilters = try presentationRepository.quickFilters(inBoard: selectedBoardID)
            swimlanes = try presentationRepository.swimlanes(inBoard: selectedBoardID)
            currentPersonID = try settings.currentPersonID
            if let projectID = currentProjectID {
                try loadStructure(projectID: projectID)
                purgeExpiredTrash()
                loadSidebar()
            }

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

    func loadSelectionDetails() {
        guard let selectedTaskID else {
            checklist = []
            subtasks = []
            comments = []
            attachments = []
            links = []
            workLog = []
            return
        }
        perform {
            checklist = try checklistRepository.items(forTask: selectedTaskID)
            subtasks = try taskRepository.subtasks(of: selectedTaskID)
            comments = try cardDetailRepository.comments(forTask: selectedTaskID)
            attachments = try cardDetailRepository.attachments(forTask: selectedTaskID)
            links = try cardDetailRepository.links(forTask: selectedTaskID)
            workLog = try cardDetailRepository.workLog(forTask: selectedTaskID)
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
    func applyQuery() {
        let combined = effectiveQuery

        guard !combined.isEmpty else {
            // A chosen list narrows the board even with no query typed: it is
            // a place, not a filter, and the search field should stay empty
            // while you are standing in it.
            matchingTaskIDs = listMembership
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
            // Both narrow: a query asked inside a list is asked of that list.
            let matched = Set(matches.map(\.id))
            matchingTaskIDs = listMembership.map { matched.intersection($0) } ?? matched
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

    /// The cards a chosen list shows — the ones that live in it and the ones
    /// added to it from elsewhere — or `nil` when the whole space is on
    /// screen, which is what a board has always shown.
    private var listMembership: Set<String>? {
        guard let selectedListID else { return nil }
        let resident = snapshot?.columns.flatMap(\.tasks).filter { $0.listID == selectedListID } ?? []
        let borrowed = extraListsByTask.filter { $0.value.contains { $0.id == selectedListID } }.keys
        return Set(resident.map(\.id)).union(borrowed)
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

        // A transition that stops to ask parks itself here instead of going
        // through. Nothing is written until the sheet is filled in and
        // submitted, so cancelling leaves the card exactly where it was.
        if let transition = transitionNeedingScreen(from: taskID, to: statusID) {
            pendingTransition = PendingTransition(
                taskID: taskID, statusID: statusID, before: before, transition: transition
            )
            return
        }

        performMove(taskID, toStatus: statusID, before: before)
    }

    /// The transition being taken, if it has a screen and the card has not
    /// already answered everything on it.
    private func transitionNeedingScreen(from taskID: String, to statusID: String) -> WorkflowTransition? {
        guard let task = task(id: taskID), task.statusID != statusID else { return nil }
        guard let transition = transitions.first(where: {
            $0.fromStatusID == task.statusID && $0.toStatusID == statusID
        }), transition.hasScreen else { return nil }

        // Asking for something already filled in is a dialog nobody learns
        // anything from, so a screen whose fields are all answered is skipped.
        let unanswered = transition.screenFields.filter { !isFilledIn($0, on: taskID) }
        return unanswered.isEmpty ? nil : transition
    }

    func isFilledIn(_ field: FieldReference, on taskID: String) -> Bool {
        (try? transitionRuleRepository.isFilledIn(field, on: taskID)) ?? true
    }

    /// Fills in what the screen asked for, then makes the move.
    public func completePendingTransition(_ values: [FieldReference: String]) {
        guard let pending = pendingTransition else { return }
        pendingTransition = nil

        perform {
            for (field, value) in values where !value.trimmingCharacters(in: .whitespaces).isEmpty {
                try transitionRuleRepository.setField(field, to: value, on: pending.taskID)
            }
        }
        performMove(pending.taskID, toStatus: pending.statusID, before: pending.before)
    }

    public func cancelPendingTransition() {
        pendingTransition = nil
    }

    private func performMove(_ taskID: String, toStatus statusID: String, before: String?) {
        editing([taskID], "Move") {
            let after = try neighbourAbove(before: before, inStatus: statusID, moving: taskID)
            try taskRepository.move(taskID, toStatus: statusID, after: after, before: before)
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
        editing([taskID], trashed ? "Move to Trash" : "Put Back") {
            try taskRepository.setTrashed(trashed, for: taskID)
            if trashed, selectedTaskID == taskID { selectedTaskID = nil }
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

    /// Runs a card edit, remembering what the cards were so it can be undone.
    ///
    /// Every single-card mutation goes through here, which is the only reason
    /// Undo covers the whole app rather than the two or three places somebody
    /// remembered to wire it into.
    func editing(_ taskIDs: [String], _ label: String, _ work: () throws -> Void) {
        let before = taskRepository.snapshot(taskIDs, label: label)
        perform {
            try work()
            history.record(before)
            reloadSnapshot()
        }
    }

    public func undo() {
        guard let record = history.popUndo(currentState: { taskRepository.snapshot($0.tasks.map(\.id), label: $0.label) })
        else { return }
        perform {
            try taskRepository.restore(record)
            reloadSnapshot()
        }
    }

    public func redo() {
        guard let record = history.popRedo(currentState: { taskRepository.snapshot($0.tasks.map(\.id), label: $0.label) })
        else { return }
        perform {
            try taskRepository.restore(record)
            reloadSnapshot()
        }
    }

    public func rename(_ taskID: String, to title: String) {
        editing([taskID], "Rename") {
            try taskRepository.setTitle(title, for: taskID)
        }
    }

    public func setDescription(_ markdown: String, for taskID: String) {
        editing([taskID], "Edit Notes") {
            try taskRepository.setDescription(markdown, for: taskID)
        }
    }

    public func setType(_ type: TaskType, for taskID: String) {
        editing([taskID], "Change Type") {
            try taskRepository.setType(type, for: taskID)
        }
    }

    public func setPriority(_ priority: Priority, for taskID: String) {
        editing([taskID], "Change Priority") {
            try taskRepository.setPriority(priority, for: taskID)
        }
    }

    public func setDueDate(_ due: Date?, for taskID: String) {
        editing([taskID], "Change Due Date") {
            try taskRepository.setDueDate(due, for: taskID)
        }
    }

    public func setStartDate(_ start: Date?, for taskID: String) {
        editing([taskID], "Change Start Date") {
            try taskRepository.setStartDate(start, for: taskID)
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
        editing([taskID], "Assign") {
            try taskRepository.setAssignee(personID, for: taskID)
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
    func perform(_ work: () throws -> Void) {
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
        editing([taskID], flagged ? "Flag" : "Remove Flag") {
            try tasks.setFlag(flagged, reason: reason, for: taskID)
        }
    }

    // MARK: Estimates and releases

    public func setEstimate(_ estimate: Double?, for taskID: String) {
        editing([taskID], "Change Points") {
            try tasks.setEstimate(estimate, for: taskID)
        }
    }

    public func setVersion(_ versionID: String?, for taskID: String) {
        editing([taskID], "Set Release") {
            try tasks.setVersion(versionID, for: taskID)
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
            if let projectID = currentProjectID {
                try loadStructure(projectID: projectID)
                purgeExpiredTrash()
                loadSidebar()
            }
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

    public func setCardFields(_ fields: [CardField], custom customIDs: [String] = []) {
        guard let boardID = selectedBoardID else { return }
        perform {
            try presentationRepository.setCardFields(fields, custom: customIDs, for: boardID)
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
            guard hasRoomForAnotherCardRow else { return }
            fields.append(field)
        }
        setCardFields(fields, custom: board.customCardFieldIDs)
    }

    /// The same, for one of the project's own fields. They share the cap with
    /// the built-in rows, because a card showing six things shows none of them.
    public func toggleCustomCardField(_ fieldID: String) {
        guard let board = snapshot?.board else { return }
        var ids = board.customCardFieldIDs

        if let index = ids.firstIndex(of: fieldID) {
            ids.remove(at: index)
        } else {
            guard hasRoomForAnotherCardRow else { return }
            ids.append(fieldID)
        }
        setCardFields(board.cardFields, custom: ids)
    }

    private var hasRoomForAnotherCardRow: Bool {
        guard let board = snapshot?.board else { return false }
        guard board.cardRowCount < CardField.maximumPerBoard else {
            failure = .invalidInput(
                field: "card rows",
                detail: "A card shows at most \(CardField.maximumPerBoard) extra rows. Turn one off first."
            )
            return false
        }
        return true
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

    /// Picks a set of cards, either replacing the selection or adding to it.
    /// The lasso uses this on every frame of the drag.
    public func pick(_ taskIDs: [String], adding: Bool) {
        if adding {
            selectedTaskIDs.formUnion(taskIDs)
        } else {
            selectedTaskIDs = Set(taskIDs)
        }
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
            let record = try work()
            lastBulkEdit = record
            history.record(record)
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

// MARK: - What else a card carries

extension BoardViewModel {

    // MARK: Comments

    /// Comments are attributed to whoever is chosen in Settings. Nobody
    /// chosen means an unattributed remark, which is honest — the alternative
    /// is inventing an author.
    public func addComment(_ body: String, to taskID: String) {
        perform {
            try cardDetailRepository.addComment(toTask: taskID, body: body, authorID: currentPersonID)
            loadSelectionDetails()
            reloadCounts()
        }
    }

    public func editComment(_ commentID: String, body: String) {
        perform {
            try cardDetailRepository.editComment(commentID, body: body)
            loadSelectionDetails()
        }
    }

    public func deleteComment(_ commentID: String) {
        perform {
            try cardDetailRepository.deleteComment(commentID)
            loadSelectionDetails()
            reloadCounts()
        }
    }

    // MARK: Attachments

    public func attachFile(to taskID: String) {
        guard let source = RepositoryAccess.chooseFile() else { return }

        // The panel hands back a URL the app may read for as long as it holds
        // access; the copy has to happen inside that window.
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        perform {
            try cardDetailRepository.attach(source, toTask: taskID)
            loadSelectionDetails()
            reloadCounts()
        }
    }

    public func url(of attachment: Attachment) -> URL? {
        cardDetailRepository.url(of: attachment)
    }

    public func removeAttachment(_ attachmentID: String) {
        perform {
            try cardDetailRepository.removeAttachment(attachmentID)
            loadSelectionDetails()
            reloadCounts()
        }
    }

    // MARK: Links

    public func link(_ taskID: String, _ kind: LinkKind, to otherID: String) {
        perform {
            try cardDetailRepository.link(taskID, kind, to: otherID)
            loadSelectionDetails()
        }
    }

    /// Every link on a card, for the timeline's arrows.
    ///
    /// Read straight from the store rather than from the inspector's cached
    /// copy, which only ever holds the one open card.
    public func links(forTask taskID: String) -> [(link: TaskLink, kind: LinkKind, otherID: String)] {
        // The open card's own list is the freshly loaded one; everything else
        // comes from the single pass made when the board was read.
        if taskID == selectedTaskID { return links }
        return linksByTask[taskID] ?? []
    }

    public func unlink(_ linkID: String) {
        perform {
            try cardDetailRepository.unlink(linkID)
            loadSelectionDetails()
        }
    }

    /// The card at the other end of a link, for showing its tag and title.
    public func task(id: String) -> BoardTask? {
        snapshot?.columns.lazy.flatMap(\.tasks).first { $0.id == id }
            ?? snapshot?.backlog?.tasks.first { $0.id == id }
    }

    // MARK: Work log

    public func logWork(minutes: Int, note: String, on day: Date, taskID: String, billable: Bool = false) {
        perform {
            try cardDetailRepository.logWork(
                onTask: taskID,
                minutes: minutes,
                note: note,
                personID: currentPersonID,
                workedOn: day,
                billable: billable
            )
            timeRevision += 1
            loadSelectionDetails()
        }
    }

    public func deleteWorkLog(_ entryID: String) {
        perform {
            try cardDetailRepository.deleteWorkLog(entryID)
            loadSelectionDetails()
        }
    }

    public var loggedMinutes: Int { workLog.reduce(0) { $0 + $1.minutes } }

    /// Of which, billable.
    public var billableMinutes: Int { workLog.filter(\.billable).reduce(0) { $0 + $1.minutes } }

    // MARK: Badges

    public func commentCount(for task: BoardTask) -> Int { commentCounts[task.id] ?? 0 }

    public func attachmentCount(for task: BoardTask) -> Int { attachmentCounts[task.id] ?? 0 }

    private func reloadCounts() {
        guard let projectID = snapshot?.board.projectID else { return }
        guard let counts = try? cardDetailRepository.countsByTask(inProject: projectID) else { return }
        commentCounts = counts.comments
        attachmentCounts = counts.attachments
    }
}

// MARK: - Milestones 3 to 5

extension BoardViewModel {

    private var projectID: String? { snapshot?.board.projectID }

    // MARK: Custom fields

    public func customValues(for task: BoardTask) -> [String: CustomFieldValue] {
        customValues[task.id] ?? [:]
    }

    public func createCustomField(named name: String, kind: CustomFieldKind, options: [String] = []) {
        guard let projectID else { return }
        perform {
            try customFieldRepository.create(
                inProject: projectID, name: name, kind: kind, options: options
            )
            reloadSnapshot()
        }
    }

    public func renameCustomField(_ fieldID: String, to name: String) {
        perform {
            try customFieldRepository.rename(fieldID, to: name)
            reloadSnapshot()
        }
    }

    public func setCustomFieldOptions(_ options: [String], for fieldID: String) {
        perform {
            try customFieldRepository.setOptions(options, for: fieldID)
            reloadSnapshot()
        }
    }

    public func deleteCustomField(_ fieldID: String) {
        perform {
            try customFieldRepository.delete(fieldID)
            reloadSnapshot()
        }
    }

    /// Custom-field values are not card columns, so they sit outside the undo
    /// stack. Undo never claims to reverse what it cannot.
    public func setCustomValue(_ value: CustomFieldValue?, forField fieldID: String, on taskID: String) {
        perform {
            try customFieldRepository.setValue(value, forField: fieldID, onTask: taskID)
            reloadSnapshot()
        }
    }

    // MARK: Sprints

    public func createSprint(named name: String, goal: String, from start: Date?, to end: Date?) {
        guard let projectID else { return }
        perform {
            try sprintRepository.create(
                inProject: projectID, name: name, goal: goal, startsAt: start, endsAt: end
            )
            reloadSnapshot()
        }
    }

    public func updateSprint(_ sprintID: String, name: String, goal: String, from start: Date?, to end: Date?) {
        perform {
            try sprintRepository.update(sprintID, name: name, goal: goal, startsAt: start, endsAt: end)
            reloadSnapshot()
        }
    }

    public func startSprint(_ sprintID: String) {
        perform {
            try sprintRepository.start(sprintID)
            reloadSnapshot()
        }
    }

    /// Completing reports how much was carried, because "the sprint is done"
    /// and "four things did not fit" are two different pieces of news and the
    /// second is the one worth acting on.
    public func completeSprint(_ sprintID: String, carryingOverTo nextID: String?) {
        perform {
            let carried = try sprintRepository.complete(sprintID, carryingOverTo: nextID)
            carriedOverCount = carried
            reloadSnapshot()
        }
    }

    public func deleteSprint(_ sprintID: String) {
        perform {
            try sprintRepository.delete(sprintID)
            reloadSnapshot()
        }
    }

    public func setSprint(_ sprintID: String?, for taskID: String) {
        editing([taskID], "Set Sprint") {
            try sprintRepository.setSprint(sprintID, for: taskID)
        }
    }

    public func sprint(id: String?) -> Sprint? {
        guard let id else { return nil }
        return sprints.first { $0.id == id }
    }

    public func tasks(inSprint sprintID: String) -> [BoardTask] {
        (try? sprintRepository.tasks(inSprint: sprintID)) ?? []
    }

    public func burndown(for sprint: Sprint, points: Bool = true) -> [BurndownPoint] {
        (try? analyticsRepository.burndown(sprint: sprint, points: points)) ?? []
    }

    public func velocity() -> [SprintVelocity] {
        guard let projectID else { return [] }
        return (try? sprintRepository.velocity(inProject: projectID)) ?? []
    }

    // MARK: Workflow

    public var enforcesWorkflow: Bool {
        projects.first { $0.id == projectID }?.enforcesWorkflow ?? false
    }

    public func setWorkflowEnforced(_ enforced: Bool) {
        guard let projectID else { return }
        perform {
            try workflowRepository.setEnforced(enforced, inProject: projectID)
            load()
        }
    }

    public func setTransition(from: String, to: String, allowed: Bool) {
        guard let projectID else { return }
        perform {
            if allowed {
                try workflowRepository.allow(from: from, to: to, inProject: projectID)
            } else {
                try workflowRepository.forbid(from: from, to: to, inProject: projectID)
            }
            reloadSnapshot()
        }
    }

    public func seedWorkflow() {
        guard let projectID else { return }
        perform {
            try workflowRepository.seedSequentialTransitions(inProject: projectID)
            reloadSnapshot()
        }
    }

    public func permitsTransition(from: String, to: String) -> Bool {
        guard let projectID else { return true }
        return (try? workflowRepository.permits(from: from, to: to, inProject: projectID)) ?? true
    }

    // MARK: Automations

    public func createAutomation(
        named name: String,
        trigger: AutomationTrigger,
        triggerStatusID: String?,
        action: AutomationAction,
        actionValue: String
    ) {
        guard let projectID else { return }
        perform {
            try automationRepository.create(
                inProject: projectID, name: name, trigger: trigger,
                triggerStatusID: triggerStatusID, action: action, actionValue: actionValue
            )
            reloadSnapshot()
        }
    }

    public func setAutomationEnabled(_ enabled: Bool, for automationID: String) {
        perform {
            try automationRepository.setEnabled(enabled, for: automationID)
            reloadSnapshot()
        }
    }

    public func deleteAutomation(_ automationID: String) {
        perform {
            try automationRepository.delete(automationID)
            reloadSnapshot()
        }
    }

    // MARK: Templates

    public func saveCardTemplate(named name: String, from taskID: String) {
        guard let projectID, let task = task(id: taskID) else { return }
        perform {
            let payload = try templateRepository.cardTemplate(from: task)
            try templateRepository.saveCardTemplate(inProject: projectID, name: name, payload: payload)
            reloadSnapshot()
        }
    }

    public func createCard(from template: Template, titled title: String, inStatus statusID: String) {
        guard let projectID else { return }
        perform {
            try templateRepository.createCard(
                from: template, titled: title, inProject: projectID, statusID: statusID
            )
            reloadSnapshot()
        }
    }

    public func saveProjectTemplate(named name: String) {
        guard let projectID else { return }
        perform {
            let payload = try templateRepository.projectTemplate(from: projectID)
            try templateRepository.saveProjectTemplate(name: name, payload: payload)
            projectTemplates = try templateRepository.projectTemplates()
        }
    }

    public func createProject(from template: Template, named name: String, key: String) {
        guard let workspaceID = workspaces.first?.id else { return }
        perform {
            let project = try templateRepository.createProject(
                from: template, named: name, key: key, inWorkspace: workspaceID
            )
            load()
            selectedBoardID = try boardRepository.boards(inProject: project.id).first?.id
        }
    }

    public func deleteTemplate(_ templateID: String) {
        perform {
            try templateRepository.delete(templateID)
            reloadSnapshot()
            projectTemplates = try templateRepository.projectTemplates()
        }
    }

    // MARK: The timer

    public func isTiming(_ taskID: String) -> Bool { runningTimer?.taskID == taskID }

    public func startTimer(on taskID: String) {
        perform {
            try cardDetailRepository.startTimer(onTask: taskID, personID: currentPersonID)
            runningTimer = try cardDetailRepository.runningTimer()
            loadSelectionDetails()
        }
    }

    public func stopTimer(discarding: Bool = false) {
        perform {
            try cardDetailRepository.stopTimer(discarding: discarding)
            runningTimer = nil
            loadSelectionDetails()
            reloadSnapshot()
        }
    }

    /// The card the timer is running on, for the toolbar.
    public var timedTask: BoardTask? {
        guard let runningTimer else { return nil }
        return task(id: runningTimer.taskID)
    }

    // MARK: Due dates, for reminders and the menu bar

    /// Everything unfinished that is due on or before the end of today.
    ///
    /// The same question the menu bar asks and the reminders are built from,
    /// so the two can never disagree about what "due today" means.
    public func dueToday(now: Date = .now, calendar: Calendar = .current) -> [BoardTask] {
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return (snapshot?.columns.flatMap(\.tasks) ?? [])
            .filter { task in
                guard task.completedAt == nil, let due = task.dueDate else { return false }
                return due < endOfDay
            }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }
}
