import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// My Work: the day in front of you.
///
/// Four sections and one rule about them — **overdue is above today, not part
/// of it.** Something due yesterday is not part of today's plan; it is a thing
/// that has already gone wrong, and burying it among today's work is how it
/// stays wrong.
struct HomeView: View {

    let model: BoardViewModel
    var onOpenInWindow: ((String) -> Void)?

    @State private var isPlanningDay = false
    @State private var dropTarget: WorkSection?
    @State private var expanded: Set<WorkSection> = []

    /// How many things a section shows before asking.
    ///
    /// A day has no scrolling region of its own here — the sections stack and
    /// the page scrolls — so everything in them is built at once. That is fine
    /// for a day and ruinous for an inventory: a project with nine hundred
    /// undated cards cost 361 MB before this cap existed. Twenty is more than
    /// a day, and the rest are one click away.
    private static let sectionCap = 20

    private var work: PersonalRepository.MyWork { model.myWork() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(WorkSection.allCases, id: \.self) { section in
                        sectionView(section)
                    }

                    if !model.myActionItems.isEmpty { actionItems }
                    if !work.snoozed.isEmpty { snoozedLine }
                }
                .padding(14)
            }
        }
        .onAppear { model.loadMyActionItems() }
        .sheet(isPresented: $isPlanningDay) { PlanMyDaySheet(model: model) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.knowsWhoIAm ? "My work" : "Everybody's work")
                .font(.headline)

            if !model.knowsWhoIAm {
                // Saying which list this is beats being quietly wrong about it.
                Text("Nobody is set as “me” yet — Settings → People")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                isPlanningDay = true
            } label: {
                Label("Plan my day", systemImage: "sun.max")
            }
            .buttonStyle(.borderless)

            Text("\(work.count) things")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - One section

    @ViewBuilder
    private func sectionView(_ section: WorkSection) -> some View {
        let tasks = work.tasks(in: section)

        // Overdue with nothing in it is good news and takes no room; the other
        // three keep their heading so the shape of the day stays the same.
        if section != .overdue || !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: section.symbol)
                        .font(.caption)
                        .foregroundStyle(section == .overdue ? .red : .secondary)
                    Text(section.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(section == .overdue ? .red : .primary)
                    Text("\(tasks.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                if tasks.isEmpty {
                    Text(emptyLine(section))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    let shown = expanded.contains(section) ? tasks : Array(tasks.prefix(Self.sectionCap))

                    ForEach(shown) { task in
                        row(task, in: section)
                    }

                    if tasks.count > shown.count {
                        Button {
                            expanded.insert(section)
                        } label: {
                            Text("\(tasks.count - shown.count) more…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("This section holds \(tasks.count). Shows the rest.")
                    }
                }
            }
            .padding(10)
            .background(
                dropTarget == section ? Color.accentColor.opacity(0.10) : Color.quaternaryFill,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(dropTarget == section ? Color.accentColor : .clear, lineWidth: 2)
            }
            // Overdue takes no drops: you cannot decide to have been late.
            .dropDestination(for: String.self) { ids, _ in
                dropTarget = nil
                guard section != .overdue, let id = ids.first else { return false }
                model.reschedule(id, into: section)
                return true
            } isTargeted: { targeted in
                dropTarget = targeted && section != .overdue ? section : nil
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(section.label), \(tasks.count) things")
        }
    }

    private func emptyLine(_ section: WorkSection) -> String {
        switch section {
        case .overdue: "Nothing is late."
        case .today: "Nothing due today. Drag something here to do it today."
        case .next: "Nothing in the next week."
        case .unscheduled: "Everything has a date."
        }
    }

    private func row(_ task: BoardTask, in section: WorkSection) -> some View {
        HStack(spacing: 8) {
            Button {
                model.move(task.id, toStatus: doneStatusID ?? task.statusID)
            } label: {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Finish it")
            .accessibilityLabel("Finish \(task.title)")

            Image(systemName: CardAppearance.symbol(forType: task.type))
                .font(.caption)
                .foregroundStyle(CardAppearance.color(forType: task.type))

            Text(model.tag(for: task))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Text(task.title)
                .lineLimit(1)

            if task.plannedFor != nil, section == .today {
                Image(systemName: "sun.max.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("You planned this for today")
            }

            Spacer(minLength: 0)

            if let due = task.dueDate {
                Text(due.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(section == .overdue ? .red : .secondary)
            }

            Menu {
                ForEach(SnoozeOption.allCases, id: \.self) { option in
                    Button(option.label) { model.snooze(task.id, option) }
                }
                Divider()
                if task.plannedFor == nil {
                    Button("Do It Today", systemImage: "sun.max") { model.planForToday(task.id) }
                } else {
                    Button("Take Off Today", systemImage: "sun.max.trianglebadge.exclamationmark") {
                        model.unplan(task.id)
                    }
                }
                Button("Open in a Window", systemImage: "macwindow") { onOpenInWindow?(task.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("What to do with \(task.title)")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTaskID = task.id }
        .draggable(task.id) {
            Text(task.title).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.tag(for: task)), \(task.title)")
    }

    private var doneStatusID: String? {
        model.visibleColumns.first { $0.status.category == .done }?.status.id
    }

    // MARK: - The other two lines

    /// Things asked of you in passing, which is where half of anyone's work
    /// actually arrives.
    private var actionItems: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Asked of you")
                    .font(.subheadline.weight(.semibold))
                Text("\(model.myActionItems.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            ForEach(model.myActionItems) { comment in
                HStack(spacing: 8) {
                    Button {
                        model.setActionDone(true, for: comment.id)
                        model.loadMyActionItems()
                    } label: {
                        Image(systemName: "circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Text(comment.bodyMarkdown)
                        .font(.callout)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    if let task = model.task(id: comment.taskID) {
                        Button(model.tag(for: task)) { model.selectedTaskID = task.id }
                            .buttonStyle(.borderless)
                            .font(.caption.monospaced())
                    }
                }
            }
        }
        .padding(10)
        .background(Color.quaternaryFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private var snoozedLine: some View {
        DisclosureGroup {
            ForEach(work.snoozed) { task in
                HStack(spacing: 8) {
                    Text(model.tag(for: task))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(task.title).lineLimit(1)
                    Spacer(minLength: 0)
                    if let until = task.snoozedUntil {
                        Text("back \(until.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Wake") { model.wake(task.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        } label: {
            Text("Snoozed  (\(work.snoozed.count))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.quaternaryFill, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Picking what today is for.
///
/// A list to tick rather than a plan the app writes: the app knows what is
/// due, and only the person knows what they are actually going to do.
private struct PlanMyDaySheet: View {

    let model: BoardViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plan my day")
                .font(.headline)

            Text("What are you actually going to do today? Picking something here does not move its due date.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let candidates = model.candidatesForToday()

            if candidates.isEmpty {
                ContentUnavailableView(
                    "Nothing waiting",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing is overdue or due in the next week.")
                )
                .frame(height: 200)
            } else {
                List(candidates, selection: $chosen) { task in
                    HStack(spacing: 8) {
                        Image(systemName: chosen.contains(task.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(chosen.contains(task.id) ? Color.accentColor : .secondary)
                        Text(model.tag(for: task))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(task.title).lineLimit(1)
                        Spacer(minLength: 0)
                        if let due = task.dueDate {
                            Text(due.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(due < .now ? .red : .secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if chosen.contains(task.id) { chosen.remove(task.id) } else { chosen.insert(task.id) }
                    }
                }
                .frame(height: 300)
            }

            HStack {
                Text("\(chosen.count) chosen")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Plan These") {
                    for id in chosen { model.planForToday(id) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

extension Color {
    /// The panel fill used by the day's sections and the trays around them.
    /// Named once so they cannot drift apart.
    static var quaternaryFill: Color { Color.secondary.opacity(0.10) }
}
