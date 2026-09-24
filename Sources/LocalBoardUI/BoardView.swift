import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The board: projects down the side, columns across the middle.
struct BoardView: View {

    @Bindable var model: BoardViewModel
    let externalChangeCount: Int

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

    private var sidebar: some View {
        List(selection: $model.selectedBoardID) {
            ForEach(model.projects) { project in
                Section {
                    ForEach(model.boards.filter { $0.projectID == project.id }) { board in
                        Label(board.name, systemImage: "rectangle.split.3x1")
                            .tag(board.id)
                            .contextMenu {
                                Button("Rename Board…") {
                                    renamedBoardName = board.name
                                    renamingBoardID = board.id
                                }
                                Button("Delete Board", systemImage: "trash", role: .destructive) {
                                    model.deleteBoard(board.id)
                                }
                                .disabled(model.boards.filter { $0.projectID == project.id }.count < 2)
                            }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(project.name)
                        Text(project.key)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .contextMenu {
                        Button("New Board…") {
                            newBoardName = ""
                            boardParentProject = project.id
                            isAddingBoard = true
                        }
                        Divider()
                        Button("Delete Project", systemImage: "trash", role: .destructive) {
                            model.deleteProject(project.id)
                        }
                    }
                }
            }

            Section("Views") {
                ForEach(model.savedViews) { view in
                    savedViewRow(view)
                }

                // Built in, because the trash has to be reachable by someone
                // who has never heard of `is:trashed`.
                trashRow
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    newProjectName = ""
                    newProjectKey = ""
                    isAddingProject = true
                } label: {
                    Label("New Project", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var trashRow: some View {
        let isActive = model.queryText == Self.trashQuery

        return Button {
            model.queryText = isActive ? "" : Self.trashQuery
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "trash.fill" : "trash")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text("Trash")
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Cards you have thrown away. Nothing is deleted; they can be put back.")
    }

    private static let trashQuery = "is:trashed"

    /// A view is a button rather than a selectable row: opening one changes
    /// the filter, not which board is on screen.
    private func savedViewRow(_ view: SavedView) -> some View {
        let isActive = model.queryText == view.query

        return Button {
            model.apply(view)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle\(isActive ? ".fill" : "")")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(view.name)
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(view.query)
        .accessibilityHint("Filters the board by: \(view.query)")
        .contextMenu {
            Button("Delete View", systemImage: "trash", role: .destructive) {
                model.deleteSavedView(view.id)
            }
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

            if let snapshot = model.snapshot {
                board(snapshot)
            } else {
                ContentUnavailableView(
                    "No board selected",
                    systemImage: "rectangle.3.group",
                    description: Text("Pick a board in the sidebar.")
                )
            }
        }
        .navigationTitle(model.snapshot?.board.name ?? AppIdentity.displayName)
        .navigationSubtitle(subtitle)
        .searchable(
            text: $model.queryText,
            placement: .toolbar,
            prompt: "due < +7d   priority >= high   is:overdue"
        )
        .toolbar {
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
        .sheet(isPresented: $isNamingView) { namingSheet }
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
    }

    /// Sits where the next column would be, which is where someone looks for
    /// it — rather than in a menu they would have to go hunting through.
    private var addColumnButton: some View {
        Button {
            newColumnName = ""
            isAddingColumn = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.title3)
                Text("Add Column")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(width: 160)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
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
        guard model.snapshot != nil else { return "" }
        let total = model.totalTaskCount

        guard model.isFiltering else {
            return total == 1 ? "1 card" : "\(total) cards"
        }
        return "\(model.visibleTaskCount) of \(total) cards"
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

    private func board(_ snapshot: BoardSnapshot) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(model.visibleColumns) { column in
                    BoardColumnView(column: column, model: model)
                }

                addColumnButton
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
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
