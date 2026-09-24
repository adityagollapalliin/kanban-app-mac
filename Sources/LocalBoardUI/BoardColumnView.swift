import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// One column of the board: a header, its cards, and a place to add another at
/// either end.
///
/// Two drop targets, not one. Each card accepts a drop meaning "above this
/// card"; the space below them accepts "at the end". Without the second, the
/// bottom of a column would be the one place a card could not be dropped.
struct BoardColumnView: View {

    let column: LoadedColumn
    let model: BoardViewModel
    /// Lanes draw the same column many times, and each needs its own add-field
    /// focus and drop state; the lane's id keeps them apart.
    var laneID: String = ""
    /// A laned board draws the headings once across the top and the add-field
    /// nowhere: a column repeated down the page would otherwise ask "add a
    /// card" four times over, with no answer to which lane it would land in.
    var isLane = false
    var onOpenInWindow: ((String) -> Void)?

    @State private var newTitle = ""
    @State private var topTitle = ""
    @State private var isAddingAtTop = false
    @State private var dropTarget: String?
    @State private var isRenaming = false
    @State private var renamedTo = ""
    @State private var isSettingLimits = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case top, bottom }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isLane { header }

            if isAddingAtTop { topAddField }

            // A lane lays its cards out directly; only a full-height column
            // scrolls on its own. Nesting a scroll view inside the board's own
            // makes every lane a separate little scrolling region, which is
            // exactly the thing a board is supposed not to be.
            if isLane {
                cards
            } else {
                ScrollView { cards }
            }

            if !isLane { addCardField }
        }
        .frame(width: 300)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var cards: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(column.tasks) { task in
                card(task)
            }

            // The rest of the column: a drop here means "put it last".
            Color.clear
                .frame(minHeight: isLane ? 24 : 60)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { insertionIndicator(above: endOfColumn) }
                .dropDestination(for: String.self) { ids, _ in
                    dropTarget = nil
                    return drop(ids, before: nil)
                } isTargeted: { targeted in
                    dropTarget = targeted ? endOfColumn : (dropTarget == endOfColumn ? nil : dropTarget)
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func card(_ task: BoardTask) -> some View {
        TaskCardView(task: task, tag: model.tag(for: task), model: model, onOpenInWindow: onOpenInWindow)
            .draggable(task.id) {
                // Drag preview: the title alone, so the cursor carries what was
                // picked up, not a whole card. A multi-card drag says how many.
                Text(dragLabel(for: task))
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .overlay(alignment: .top) { insertionIndicator(above: task.id) }
            .dropDestination(for: String.self) { ids, _ in
                dropTarget = nil
                return drop(ids, before: task.id)
            } isTargeted: { targeted in
                dropTarget = targeted ? task.id : (dropTarget == task.id ? nil : dropTarget)
            }
    }

    /// Dragging one of several selected cards brings the whole selection —
    /// which is what a selection is for, and what every other Mac app does.
    private func drop(_ ids: [String], before: String?) -> Bool {
        guard let dragged = ids.first else { return false }

        if model.isPicked(dragged), model.selectedTaskIDs.count > 1 {
            model.bulkMove(toStatus: column.status.id)
            return true
        }
        model.move(dragged, toStatus: column.status.id, before: before)
        return true
    }

    private func dragLabel(for task: BoardTask) -> String {
        let picked = model.selectedTaskIDs
        guard picked.contains(task.id), picked.count > 1 else { return task.title }
        return "\(picked.count) cards"
    }

    /// Sentinel for "below the last card" — a column has no task id there.
    private var endOfColumn: String { "\u{0}end-\(laneID)" }

    private func insertionIndicator(above id: String) -> some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .opacity(dropTarget == id ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: dropTarget)
            .accessibilityHidden(true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(column.name)
                .font(.subheadline.weight(.semibold))

            Text("\(column.tasks.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())

            // A column gathering several statuses says so, because otherwise
            // the cards in it look like they are all in one place.
            if column.statuses.count > 1 {
                Image(systemName: "arrow.triangle.merge")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Shows: " + column.statuses.map(\.name).joined(separator: ", "))
            }

            Spacer(minLength: 0)

            wipBadge

            Button {
                isAddingAtTop = true
                focusedField = .top
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add a card at the top")
            .accessibilityLabel("Add a card at the top of \(column.name)")

            columnMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(alignment: .bottom) { wipUnderline }
        .alert("Rename column", isPresented: $isRenaming) {
            TextField("Name", text: $renamedTo)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.renameColumn(column.id, to: renamedTo) }
        } message: {
            Text("The name is also what `status = \"…\"` matches in a query.")
        }
        .sheet(isPresented: $isSettingLimits) {
            WIPLimitSheet(column: column, model: model)
        }
    }

    /// The limit, and how it is doing. Amber approaching, red over, blue when
    /// the column has run dry — and nothing at all when no limit is set, so an
    /// unlimited column stays quiet.
    @ViewBuilder
    private var wipBadge: some View {
        if column.column.wipLimit != nil || column.column.wipMinimum != nil {
            Label(wipText, systemImage: wipSymbol)
                .font(.caption2.monospacedDigit())
                .labelStyle(.titleAndIcon)
                .foregroundStyle(wipColor)
                .help(wipHelp)
                .accessibilityLabel(wipHelp)
        }
    }

    /// A thin rule under the header rather than a tinted column: the colour
    /// has to be noticeable without making the cards harder to read.
    @ViewBuilder
    private var wipUnderline: some View {
        if column.wipState != .fine {
            Rectangle()
                .fill(wipColor)
                .frame(height: 2)
                .accessibilityHidden(true)
        }
    }

    private var wipText: String {
        let amount = column.wipAmount
        let shown = amount == amount.rounded() ? String(Int(amount)) : String(format: "%.1f", amount)

        if let limit = column.column.wipLimit {
            return "\(shown)/\(limit)"
        }
        if let minimum = column.column.wipMinimum {
            return "\(shown) (min \(minimum))"
        }
        return shown
    }

    private var wipSymbol: String {
        switch column.wipState {
        case .fine: column.column.wipMeasure == .estimate ? "number" : "tray.full"
        case .belowMinimum: "arrow.down.to.line"
        case .approaching: "exclamationmark.triangle"
        case .breached: "exclamationmark.triangle.fill"
        }
    }

    private var wipColor: Color {
        switch column.wipState {
        case .fine: .secondary
        case .belowMinimum: .blue
        case .approaching: .orange
        case .breached: .red
        }
    }

    private var wipHelp: String {
        let unit = column.column.wipMeasure == .estimate ? "points" : "cards"

        let headline: String
        switch column.wipState {
        case .fine:
            headline = "Work-in-progress limits for \(column.name), counted in \(unit)."
        case .belowMinimum:
            headline = "Below the minimum of \(column.column.wipMinimum ?? 0) \(unit). "
                + "This column has run dry — nothing is blocked."
        case .approaching:
            headline = "At the limit of \(column.column.wipLimit ?? 0) \(unit). One more and it is over."
        case .breached:
            headline = "Over the limit of \(column.column.wipLimit ?? 0) \(unit). "
                + "Nothing is blocked; the board is just telling you."
        }

        // Counting points quietly ignores unestimated cards, so the column
        // says how many it is not counting rather than letting the number lie.
        guard column.unestimatedCount > 0 else { return headline }
        let count = column.unestimatedCount
        return headline + " \(count) card\(count == 1 ? " has" : "s have") no estimate."
    }

    private var columnMenu: some View {
        Menu {
            Button("Rename…") {
                renamedTo = column.name
                isRenaming = true
            }

            Button("Limits…", systemImage: "gauge.with.dots.needle.33percent") {
                isSettingLimits = true
            }

            // The category is what makes "done" mean something to the rest of
            // the app — it is what stamps completed_at.
            Menu("Counts as") {
                Button("To do") { model.setCategory(.toDo, for: column.id) }
                Button("In progress") { model.setCategory(.inProgress, for: column.id) }
                Button("Done") { model.setCategory(.done, for: column.id) }
            }

            Divider()

            Button("Move Left") { moveLeft() }
                .disabled(neighbours.left == nil)
            Button("Move Right") { moveRight() }
                .disabled(neighbours.right == nil)

            Divider()

            Toggle("Backlog Column", isOn: Binding(
                get: { column.column.isBacklog },
                set: { model.setBacklog($0, for: column.id) }
            ))
            .help("Cards here wait off the board. Dragging one onto the board is the commitment point.")

            if !otherColumns.isEmpty {
                Menu("Merge Into This Column") {
                    ForEach(otherColumns) { other in
                        Button(other.name) { model.mergeColumn(other.id, into: column.id) }
                    }
                }
                .help("Show another column's status under this heading instead.")
            }

            if column.statuses.count > 1 {
                Menu("Split Back Out") {
                    ForEach(column.statuses.dropFirst(), id: \.id) { status in
                        Button(status.name) { model.splitStatus(status.id, outOf: column.id) }
                    }
                }
            }

            Divider()

            if column.tasks.isEmpty {
                Button("Delete Column", systemImage: "trash", role: .destructive) {
                    model.deleteColumn(column.id, movingTasksTo: nil)
                }
            } else {
                // A column holding work cannot go without somewhere for the
                // work to land, so the choice is part of the action rather
                // than a dialog that follows it.
                Menu("Delete, Moving Cards To") {
                    ForEach(otherColumns) { other in
                        Button(other.name) {
                            model.deleteColumn(column.id, movingTasksTo: other.status.id)
                        }
                    }
                }
                .disabled(otherColumns.isEmpty)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rename, limit or remove this column")
        .accessibilityLabel("Column options for \(column.name)")
    }

    private var allColumns: [LoadedColumn] { model.snapshot?.columns ?? [] }

    private var otherColumns: [LoadedColumn] { allColumns.filter { $0.id != column.id } }

    private var neighbours: (left: LoadedColumn?, right: LoadedColumn?) {
        guard let index = allColumns.firstIndex(where: { $0.id == column.id }) else { return (nil, nil) }
        return (
            index > 0 ? allColumns[index - 1] : nil,
            index < allColumns.count - 1 ? allColumns[index + 1] : nil
        )
    }

    /// Swapping with a neighbour means landing on the far side of it.
    private func moveLeft() {
        guard let left = neighbours.left else { return }
        let index = allColumns.firstIndex { $0.id == left.id } ?? 0
        model.moveColumn(column.id, after: index > 0 ? allColumns[index - 1].id : nil, before: left.id)
    }

    private func moveRight() {
        guard let right = neighbours.right else { return }
        let index = allColumns.firstIndex { $0.id == right.id } ?? 0
        let beyond = index < allColumns.count - 1 ? allColumns[index + 1].id : nil
        model.moveColumn(column.id, after: right.id, before: beyond)
    }

    // MARK: - Adding cards

    private var topAddField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Add a card at the top", text: $topTitle)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focusedField, equals: .top)
                .onSubmit { submit(top: true) }
                .onExitCommand {
                    isAddingAtTop = false
                    topTitle = ""
                }
                .accessibilityLabel("Add a card at the top of \(column.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    private var addCardField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Add a card", text: $newTitle)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focusedField, equals: .bottom)
                .onSubmit { submit(top: false) }
                .accessibilityLabel("Add a card to \(column.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = .bottom }
    }

    private func submit(top: Bool) {
        let source = top ? topTitle : newTitle
        let title = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            if top { isAddingAtTop = false }
            return
        }

        model.addTask(title: title, toStatus: column.status.id, atTop: top)

        if top { topTitle = "" } else { newTitle = "" }
        // Stay focused: adding cards is something people do several times in a
        // row, and reaching for the mouse between each one is the slow way.
        focusedField = top ? .top : .bottom
    }
}

/// Both limits and what they count, in one place.
///
/// A sheet rather than nested menus because the three settings only make sense
/// together: a minimum of two and a maximum of one is a contradiction worth
/// seeing on one screen.
struct WIPLimitSheet: View {
    let column: LoadedColumn
    let model: BoardViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var hasMaximum = false
    @State private var maximum = 5
    @State private var hasMinimum = false
    @State private var minimum = 1
    @State private var measure: WIPMeasure = .cardCount

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Limits for \(column.name)")
                .font(.headline)

            Picker("Count", selection: $measure) {
                ForEach(WIPMeasure.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Maximum", isOn: $hasMaximum)
            if hasMaximum {
                Stepper("At most \(maximum)", value: $maximum, in: 1...99)
            }

            Toggle("Minimum", isOn: $hasMinimum)
            if hasMinimum {
                Stepper("At least \(minimum)", value: $minimum, in: 0...99)
            }

            if hasMaximum, hasMinimum, minimum > maximum {
                Label("The minimum is above the maximum, so the column can never be right.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Limits are reported, never enforced. Going over one never blocks a move.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            measure = column.column.wipMeasure
            if let limit = column.column.wipLimit {
                hasMaximum = true
                maximum = limit
            }
            if let floor = column.column.wipMinimum {
                hasMinimum = true
                minimum = floor
            }
        }
    }

    private func apply() {
        model.setWIPMeasure(measure, for: column.id)
        model.setWIPLimit(hasMaximum ? maximum : nil, for: column.id)
        model.setWIPMinimum(hasMinimum ? minimum : nil, for: column.id)
        dismiss()
    }
}
