import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The board: projects down the side, columns across the middle.
struct BoardView: View {

    @Bindable var model: BoardViewModel
    let externalChangeCount: Int

    @Environment(\.openWindow) private var openWindow
    @Environment(AppEnvironment.self) private var environment

    @State private var isNamingView = false
    @State private var newViewName = ""

    @State private var isAddingColumn = false
    @State private var newColumnName = ""

    @State private var isAddingProject = false
    @State private var newProjectName = ""
    @State private var newProjectKey = ""

    @State private var isAddingBoard = false
    @State private var newBoardName = ""
    @State private var boardParentProject: String?

    @State private var renamingBoardID: String?
    @State private var renamedBoardName = ""

    @State private var isEditingSwimlanes = false
    @State private var screen: BoardScreen = .board
    @State private var isEditingBoardQuery = false
    @State private var boardQuery = ""
    @State private var isShowingPalette = false
    @State private var isShowingProjectSettings = false
    @State private var isNamingTemplate = false
    @State private var newTemplateName = ""

    /// Which of the board's screens is showing. The same cards as columns, as
    /// a table, against a month and against a timeline; the work waiting to
    /// start, the releases it is going into, and what the history says about
    /// all of it — views of one project rather than a set of places.
    enum BoardScreen: String, CaseIterable, Identifiable {
        case home, board, list, table, calendar, timeline, workload, box, mindMap, backlog, sprints, releases, activity, analytics, dashboards, goals, timesheet, timeInStatus, everything, reminders, notepad, docs, whiteboard
        var id: String { rawValue }

        var label: String {
            switch self {
            case .home: "My Work"
            case .board: "Board"
            case .list: "List"
            case .table: "Table"
            case .calendar: "Calendar"
            case .workload: "Workload"
            case .box: "Box"
            case .mindMap: "Mind Map"
            case .activity: "Activity"
            case .everything: "Everything"
            case .reminders: "Reminders"
            case .notepad: "Notepad"
            case .docs: "Docs"
            case .whiteboard: "Whiteboard"
            case .backlog: "Backlog"
            case .timeline: "Timeline"
            case .sprints: "Sprints"
            case .releases: "Releases"
            case .analytics: "Analytics"
            case .dashboards: "Dashboards"
            case .goals: "Goals"
            case .timesheet: "Timesheet"
            case .timeInStatus: "Time in Status"
            }
        }

        /// Whether the quick filters belong above this screen. They do wherever
        /// the screen is showing the board's own cards.
        var showsFilters: Bool {
            switch self {
            case .board, .list, .table, .calendar, .box, .mindMap, .everything: true
            default: false
            }
        }

        var symbol: String {
            switch self {
            case .home: "sun.max"
            case .board: "rectangle.split.3x1"
            case .list: "list.bullet.rectangle"
            case .table: "tablecells"
            case .calendar: "calendar"
            case .workload: "gauge.with.dots.needle.67percent"
            case .box: "square.grid.2x2"
            case .mindMap: "point.3.connected.trianglepath.dotted"
            case .activity: "clock.arrow.circlepath"
            case .everything: "globe"
            case .reminders: "bell"
            case .notepad: "note.text"
            case .docs: "doc.text"
            case .whiteboard: "rectangle.dashed"
            case .backlog: "tray.2"
            case .timeline: "chart.bar.xaxis"
            case .sprints: "figure.run"
            case .releases: "shippingbox"
            case .analytics: "chart.xyaxis.line"
            case .dashboards: "square.grid.2x2"
            case .goals: "target"
            case .timesheet: "tablecells.badge.ellipsis"
            case .timeInStatus: "clock.arrow.2.circlepath"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail
        }
        .inspector(isPresented: inspectorShown) {
            if let task = model.selectedTask {
                TaskDetailView(task: task, model: model)
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
            } else {
                ContentUnavailableView("No card selected", systemImage: "square.text.square")
            }
        }
        .task { model.load() }
        // Due dates change as cards are edited, so the scheduled reminders are
        // rewritten whenever the board is.
        .onChange(of: model.snapshot?.taskCount) { environment.refreshReminders() }
        // Another process wrote to the same file. AppEnvironment notices on
        // activation and bumps the counter; this is where the board catches up.
        .onChange(of: externalChangeCount) { model.load() }
    }

    /// The inspector is open exactly when a card is selected, so closing it
    /// and deselecting are the same action rather than two states that can
    /// disagree.
    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { model.selectedTaskID != nil },
            set: { shown in if !shown { model.selectedTaskID = nil } }
        )
    }

    // MARK: - Sidebar

    /// Spaces, folders, lists and shortcuts. Its own file, because a sidebar
    /// that draws four levels and five kinds of shortcut is a screen rather
    /// than a detail of this one.
    private var sidebar: some View {
        SpaceSidebar(model: model) {
            newProjectName = ""
            newProjectKey = ""
            isAddingProject = true
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if let failure = model.failure {
                failureBanner(failure)
            }

            if let incomplete = model.queryFailure {
                queryHint(incomplete)
            }

            if model.snapshot != nil {
                // The board, the list and the calendar are the same cards, so
                // the filters that apply to one apply to all three.
                if screen.showsFilters { QuickFilterBar(model: model) }
                currentScreen
            } else {
                ContentUnavailableView(
                    "No board selected",
                    systemImage: "rectangle.3.group",
                    description: Text("Pick a board in the sidebar.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if !model.trayTaskIDs.isEmpty { TaskTray(model: model) }
                if model.hasSelection { BulkActionBar(model: model) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.hasSelection)
        .navigationTitle(model.snapshot?.board.name ?? AppIdentity.displayName)
        .navigationSubtitle(subtitle)
        .searchable(
            text: $model.queryText,
            placement: .toolbar,
            prompt: "due < +7d   priority >= high   is:flagged   days >= 5"
        )
        .toolbar { toolbarContent }
        .sheet(isPresented: $isNamingView) { namingSheet }
        .sheet(isPresented: $isEditingSwimlanes) { SwimlaneEditor(model: model) }
        .sheet(isPresented: $isShowingProjectSettings) { ProjectSettingsView(model: model) }
        .sheet(isPresented: $isShowingPalette) {
            CommandPalette(model: model) { screen = $0 }
        }
        .alert("Save as template", isPresented: $isNamingTemplate) {
            TextField("Name", text: $newTemplateName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let taskID = model.selectedTaskID {
                    model.saveCardTemplate(named: newTemplateName, from: taskID)
                }
            }
        } message: {
            Text("Keeps this card's type, priority, notes, labels and checklist — not its title.")
        }
        // The palette and undo are wired here rather than only in the menu bar,
        // so they work whichever window has focus.
        .onKeyPress(.init("k"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            isShowingPalette = true
            return .handled
        }
        .alert("Sprint completed", isPresented: carriedOverShown) {
            Button("OK", role: .cancel) { model.carriedOverCount = nil }
        } message: {
            Text(carriedOverMessage)
        }
        .alert("New column", isPresented: $isAddingColumn) {
            TextField("Name", text: $newColumnName)
            Button("Cancel", role: .cancel) {}
            Button("Add") { model.addColumn(named: newColumnName) }
        } message: {
            Text("It starts as a to-do column. Change that from the column's menu.")
        }
        .alert("New project", isPresented: $isAddingProject) {
            TextField("Name", text: $newProjectName)
            TextField("Key, like WORK", text: $newProjectKey)
            Button("Cancel", role: .cancel) {}
            Button("Create") { model.createProject(named: newProjectName, key: newProjectKey) }
        } message: {
            Text("The key goes in front of every card number in the project.")
        }
        .alert("New board", isPresented: $isAddingBoard) {
            TextField("Name", text: $newBoardName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                if let projectID = boardParentProject {
                    model.createBoard(named: newBoardName, inProject: projectID)
                }
            }
        } message: {
            Text("A second board over the same project, showing the same cards.")
        }
        .alert("Rename board", isPresented: Binding(
            get: { renamingBoardID != nil },
            set: { if !$0 { renamingBoardID = nil } }
        )) {
            TextField("Name", text: $renamedBoardName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let boardID = renamingBoardID { model.renameBoard(boardID, to: renamedBoardName) }
            }
        }
        .alert("Board from a query", isPresented: $isEditingBoardQuery) {
            TextField("Query, or empty for the whole project", text: $boardQuery)
            Button("Cancel", role: .cancel) {}
            Button("Apply") { model.setBoardQuery(boardQuery) }
        } message: {
            Text("A board defined by a question gathers whatever answers it, from every project rather than one.")
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch screen {
        case .board:
            BoardCanvas(model: model, onOpenInWindow: openInWindow) {
                newColumnName = ""
                isAddingColumn = true
            }
        case .home:
            HomeView(model: model, onOpenInWindow: openInWindow)
        case .reminders:
            RemindersView(model: model)
        case .notepad:
            NotepadView(model: model)
        case .docs:
            DocsView(model: model, onOpenInWindow: openInWindow)
        case .whiteboard:
            WhiteboardView(model: model)
        case .list:
            ListView(model: model, onOpenInWindow: openInWindow)
        case .table:
            TableView(model: model)
        case .calendar:
            CalendarView(model: model, onOpenInWindow: openInWindow)
        case .workload:
            WorkloadView(model: model)
        case .box:
            BoxView(model: model)
        case .mindMap:
            MindMapView(model: model, onOpenInWindow: openInWindow)
        case .activity:
            ActivityView(model: model)
        case .everything:
            EverythingView(model: model, onOpenInWindow: openInWindow)
        case .backlog:
            BacklogView(model: model, onOpenInWindow: openInWindow) { screen = .board }
        case .timeline:
            TimelineView(model: model, onOpenInWindow: openInWindow)
        case .sprints:
            SprintsView(model: model)
        case .releases:
            ReleasesView(model: model)
        case .analytics:
            AnalyticsView(model: model)
        case .dashboards:
            DashboardsView(model: model)
        case .goals:
            GoalsView(model: model)
        case .timesheet:
            TimesheetView(model: model)
        case .timeInStatus:
            TimeInStatusView(model: model)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // A menu rather than a segmented control: thirteen segments is a
            // row of unlabelled icons nobody can tell apart, and the name of
            // the view you are in is worth more than a saved click.
            Menu {
                ForEach(BoardScreen.allCases) { option in
                    Button {
                        screen = option
                    } label: {
                        if screen == option {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Label(option.label, systemImage: option.symbol)
                        }
                    }
                }
            } label: {
                Label(screen.label, systemImage: screen.symbol)
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which view of this work to show")
        }

        if let timed = model.timedTask {
            ToolbarItem(placement: .primaryAction) {
                TimerToolbarItem(task: timed, model: model)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            BoardSettingsMenu(model: model)
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Command Palette…", systemImage: "magnifyingglass") {
                    isShowingPalette = true
                }
                .keyboardShortcut("k")

                Divider()

                Button("Project Settings…", systemImage: "gearshape") {
                    isShowingProjectSettings = true
                }
                Button("Edit Swimlanes…", systemImage: "arrow.left.and.right.text.vertical") {
                    isEditingSwimlanes = true
                }
                Button("Board From a Query…", systemImage: "line.3.horizontal.decrease.circle") {
                    boardQuery = model.snapshot?.board.filterQuery ?? ""
                    isEditingBoardQuery = true
                }
                Divider()

                if !model.cardTemplates.isEmpty {
                    Menu("New Card From Template") {
                        ForEach(model.cardTemplates) { template in
                            Button(template.name) {
                                if let column = model.visibleColumns.first {
                                    model.createCard(
                                        from: template,
                                        titled: "New \(template.name)",
                                        inStatus: column.status.id
                                    )
                                }
                            }
                        }
                    }
                }
                Button("Save Card as Template…", systemImage: "doc.on.doc") {
                    newTemplateName = ""
                    isNamingTemplate = true
                }
                .disabled(model.selectedTaskID == nil)
                .help("Open a card first")

                Divider()
                Button("Select All Cards", systemImage: "checklist") { model.pickAll() }
                    .disabled(model.visibleTaskCount == 0)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                newViewName = ""
                isNamingView = true
            } label: {
                // Spelled out, not just the icon: a toolbar bookmark glyph
                // on its own is a rebus, and this is not an action anyone
                // can guess from a symbol.
                Label("Save View", systemImage: "bookmark")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canSaveCurrentQuery)
            .help(model.canSaveCurrentQuery
                  ? "Keep this query under a name"
                  : "Type a query to save it as a view")
        }
    }

    private var namingSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save this view")
                .font(.headline)

            // The query is shown, not hidden behind the name: a view is a
            // question, and it should be obvious which one is being kept.
            Text(model.queryText)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)

            TextField("Name", text: $newViewName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveView)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isNamingView = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: saveView)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newViewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func saveView() {
        let name = newViewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.saveCurrentQuery(named: name)
        isNamingView = false
    }

    private var subtitle: String {
        guard let snapshot = model.snapshot else { return "" }
        let total = model.totalTaskCount

        var parts: [String] = []
        if model.isFiltering {
            parts.append("\(model.visibleTaskCount) of \(total) cards")
        } else {
            parts.append(total == 1 ? "1 card" : "\(total) cards")
        }

        // A board defined by a query is a different kind of board, and the
        // subtitle is where that belongs — it explains why cards from other
        // projects are on screen.
        if snapshot.board.isQueryBoard { parts.append("from a query") }
        if snapshot.board.swimlaneMode != .none {
            parts.append("by \(snapshot.board.swimlaneMode.label.lowercased())")
        }
        return parts.joined(separator: " · ")
    }

    private var carriedOverShown: Binding<Bool> {
        Binding(
            get: { model.carriedOverCount != nil },
            set: { if !$0 { model.carriedOverCount = nil } }
        )
    }

    private var carriedOverMessage: String {
        let count = model.carriedOverCount ?? 0
        guard count > 0 else { return "Everything in the sprint was finished." }
        return count == 1
            ? "One card was unfinished and has been carried over."
            : "\(count) cards were unfinished and have been carried over."
    }

    /// ⌥-click, or the card's menu: the card in a window of its own, so two
    /// cards can be read side by side.
    private func openInWindow(_ taskID: String) {
        openWindow(id: TaskWindow.identifier, value: taskID)
    }

    /// A query still being typed is not an error to apologise for. It is said
    /// quietly, and the last good result stays on screen underneath.
    private func queryHint(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// A failed action says what failed and what to do, and goes away when the
    /// next one succeeds.
    private func failureBanner(_ error: LocalBoardError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(error.errorDescription ?? "Something went wrong.")
                    .font(.callout.weight(.medium))
                if let suggestion = error.recoverySuggestion ?? error.failureReason {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button("Dismiss") { model.dismissFailure() }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeOut(duration: 0.2), value: model.failure)
    }
}
