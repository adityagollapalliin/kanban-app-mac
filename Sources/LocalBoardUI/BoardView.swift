import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The board: projects down the side, columns across the middle.
struct BoardView: View {

    @Bindable var model: BoardViewModel
    let externalChangeCount: Int

    @State private var isNamingView = false
    @State private var newViewName = ""

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
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(project.name)
                        Text(project.key)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !model.savedViews.isEmpty {
                Section("Views") {
                    ForEach(model.savedViews) { view in
                        savedViewRow(view)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

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
                Button("Save View", systemImage: "bookmark") {
                    newViewName = ""
                    isNamingView = true
                }
                .disabled(!model.canSaveCurrentQuery)
                .help(model.canSaveCurrentQuery
                      ? "Keep this query under a name"
                      : "Type a query to save it as a view")
            }
        }
        .sheet(isPresented: $isNamingView) { namingSheet }
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
