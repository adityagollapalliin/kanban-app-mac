import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The issue navigator: a filter, its results, and one card beside them.
///
/// A split view rather than a page per card, because the navigator is what you
/// use when you are working *through* a list — triaging bugs, checking a
/// release — and going back and forth to a full page for each one is the thing
/// that makes that tedious.
struct NavigatorView: View {

    let model: BoardViewModel

    @State private var selectedViewID: String?
    @State private var query = ""
    @State private var syntax: QuerySyntax = .simple
    @State private var selectedTaskID: String?
    @State private var isNaming = false
    @State private var newName = ""
    @State private var converting: SavedView?

    /// The default columns, when a filter has not chosen its own.
    private static let defaultColumns = ["key", "title", "status", "assignee", "due"]

    private var chosenView: SavedView? {
        model.savedViews.first { $0.id == selectedViewID }
    }

    private var columns: [String] {
        let chosen = chosenView?.columns ?? []
        return chosen.isEmpty ? Self.defaultColumns : chosen
    }

    /// What the navigator is showing: the saved filter if one is selected,
    /// otherwise whatever is typed in the bar.
    private var results: [BoardTask] {
        if let chosenView { return model.tasks(matching: chosenView) }
        guard let projectID = model.currentProjectID else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.visibleTasks }
        return (try? model.taskRepository.tasks(
            matching: trimmed, inProject: projectID, syntax: syntax
        )) ?? []
    }

    var body: some View {
        // The bar stacked above rather than as a safe-area inset: an
        // HSplitView takes all the height it is offered and an inset on it
        // lands halfway down the window, with the list squashed underneath.
        VStack(spacing: 0) {
            bar
            HSplitView {
                // Both halves told to fill: given only a width, an HSplitView
                // lets a child size to its content and settles it against the
                // bottom, which puts the table in the floor of the window.
                list
                    .frame(minWidth: 400, idealWidth: 520, maxHeight: .infinity)
                detail
                    .frame(minWidth: 260, idealWidth: 320, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle(chosenView?.name ?? "Navigator")
        .sheet(item: $converting) { view in
            ConversionSheet(view: view, model: model)
        }
        .alert("Save this filter", isPresented: $isNaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                model.createSavedView(named: newName, query: query, syntax: syntax)
            }
        } message: {
            Text("Saved as \(syntax.label.lowercased()), which is the language it is written in.")
        }
    }

    // MARK: The query bar

    private var bar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Basic and advanced are two languages rather than two
                // spellings, so this switches which parser reads the box —
                // and never rewrites what is in it.
                Picker("", selection: $syntax) {
                    ForEach(QuerySyntax.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .disabled(chosenView != nil)

                TextField(
                    syntax == .jql
                        ? "priority IN (high, highest) ORDER BY due"
                        : "due < +7d  priority >= high  is:flagged",
                    text: $query
                )
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .disabled(chosenView != nil)
                .onSubmit { selectedViewID = nil }

                if chosenView == nil {
                    Button("Save…") { newName = ""; isNaming = true }
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            HStack(spacing: 8) {
                savedFilters

                Spacer()

                if let problem = model.problem(with: query, syntax: syntax), chosenView == nil {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text("\(results.count) card\(results.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var savedFilters: some View {
        HStack(spacing: 6) {
            Button {
                selectedViewID = nil
            } label: {
                Text("Everything")
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(selectedViewID == nil ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary),
                                in: Capsule())
            }
            .buttonStyle(.plain)

            // Starred first, because they are the ones kept to hand.
            ForEach(model.savedViews.sorted { ($0.starred ? 0 : 1) < ($1.starred ? 0 : 1) }) { view in
                Button {
                    selectedViewID = view.id
                } label: {
                    HStack(spacing: 3) {
                        if view.starred {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                        }
                        Text(view.name).font(.caption)
                        if view.syntax == .jql {
                            Text("JQL")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(selectedViewID == view.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary),
                                in: Capsule())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(view.starred ? "Unstar" : "Star") {
                        model.setStarred(!view.starred, for: view.id)
                    }
                    Divider()
                    Button("Convert to \(view.syntax == .simple ? "advanced" : "basic")…") {
                        converting = view
                    }
                }
            }
        }
    }

    // MARK: The list

    private var list: some View {
        Table(results, selection: Binding(
            get: { selectedTaskID.map { Set([$0]) } ?? [] },
            set: { selectedTaskID = $0.first }
        )) {
            TableColumn("Key") { task in
                Text(model.tag(for: task))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)

            // A minimum as well as an ideal: without one the title is the
            // column that gives way when the others are satisfied, and it
            // collapses to an ellipsis — which is the one column nobody can
            // read the list without.
            TableColumn("Title") { task in
                HStack(spacing: 5) {
                    Image(systemName: model.typeSymbol(for: task))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(task.title).lineLimit(1)
                }
            }
            .width(min: 140, ideal: 220)

            TableColumn("Status") { task in
                Text(model.columnName(for: task) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 95)

            TableColumn("Assignee") { task in
                Text(model.person(id: task.assigneeID)?.name ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Due") { task in
                Text(task.dueDate?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(task.dueDate.map { $0 < Date() && task.completedAt == nil } == true
                                     ? .orange : .secondary)
            }
            .width(min: 80, ideal: 90)
        }
        .tableStyle(.inset)
    }

    // MARK: The card beside it

    @ViewBuilder
    private var detail: some View {
        if let id = selectedTaskID, let task = results.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: model.typeSymbol(for: task))
                            .foregroundStyle(.secondary)
                        Text(model.tag(for: task))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open", systemImage: "arrow.up.forward.square") {
                            model.selectedTaskID = task.id
                        }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .help("Open this card in the inspector")
                    }

                    Text(task.title).font(.title3.weight(.medium))

                    LabeledContent("Kind", value: model.typeName(for: task))
                    LabeledContent("Status", value: model.columnName(for: task) ?? "")
                    LabeledContent("Priority", value: model.priorityName(for: task))
                    if let assignee = model.person(id: task.assigneeID) {
                        LabeledContent("Assignee", value: assignee.name)
                    }
                    if let due = task.dueDate {
                        LabeledContent("Due", value: due.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let resolution = model.resolution(for: task) {
                        LabeledContent("Resolution", value: resolution.name)
                    }

                    if !task.descriptionMarkdown.isEmpty {
                        Divider()
                        Text(task.descriptionMarkdown)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "No card selected",
                systemImage: "sidebar.right",
                description: Text("Pick one on the left to see it here.")
            )
        }
    }
}

/// What converting a filter to the other language would do, before it does it.
struct ConversionSheet: View {

    let view: SavedView
    let model: BoardViewModel

    @Environment(\.dismiss) private var dismiss

    private var target: QuerySyntax { view.syntax == .simple ? .jql : .simple }

    var body: some View {
        let preview = model.previewConversion(view.id, to: target)

        VStack(alignment: .leading, spacing: 12) {
            Text("Convert “\(view.name)” to \(target.label.lowercased())")
                .font(.headline)

            Text(view.query)
                .font(.callout.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            if let preview {
                if let problem = preview.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if preview.resultsChange {
                    // The part nobody expects: it parses in both languages and
                    // means different things in each.
                    Label(
                        "This filter matches \(preview.matchesBefore) card\(preview.matchesBefore == 1 ? "" : "s") now and would match \(preview.matchesAfter) after converting.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(
                        "It matches the same \(preview.matchesBefore) card\(preview.matchesBefore == 1 ? "" : "s") either way.",
                        systemImage: "checkmark.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.green)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Convert") {
                    model.convert(view.id, to: target)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview?.parses != true)
            }
        }
        .padding()
        .frame(width: 440)
    }
}
