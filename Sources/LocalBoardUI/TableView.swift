import AppKit
import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// A spreadsheet over the same cards.
///
/// The difference from the list is that this one is *editable in place*. A
/// list is for reading in an order you chose; a table is for changing twenty
/// cards without opening twenty panels. So every cell that can be typed into
/// is, the number columns carry totals, and the whole thing can leave as CSV.
///
/// What it remembers — which columns, in what order, grouped and sorted how —
/// is saved per place, because the columns that matter on a bug list are not
/// the ones that matter on a release list.
struct TableView: View {

    let model: BoardViewModel

    @State private var config = ViewConfig(
        id: "", scopeKind: .space, scopeID: "", viewKind: .table, updatedAt: .now
    )
    @State private var loaded = false
    @State private var editingCell: String?
    @State private var draft = ""
    @State private var exportMessage: String?

    /// Every column the table can show. Which ones it *does* show is the
    /// user's, kept per place.
    enum Column: String, CaseIterable, Identifiable {
        case key, title, status, type, priority, assignees, due, start, points, days, list, labels

        var id: String { rawValue }

        var label: String {
            switch self {
            case .key: "Key"
            case .title: "Title"
            case .status: "Status"
            case .type: "Type"
            case .priority: "Priority"
            case .assignees: "Assignees"
            case .due: "Due"
            case .start: "Start"
            case .points: "Points"
            case .days: "Days"
            case .list: "List"
            case .labels: "Labels"
            }
        }

        var width: CGFloat {
            switch self {
            case .key: 72
            case .title: 260
            case .status, .list: 110
            case .type, .priority: 86
            case .assignees, .labels: 140
            case .due, .start: 96
            case .points, .days: 56
            }
        }

        /// The columns worth totalling. A sum of priorities would be a number
        /// with no meaning, so only the ones measured in something get one.
        var isNumeric: Bool { self == .points || self == .days }

        /// Typed into directly. The rest are pickers or facts the card owns.
        var isTypable: Bool { self == .title || self == .points }

        static let defaults: [Column] = [.key, .title, .status, .priority, .assignees, .due, .points]
    }

    private var columns: [Column] {
        let chosen = config.columns.compactMap { Column(rawValue: $0) }
        return chosen.isEmpty ? Column.defaults : chosen
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            grid
            Divider()
            totals
        }
        .onAppear(perform: loadConfig)
        // The board underneath can change while this is open — a card trashed
        // from a window, another process writing — and the saved settings
        // belong to the place, so both are re-read when the place changes.
        .onChange(of: model.selectedListID) { loadConfig() }
        .onChange(of: model.selectedBoardID) { loadConfig() }
    }

    private func loadConfig() {
        config = model.viewConfig(.table)
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        model.save(config)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Group by", selection: Binding(
                get: { config.groupBy },
                set: { config.groupBy = $0; save() }
            )) {
                Text("No Grouping").tag("")
                Text("Status").tag("status")
                Text("Assignee").tag("assignee")
                Text("Priority").tag("priority")
                Text("List").tag("list")
            }
            .pickerStyle(.menu)
            .fixedSize()

            Menu {
                ForEach(Column.allCases) { column in
                    Button {
                        toggle(column)
                    } label: {
                        if columns.contains(column) {
                            Label(column.label, systemImage: "checkmark")
                        } else {
                            Text(column.label)
                        }
                    }
                }
                Divider()
                Button("Reset Columns") {
                    config.columns = Column.defaults.map(\.rawValue)
                    save()
                }
            } label: {
                Label("Columns", systemImage: "tablecells")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 0)

            if let exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Button {
                exportCSV()
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Writes the rows as they are shown — the same columns, the same order.")

            Text("\(rows.count) cards")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func toggle(_ column: Column) {
        var chosen = columns
        if let index = chosen.firstIndex(of: column) {
            // The last column cannot be removed: a table with no columns is a
            // blank rectangle with no way back.
            guard chosen.count > 1 else { return }
            chosen.remove(at: index)
        } else {
            chosen.append(column)
        }
        config.columns = chosen.map(\.rawValue)
        save()
    }

    // MARK: - The grid

    /// Two scroll views of different axes, with the header as the vertical
    /// one's top inset.
    ///
    /// Not a pinned section header: a pinned header inside a view that scrolls
    /// both ways mis-measures and ends up drawn over the first rows — the same
    /// fault as a lazy stack in a two-axis scroll view, and it looks exactly
    /// as broken. An inset on a vertically-bounded scroll view stays put down
    /// the page and still slides sideways with the columns it labels.
    private var grid: some View {
        ScrollView(.horizontal) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if config.groupBy.isEmpty {
                        ForEach(rows) { row in
                            line(row)
                        }
                    } else {
                        ForEach(groups, id: \.name) { group in
                            groupHeader(group)
                            ForEach(group.rows) { row in
                                line(row)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Button {
                    sort(by: column)
                } label: {
                    HStack(spacing: 3) {
                        Text(column.label)
                            .font(.caption.weight(.semibold))
                        if config.sortField == column.rawValue {
                            Image(systemName: config.sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: column.width, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func sort(by column: Column) {
        if config.sortField == column.rawValue {
            config.sortAscending.toggle()
        } else {
            config.sortField = column.rawValue
            config.sortAscending = true
        }
        save()
    }

    private func groupHeader(_ group: (name: String, rows: [ListRow])) -> some View {
        HStack(spacing: 6) {
            Text(group.name)
                .font(.caption.weight(.semibold))
            Text("\(group.rows.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.4))
    }

    private func line(_ row: ListRow) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                cell(column, row: row)
                    .frame(width: column.width, alignment: .leading)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 3)
        .background(model.selectedTaskID == row.id ? Color.accentColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTaskID = row.id }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.key), \(row.title), \(row.status)")
    }

    @ViewBuilder
    private func cell(_ column: Column, row: ListRow) -> some View {
        switch column {
        case .key:
            Text(row.key)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

        case .title:
            editableText(row: row, column: .title, value: row.title) { new in
                model.rename(row.id, to: new)
            }

        case .status:
            Menu(row.status) {
                // Only the moves this card may actually make. A condition
                // hides a move rather than refusing it, which is the whole
                // difference between a condition and a validator.
                ForEach(model.task(id: row.id).map { model.offeredStatuses(for: $0) } ?? model.statuses) { status in
                    Button(status.name) { model.move(row.id, toStatus: status.id) }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.callout)

        case .type:
            Menu {
                ForEach(TaskType.allCases, id: \.self) { type in
                    Button(CardAppearance.label(forType: type)) { model.setType(type, for: row.id) }
                }
            } label: {
                Label(CardAppearance.label(forType: row.task.type),
                      systemImage: CardAppearance.symbol(forType: row.task.type))
                    .foregroundStyle(CardAppearance.color(forType: row.task.type))
            }
            .menuStyle(.borderlessButton)
            .font(.callout)

        case .priority:
            Menu {
                ForEach(Priority.allCases.reversed(), id: \.self) { priority in
                    Button(CardAppearance.label(forPriority: priority)) {
                        model.setPriority(priority, for: row.id)
                    }
                }
            } label: {
                Label(row.priority, systemImage: CardAppearance.symbol(forPriority: row.task.priority))
                    .foregroundStyle(CardAppearance.color(forPriority: row.task.priority))
            }
            .menuStyle(.borderlessButton)
            .font(.callout)

        case .assignees:
            Menu {
                ForEach(model.people) { person in
                    Button {
                        if model.people(on: row.task).contains(where: { $0.id == person.id }) {
                            model.removeAssignee(person.id, from: row.id)
                        } else {
                            model.addAssignee(person.id, to: row.id)
                        }
                    } label: {
                        if model.people(on: row.task).contains(where: { $0.id == person.id }) {
                            Label(person.name, systemImage: "checkmark")
                        } else {
                            Text(person.name)
                        }
                    }
                }
            } label: {
                Text(assigneeLabel(row))
                    .foregroundStyle(model.people(on: row.task).isEmpty ? .secondary : .primary)
            }
            .menuStyle(.borderlessButton)
            .font(.callout)

        case .due:
            DatePicker("", selection: Binding(
                get: { row.task.dueDate ?? .now },
                set: { model.setDueDate($0, for: row.id) }
            ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .opacity(row.task.dueDate == nil ? 0.45 : 1)

        case .start:
            DatePicker("", selection: Binding(
                get: { row.task.startDate ?? .now },
                set: { model.setStartDate($0, for: row.id) }
            ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .opacity(row.task.startDate == nil ? 0.45 : 1)

        case .points:
            editableText(row: row, column: .points, value: row.pointsLabel) { new in
                model.setEstimate(Double(new), for: row.id)
            }

        case .days:
            Text("\(row.days)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(row.days >= model.staleDays ? .orange : .secondary)

        case .list:
            Menu(model.list(id: row.task.listID)?.name ?? "—") {
                ForEach(model.lists) { list in
                    Button(list.name) { model.setHomeList(list.id, forTask: row.id) }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.callout)

        case .labels:
            Text(model.labels(for: row.task).map(\.name).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func assigneeLabel(_ row: ListRow) -> String {
        let people = model.people(on: row.task)
        switch people.count {
        case 0: return "—"
        case 1: return people[0].name
        default: return "\(people[0].name) +\(people.count - 1)"
        }
    }

    /// A cell that becomes a text field when clicked and goes back when it
    /// loses focus. Committing on blur as well as on Return matters here:
    /// filling a column top to bottom means clicking away twenty times.
    @ViewBuilder
    private func editableText(
        row: ListRow, column: Column, value: String, commit: @escaping (String) -> Void
    ) -> some View {
        let key = "\(row.id)-\(column.rawValue)"

        if editingCell == key {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit {
                    commit(draft)
                    editingCell = nil
                }
                .onExitCommand { editingCell = nil }
        } else {
            Text(value)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    draft = value == "—" ? "" : value
                    editingCell = key
                }
        }
    }

    // MARK: - Rows

    private var rows: [ListRow] {
        let made = model.visibleTasks.map { ListRow(task: $0, model: model) }
        guard let field = Column(rawValue: config.sortField) else { return made }

        let sorted: [ListRow]
        switch field {
        case .title: sorted = made.sorted { $0.title < $1.title }
        case .status: sorted = made.sorted { $0.status < $1.status }
        case .priority: sorted = made.sorted { $0.priorityRank < $1.priorityRank }
        case .assignees: sorted = made.sorted { $0.assignee < $1.assignee }
        case .due: sorted = made.sorted { $0.dueSort < $1.dueSort }
        case .start:
            sorted = made.sorted { ($0.task.startDate ?? .distantFuture) < ($1.task.startDate ?? .distantFuture) }
        case .points: sorted = made.sorted { $0.points < $1.points }
        case .days: sorted = made.sorted { $0.days < $1.days }
        case .type: sorted = made.sorted { $0.task.type.rawValue < $1.task.type.rawValue }
        case .list, .labels, .key: sorted = made.sorted { $0.number < $1.number }
        }
        return config.sortAscending ? sorted : sorted.reversed()
    }

    private var groups: [(name: String, rows: [ListRow])] {
        var order: [String] = []
        var buckets: [String: [ListRow]] = [:]

        for row in rows {
            let name = groupName(row)
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(row)
        }
        // "None" last: the cards nobody has claimed do not belong above the
        // ones somebody has.
        return order
            .sorted { lhs, rhs in lhs == "None" ? false : (rhs == "None" ? true : false) }
            .map { ($0, buckets[$0] ?? []) }
    }

    private func groupName(_ row: ListRow) -> String {
        switch config.groupBy {
        case "status": return row.status
        case "assignee": return row.assignee.isEmpty ? "None" : row.assignee
        case "priority": return row.priority
        case "list": return model.list(id: row.task.listID)?.name ?? "None"
        default: return ""
        }
    }

    // MARK: - Totals

    /// Only the columns measured in something get a total. A sum of
    /// priorities would be a number that means nothing.
    private var totals: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Group {
                    if column.isNumeric {
                        Text(total(column))
                            .font(.caption.monospacedDigit().weight(.semibold))
                    } else if column == columns.first {
                        Text("Total")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: column.width, alignment: .leading)
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func total(_ column: Column) -> String {
        let sum: Double
        switch column {
        case .points: sum = rows.reduce(0) { $0 + $1.points }
        case .days: sum = rows.reduce(0) { $0 + Double($1.days) }
        default: return ""
        }
        return sum == sum.rounded() ? String(Int(sum)) : String(format: "%.1f", sum)
    }

    // MARK: - CSV

    /// Writes what is on screen, in the order it is on screen. An export that
    /// quietly gave you every column and every card would not be an export of
    /// the table you set up.
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.selectedList?.name ?? model.currentProject?.name ?? "cards").csv"
        panel.allowedContentTypes = [.commaSeparatedText]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines = [columns.map { escape($0.label) }.joined(separator: ",")]
        for row in rows {
            lines.append(columns.map { escape(text(of: $0, row: row)) }.joined(separator: ","))
        }

        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            withAnimation { exportMessage = "Saved \(rows.count) rows." }
        } catch {
            withAnimation { exportMessage = "Could not write the file." }
        }
    }

    private func text(of column: Column, row: ListRow) -> String {
        switch column {
        case .key: row.key
        case .title: row.title
        case .status: row.status
        case .type: CardAppearance.label(forType: row.task.type)
        case .priority: row.priority
        case .assignees: model.people(on: row.task).map(\.name).joined(separator: "; ")
        case .due: row.task.dueDate.map { $0.formatted(date: .numeric, time: .omitted) } ?? ""
        case .start: row.task.startDate.map { $0.formatted(date: .numeric, time: .omitted) } ?? ""
        case .points: row.task.estimate.map { String($0) } ?? ""
        case .days: String(row.days)
        case .list: model.list(id: row.task.listID)?.name ?? ""
        case .labels: model.labels(for: row.task).map(\.name).joined(separator: "; ")
        }
    }

    /// A title with a comma in it is one field, not two. Quotes inside are
    /// doubled, which is what every spreadsheet expects to read back.
    private func escape(_ text: String) -> String {
        guard text.contains(",") || text.contains("\"") || text.contains("\n") else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
