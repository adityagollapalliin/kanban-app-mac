import SwiftUI
import Charts
import LocalBoardCore
import LocalBoardStore

/// A grid of widgets over the space.
///
/// The grid flows: what is stored is the order, and the positions are worked
/// out for whatever width there is. A free grid would have to answer what
/// happens when the window is narrower than the layout, and every answer is
/// either a horizontal scroll bar or widgets that overlap.
struct DashboardsView: View {

    let model: BoardViewModel

    @State private var selected: String?
    @State private var isNaming = false
    @State private var name = ""
    @State private var editing: DashboardWidget?

    /// Four across on a wide window, fewer as it narrows. The widgets keep
    /// their spans and the packer finds them somewhere to sit.
    private func columns(for width: Double) -> Int {
        if width < 520 { return 1 }
        if width < 820 { return 2 }
        if width < 1_150 { return 3 }
        return 4
    }

    private var current: Dashboard? {
        model.dashboards.first { $0.id == selected } ?? model.dashboards.first
    }

    var body: some View {
        Group {
            if model.dashboards.isEmpty {
                ContentUnavailableView {
                    Label("No dashboards yet", systemImage: "square.grid.2x2")
                } description: {
                    Text("A dashboard is a grid of widgets, each one a saved query and a way of drawing it.")
                } actions: {
                    Button("Create one") {
                        selected = model.createDashboard(named: "Overview")
                    }
                    .help("Starts with four widgets that already say something about this space")
                }
            } else if let dashboard = current {
                grid(dashboard)
            }
        }
        .navigationTitle(current?.name ?? "Dashboards")
        .toolbar { toolbar }
        .sheet(item: $editing) { widget in
            WidgetEditor(model: model, widget: widget)
        }
        .alert("New dashboard", isPresented: $isNaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") { selected = model.createDashboard(named: name) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if model.dashboards.count > 1 {
                Picker("Dashboard", selection: Binding(
                    get: { current?.id ?? "" },
                    set: { selected = $0 }
                )) {
                    ForEach(model.dashboards) { dashboard in
                        Text(dashboard.name).tag(dashboard.id)
                    }
                }
                .pickerStyle(.menu)
            }

            if let dashboard = current {
                Menu {
                    ForEach(DashboardWidgetKind.allCases, id: \.self) { kind in
                        Button {
                            model.addWidget(kind, to: dashboard.id)
                        } label: {
                            Label(kind.label, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Label("Add Widget", systemImage: "plus.square")
                }

                Menu {
                    Button("New dashboard…") { name = ""; isNaming = true }
                    Divider()
                    Button("Delete this dashboard", role: .destructive) {
                        model.deleteDashboard(dashboard.id)
                        selected = nil
                    }
                } label: {
                    Label("Dashboards", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func grid(_ dashboard: Dashboard) -> some View {
        GeometryReader { geometry in
            let across = columns(for: geometry.size.width)
            let rows = DashboardLayout.rows(model.widgets(on: dashboard.id), columns: across)
            let cell = cellWidth(in: geometry.size.width, across: across)

            ScrollView {
                // Rows of their own rather than a LazyVGrid, because
                // LazyVGrid has no way to make one cell wider than another —
                // which would quietly ignore every width anybody set.
                LazyVStack(spacing: Self.spacing) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: Self.spacing) {
                            ForEach(row) { widget in
                                box(widget, dashboard: dashboard, cell: cell, across: across, rows: rows)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(Self.spacing)
                // Tied to the revision, so adding, moving or removing a widget
                // redraws rather than leaving a stale arrangement on screen.
                .id(model.dashboardRevision)
            }
        }
    }

    private static let spacing: CGFloat = 12

    /// What one cell is worth, so a widget two cells wide is two cells plus
    /// the gap it swallows.
    private func cellWidth(in width: CGFloat, across: Int) -> CGFloat {
        max(80, (width - Self.spacing * CGFloat(across + 1)) / CGFloat(across))
    }

    private func box(
        _ widget: DashboardWidget,
        dashboard: Dashboard,
        cell: CGFloat,
        across: Int,
        rows: [[DashboardWidget]]
    ) -> some View {
        let width = cell * CGFloat(widget.width) + Self.spacing * CGFloat(widget.width - 1)

        return WidgetBox(widget: widget, model: model) { editing = widget }
            .frame(width: width, height: CGFloat(widget.height) * 150)
            .draggable(widget.id) {
                Label(widget.displayTitle, systemImage: widget.kind.symbol)
            }
            .dropDestination(for: String.self) { items, _ in
                drop(items, onto: widget, dashboard: dashboard, across: across, rows: rows)
            }
    }

    /// Dropping onto a widget means "take its place".
    private func drop(
        _ items: [String],
        onto widget: DashboardWidget,
        dashboard: Dashboard,
        across: Int,
        rows: [[DashboardWidget]]
    ) -> Bool {
        let ordered = rows.flatMap { $0 }
        guard let movedID = items.first,
              let from = ordered.firstIndex(where: { $0.id == movedID }),
              let to = ordered.firstIndex(where: { $0.id == widget.id }),
              from != to
        else { return false }

        // Moving downwards means inserting after it, because the widget being
        // dragged leaves a gap behind first.
        model.moveWidget(
            on: dashboard.id, from: from, to: to > from ? to + 1 : to, columns: across
        )
        return true
    }
}

/// One widget, drawn.
struct WidgetBox: View {

    let widget: DashboardWidget
    let model: BoardViewModel
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: widget.kind.symbol)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(widget.displayTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("Edit…", action: onEdit)
                    Divider()
                    Button("Remove", role: .destructive) { model.removeWidget(widget.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            content
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    @ViewBuilder
    private var content: some View {
        switch model.widgetData(widget) {
        case .count(let matching, let total):
            VStack(alignment: .leading, spacing: 2) {
                Text("\(matching)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("of \(total) cards")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .breakdown(let slices):
            if slices.allSatisfy({ $0.value == 0 }) {
                empty("Nothing matches yet")
            } else {
                Chart(slices) { slice in
                    BarMark(
                        x: .value("Cards", slice.value),
                        y: .value("Group", slice.label)
                    )
                    .foregroundStyle(color(named: slice.colorName))
                    .annotation(position: .trailing) {
                        Text("\(Int(slice.value))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(minHeight: CGFloat(slices.count) * 22)
            }

        case .tasks(let tasks, let total):
            if tasks.isEmpty {
                empty("Nothing matches")
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(tasks) { task in
                        Button {
                            model.selectedTaskID = task.id
                        } label: {
                            HStack(spacing: 5) {
                                Text(model.tag(for: task))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(task.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if total > tasks.count {
                        Text("and \(total - tasks.count) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .workload(let people, let unit):
            if people.isEmpty {
                empty("Nobody has anything due")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(people) { person in
                        HStack {
                            Text(person.label).font(.caption).lineLimit(1)
                            Spacer()
                            Text("\(Int(person.value)) \(unit)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

        case .time(let total, let billable, let byDay):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(DurationFormat.short(total))
                        .font(.title2.weight(.semibold).monospacedDigit())
                    if billable > 0 {
                        Text("\(DurationFormat.short(billable)) billable")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                if byDay.count > 1 {
                    Chart(byDay) { point in
                        BarMark(
                            x: .value("Day", point.day, unit: .day),
                            y: .value("Minutes", Double(point.minutes) / 60)
                        )
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(minHeight: 70)
                }
            }

        case .goal(let goal):
            VStack(alignment: .leading, spacing: 6) {
                Text(goal.name).font(.callout).lineLimit(1)
                ProgressView(value: goal.fraction)
                    .tint(goal.isMet ? .green : .accentColor)
                Text(goal.progressDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .note(let text):
            if text.isEmpty {
                empty("Nothing written yet")
            } else {
                Text(text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .flow(let points):
            if points.count < 2 {
                empty("Not enough history yet")
            } else {
                Chart {
                    ForEach(points) { point in
                        AreaMark(x: .value("Day", point.day), y: .value("Done", point.done))
                            .foregroundStyle(by: .value("Category", "Done"))
                        AreaMark(x: .value("Day", point.day), y: .value("In progress", point.inProgress))
                            .foregroundStyle(by: .value("Category", "In progress"))
                        AreaMark(x: .value("Day", point.day), y: .value("To do", point.toDo))
                            .foregroundStyle(by: .value("Category", "To do"))
                    }
                }
                .frame(minHeight: 110)
            }

        case .burndown(let points):
            if points.count < 2 {
                empty("Not enough of the sprint has passed")
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Day", point.day), y: .value("Left", point.remaining))
                    }
                }
                .frame(minHeight: 110)
            }

        case .unavailable(let reason):
            // A widget that cannot read says why, rather than being an empty
            // box the user has to guess about.
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func color(named name: String) -> Color {
        switch name {
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        case "red": .red
        default: .secondary
        }
    }
}

/// A widget's title, query and settings.
struct WidgetEditor: View {

    let model: BoardViewModel
    let widget: DashboardWidget

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var query = ""
    @State private var text = ""
    @State private var days = 30
    @State private var limit = 10
    @State private var goalID: String?
    @State private var width = 1
    @State private var height = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(widget.kind.label, systemImage: widget.kind.symbol)
                .font(.headline)
                .padding()

            Form {
                TextField("Title", text: $title, prompt: Text(widget.kind.label))

                if widget.kind.usesQuery {
                    TextField("Cards matching", text: $query, prompt: Text("is:open priority >= high"))
                    Text("Leave it empty for every card in the space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                switch widget.kind {
                case .note:
                    TextField("Text", text: $text, axis: .vertical).lineLimit(3...8)
                case .goalProgress:
                    Picker("Goal", selection: $goalID) {
                        Text("Pick one").tag(String?.none)
                        ForEach(model.goals) { goal in
                            Text(goal.name).tag(String?.some(goal.id))
                        }
                    }
                case .taskList:
                    Stepper("Show at most \(limit)", value: $limit, in: 1...50)
                case .timeTracked, .cumulativeFlow, .workload:
                    Stepper("Over \(days) days", value: $days, in: 1...365, step: 7)
                default:
                    EmptyView()
                }

                Section("Size") {
                    Stepper("\(width) across", value: $width, in: 1...4)
                    Stepper("\(height) down", value: $height, in: 1...3)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420)
        .onAppear {
            title = widget.title
            query = widget.query
            text = widget.config.text
            days = widget.config.days
            limit = widget.config.limit
            goalID = widget.config.goalID
            width = widget.width
            height = widget.height
        }
    }

    private func save() {
        var updated = widget
        updated.title = title
        updated.query = query
        updated.config.text = text
        updated.config.days = days
        updated.config.limit = limit
        updated.config.goalID = goalID
        updated.width = width
        updated.height = height
        model.updateWidget(updated)
        dismiss()
    }
}
