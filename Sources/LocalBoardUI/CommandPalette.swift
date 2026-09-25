import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// ⌘K: one field that reaches every card and every action.
///
/// The ranking is the whole design. A palette that lists matches in database
/// order is a palette people stop using on the second try, so an exact prefix
/// beats a word beginning, which beats a match buried in the middle — and a
/// card's key beats its title, because someone typing WORK-14 knows exactly
/// what they want.
struct CommandPalette: View {

    let model: BoardViewModel
    var onOpenScreen: (BoardView.BoardScreen) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field

            Divider()

            if results.isEmpty {
                Text(query.isEmpty ? "Type to search cards and actions." : "Nothing matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                list
            }
        }
        .frame(width: 520)
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search cards, or type an action", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit(run)
                .onChange(of: query) { highlighted = 0 }
                .onKeyPress(.upArrow) {
                    highlighted = max(0, highlighted - 1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    highlighted = min(results.count - 1, highlighted + 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
        }
        .padding(14)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        row(result, isHighlighted: index == highlighted)
                            .id(result.id)
                            .onTapGesture {
                                highlighted = index
                                run()
                            }
                    }
                }
            }
            .frame(maxHeight: 320)
            .onChange(of: highlighted) {
                guard results.indices.contains(highlighted) else { return }
                proxy.scrollTo(results[highlighted].id)
            }
        }
    }

    private func row(_ result: PaletteResult, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.symbol)
                .foregroundStyle(isHighlighted ? .white : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .lineLimit(1)
                if let subtitle = result.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isHighlighted ? Color.accentColor : .clear)
        .foregroundStyle(isHighlighted ? .white : .primary)
        .contentShape(Rectangle())
    }

    private func run() {
        guard results.indices.contains(highlighted) else { return }
        results[highlighted].run()
        dismiss()
    }

    // MARK: - What it offers

    private var results: [PaletteResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        var found = actions.filter { $0.matches(trimmed) }
        found += cards(matching: trimmed)

        return Array(
            found.sorted { $0.score(for: trimmed) > $1.score(for: trimmed) }.prefix(40)
        )
    }

    private func cards(matching query: String) -> [PaletteResult] {
        let tasks = model.visibleColumns.flatMap(\.tasks)
            + (model.snapshot?.backlog?.tasks ?? [])

        return tasks.compactMap { task in
            let tag = model.tag(for: task)
            let haystack = "\(tag) \(task.title)"
            guard query.isEmpty || haystack.localizedCaseInsensitiveContains(query) else { return nil }

            return PaletteResult(
                id: task.id,
                title: task.title,
                subtitle: "\(tag) · \(model.statusName(task.statusID))",
                symbol: task.flagged ? "flag.fill" : "square.text.square",
                keywords: haystack
            ) {
                model.selectedTaskID = task.id
            }
        }
    }

    private var actions: [PaletteResult] {
        var list: [PaletteResult] = [
            PaletteResult(id: "screen-board", title: "Go to Board", symbol: "rectangle.split.3x1",
                          keywords: "board columns") { onOpenScreen(.board) },
            PaletteResult(id: "screen-list", title: "Go to List", symbol: "list.bullet.rectangle",
                          keywords: "list table sort group") { onOpenScreen(.list) },
            PaletteResult(id: "screen-calendar", title: "Go to Calendar", symbol: "calendar",
                          keywords: "calendar month due dates") { onOpenScreen(.calendar) },
            PaletteResult(id: "screen-table", title: "Go to Table", symbol: "tablecells",
                          keywords: "table spreadsheet grid csv") { onOpenScreen(.table) },
            PaletteResult(id: "screen-workload", title: "Go to Workload",
                          symbol: "gauge.with.dots.needle.67percent",
                          keywords: "workload capacity who busy") { onOpenScreen(.workload) },
            PaletteResult(id: "screen-box", title: "Go to Box", symbol: "square.grid.2x2",
                          keywords: "box by assignee people") { onOpenScreen(.box) },
            PaletteResult(id: "screen-mindmap", title: "Go to Mind Map",
                          symbol: "point.3.connected.trianglepath.dotted",
                          keywords: "mind map graph nodes tree") { onOpenScreen(.mindMap) },
            PaletteResult(id: "screen-activity", title: "Go to Activity",
                          symbol: "clock.arrow.circlepath",
                          keywords: "activity history feed changes") { onOpenScreen(.activity) },
            PaletteResult(id: "screen-everything", title: "Go to Everything", symbol: "globe",
                          keywords: "everything all spaces") { onOpenScreen(.everything) },
            PaletteResult(id: "screen-backlog", title: "Go to Backlog", symbol: "tray.2",
                          keywords: "backlog waiting") { onOpenScreen(.backlog) },
            PaletteResult(id: "screen-timeline", title: "Go to Timeline", symbol: "chart.bar.xaxis",
                          keywords: "timeline gantt schedule dates") { onOpenScreen(.timeline) },
            PaletteResult(id: "screen-sprints", title: "Go to Sprints", symbol: "figure.run",
                          keywords: "sprint burndown velocity") { onOpenScreen(.sprints) },
            PaletteResult(id: "screen-releases", title: "Go to Releases", symbol: "shippingbox",
                          keywords: "release version ship") { onOpenScreen(.releases) },
            PaletteResult(id: "screen-analytics", title: "Go to Analytics", symbol: "chart.xyaxis.line",
                          keywords: "analytics charts flow cycle time") { onOpenScreen(.analytics) },
            PaletteResult(id: "clear", title: "Clear All Filters", symbol: "xmark.circle",
                          keywords: "clear filters reset") { model.clearFilters() },
            PaletteResult(id: "select-all", title: "Select All Cards", symbol: "checklist",
                          keywords: "select all") { model.pickAll() },
        ]

        // Only offered when there is something to do: a palette full of greyed
        // possibilities is a palette you have to read rather than scan.
        if model.canUndo {
            list.append(PaletteResult(
                id: "undo", title: "Undo \(model.undoLabel ?? "")",
                symbol: "arrow.uturn.backward", keywords: "undo") { model.undo() }
            )
        }
        if model.canRedo {
            list.append(PaletteResult(
                id: "redo", title: "Redo \(model.redoLabel ?? "")",
                symbol: "arrow.uturn.forward", keywords: "redo") { model.redo() }
            )
        }
        if let timed = model.timedTask {
            list.append(PaletteResult(
                id: "stop-timer", title: "Stop Timer on \(model.tag(for: timed))",
                symbol: "stopwatch", keywords: "stop timer time") { model.stopTimer() }
            )
        }

        for filter in model.quickFilters {
            list.append(PaletteResult(
                id: "filter-\(filter.id)",
                title: "Filter: \(filter.name)",
                subtitle: filter.query,
                symbol: "line.3.horizontal.decrease.circle",
                keywords: "filter \(filter.name)"
            ) { model.toggleQuickFilter(filter.id) })
        }

        for view in model.savedViews {
            list.append(PaletteResult(
                id: "view-\(view.id)",
                title: "View: \(view.name)",
                subtitle: view.query,
                symbol: "bookmark",
                keywords: "view \(view.name)"
            ) { model.apply(view) })
        }

        return list
    }
}

/// One line of the palette.
struct PaletteResult: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let symbol: String
    let keywords: String
    let run: () -> Void

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbol: String,
        keywords: String,
        run: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.keywords = keywords
        self.run = run
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || keywords.localizedCaseInsensitiveContains(query)
            || title.localizedCaseInsensitiveContains(query)
    }

    /// Higher is better. An exact prefix beats a word beginning, which beats a
    /// match buried in the middle — the order somebody typing expects to see.
    func score(for query: String) -> Int {
        guard !query.isEmpty else { return 0 }

        let lowered = title.lowercased()
        let needle = query.lowercased()

        if lowered == needle { return 100 }
        if lowered.hasPrefix(needle) { return 80 }
        if lowered.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 60 }
        if lowered.contains(needle) { return 40 }
        if keywords.lowercased().contains(needle) { return 20 }
        return 0
    }
}
