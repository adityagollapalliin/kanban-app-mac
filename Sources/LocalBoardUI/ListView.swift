import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The same cards as a table: sortable by any column, grouped by anything the
/// board already knows how to group by.
///
/// A list is what a board is bad at. A board answers "what is in flight"; a
/// list answers "everything due this month, oldest first" — a question the
/// board can only answer by making someone read every column. So the list
/// shows the same filtered set the board does, and differs only in shape.
struct ListView: View {

    let model: BoardViewModel
    var onOpenInWindow: ((String) -> Void)?

    @State private var sortOrder = [KeyPathComparator(\ListRow.number)]
    @State private var grouping: Grouping = .none
    @State private var selection: Set<String> = []

    /// What the rows are cut into. Every one of these is something the card
    /// already carries, so no grouping can produce a row that belongs nowhere
    /// — the ones that can be empty get a "None" group rather than vanishing.
    enum Grouping: String, CaseIterable, Identifiable {
        case none, status, assignee, priority, type, epic, sprint
        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: "No Grouping"
            case .status: "Status"
            case .assignee: "Assignee"
            case .priority: "Priority"
            case .type: "Type"
            case .epic: "Epic"
            case .sprint: "Sprint"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            table
        }
        .onChange(of: selection) { _, new in applySelection(new) }
        .onChange(of: model.selectedTaskID) { _, new in
            // The inspector and the table agree about what is open, whichever
            // one was used to change it — including the command palette.
            if let new, !selection.contains(new) { selection = [new] }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Group by", selection: $grouping) {
                ForEach(Grouping.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Group the list by")

            Spacer(minLength: 0)

            Text(countLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(countLabel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var countLabel: String {
        let shown = rows.count
        let total = model.totalTaskCount
        guard model.isFiltering, shown != total else {
            return "\(shown) card\(shown == 1 ? "" : "s")"
        }
        return "\(shown) of \(total) cards"
    }

    // MARK: - The table

    /// The widths are deliberately tight. A table whose columns add up to
    /// more than the window puts the last ones past the edge, where they
    /// cannot be reached — so the default has to fit the smallest sensible
    /// window, and the user widens from there.
    private var table: some View {
        Table(of: ListRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Key", value: \.number) { row in
                Text(row.key)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 72, max: 100)

            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 6) {
                    Image(systemName: CardAppearance.symbol(forType: row.task.type))
                        .font(.caption)
                        .foregroundStyle(CardAppearance.color(forType: row.task.type))
                        .help(CardAppearance.label(forType: row.task.type))
                        .accessibilityHidden(true)

                    Text(row.title)
                        .lineLimit(1)
                        .strikethrough(row.task.trashed)

                    if row.task.flagged {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .help(row.task.flagReason.isEmpty ? "Flagged" : row.task.flagReason)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(accessibilityLabel(for: row))
            }
            .width(min: 140, ideal: 240)

            TableColumn("Status", value: \.status) { row in
                Text(row.status).foregroundStyle(.secondary)
            }
            .width(min: 72, ideal: 104, max: 180)

            TableColumn("Priority", value: \.priorityRank) { row in
                Label(row.priority, systemImage: CardAppearance.symbol(forPriority: row.task.priority))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(CardAppearance.color(forPriority: row.task.priority))
            }
            .width(min: 70, ideal: 86, max: 120)

            TableColumn("Assignee", value: \.assignee) { row in
                Text(row.assignee.isEmpty ? "—" : row.assignee)
                    .foregroundStyle(row.assignee.isEmpty ? .secondary : .primary)
            }
            .width(min: 72, ideal: 104, max: 180)

            TableColumn("Due", value: \.dueSort) { row in
                Text(row.due)
                    .foregroundStyle(row.isOverdue ? .red : .secondary)
                    .help(row.isOverdue ? "Overdue" : "")
            }
            .width(min: 70, ideal: 92, max: 130)

            TableColumn("Points", value: \.points) { row in
                Text(row.pointsLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 46, ideal: 54, max: 80)

            TableColumn("Days", value: \.days) { row in
                Text("\(row.days)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(row.days >= model.staleDays ? .orange : .secondary)
                    .help("Days in its current column")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 42, ideal: 50, max: 70)
        } rows: {
            if grouping == .none {
                ForEach(rows) { TableRow($0) }
            } else {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.rows) { TableRow($0) }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            // Double-click: the list's version of ⌥-clicking a card.
            if let id = ids.first { onOpenInWindow?(id) }
        }
        .tableStyle(.inset)
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<String>) -> some View {
        if ids.count == 1, let id = ids.first {
            Button("Open in a Window", systemImage: "macwindow") { onOpenInWindow?(id) }
            Divider()
            Button(model.task(id: id)?.flagged == true ? "Clear Flag" : "Flag", systemImage: "flag") {
                model.setFlag(model.task(id: id)?.flagged != true, for: id)
            }
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                model.setTrashed(true, for: id)
            }
        } else if !ids.isEmpty {
            // Everything a multi-row selection can do already lives in the
            // bulk bar at the bottom, which is one place rather than two.
            Text("\(ids.count) cards selected")
        }
    }

    private func accessibilityLabel(for row: ListRow) -> String {
        var parts = ["\(row.key), \(row.title)", row.status, "\(row.priority) priority"]
        if !row.assignee.isEmpty { parts.append("assigned to \(row.assignee)") }
        if row.task.dueDate != nil { parts.append("due \(row.due)") }
        if row.task.flagged { parts.append("flagged") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Rows

    private var rows: [ListRow] {
        model.visibleTasks
            .map { ListRow(task: $0, model: model) }
            .sorted(using: sortOrder)
    }

    private struct Group: Identifiable {
        let id: String
        let title: String
        let rows: [ListRow]
    }

    /// Grouped, with the empties last: a "None" group at the top would put the
    /// cards nobody has claimed above the ones somebody has.
    private var groups: [Group] {
        let sorted = rows
        var order: [String] = []
        var buckets: [String: [ListRow]] = [:]

        for row in sorted {
            let key = groupTitle(for: row)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(row)
        }

        let unassigned = "None"
        return order
            .sorted { lhs, rhs in
                if lhs == unassigned { return false }
                if rhs == unassigned { return true }
                return groupRank(lhs) < groupRank(rhs)
            }
            .map { Group(id: $0, title: "\($0)  (\(buckets[$0]?.count ?? 0))", rows: buckets[$0] ?? []) }
    }

    private func groupTitle(for row: ListRow) -> String {
        switch grouping {
        case .none: return ""
        case .status: return row.status
        case .assignee: return row.assignee.isEmpty ? "None" : row.assignee
        case .priority: return row.priority
        case .type: return CardAppearance.label(forType: row.task.type)
        case .epic:
            guard let epic = row.task.epicID.flatMap({ model.task(id: $0) }) else { return "None" }
            return epic.title
        case .sprint:
            guard let sprint = model.sprint(id: row.task.sprintID) else { return "None" }
            return sprint.name
        }
    }

    /// Status and priority have an order that is not alphabetical, and reading
    /// them out of alphabetical order is the whole point of grouping by them.
    private func groupRank(_ title: String) -> String {
        switch grouping {
        case .status:
            let index = model.visibleColumns.firstIndex { $0.name == title } ?? 99
            return String(format: "%02d", index)
        case .priority:
            let index = Priority.allCases.reversed()
                .firstIndex { CardAppearance.label(forPriority: $0) == title } ?? 99
            return String(format: "%02d", index)
        default:
            return title.lowercased()
        }
    }

    // MARK: - Selection

    /// One row selected opens it. Several is a bulk edit, and the bulk bar at
    /// the bottom of the window is where those live — the same bar the board
    /// uses, doing the same things to the same cards.
    private func applySelection(_ ids: Set<String>) {
        if ids.count == 1, let id = ids.first {
            model.selectedTaskID = id
            model.focus(id)
            model.clearPicks()
        } else {
            model.pick(Array(ids), adding: false)
        }
    }
}

/// One row, with everything it sorts by worked out once.
///
/// Sorting a table re-reads every column of every row, so the row holds plain
/// comparable values rather than asking the model each time — which on a
/// thousand cards is a thousand dictionary lookups per keystroke.
struct ListRow: Identifiable {
    let id: String
    let task: BoardTask
    let key: String
    let number: Int
    let title: String
    let status: String
    let priority: String
    let priorityRank: Int
    let assignee: String
    let due: String
    let dueSort: Date
    let isOverdue: Bool
    let points: Double
    let pointsLabel: String
    let days: Int

    @MainActor
    init(task: BoardTask, model: BoardViewModel, now: Date = .now) {
        self.id = task.id
        self.task = task
        self.key = model.tag(for: task)
        self.number = task.number
        self.title = task.title
        self.status = model.columnName(for: task)
        self.priority = CardAppearance.label(forPriority: task.priority)
        self.priorityRank = -task.priority.rawValue
        self.assignee = model.person(id: task.assigneeID)?.name ?? ""
        // Undated cards sort last whichever way the column is pointed, because
        // "no date" is not early and it is not late.
        self.dueSort = task.dueDate ?? .distantFuture
        self.due = task.dueDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
        self.isOverdue = (task.dueDate.map { $0 < now } ?? false) && task.completedAt == nil
        self.points = task.estimate ?? 0
        self.pointsLabel = task.estimate.map {
            $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0)
        } ?? "—"
        self.days = task.daysInColumn(now: now)
    }
}
