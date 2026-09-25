import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// Everyone on a card, and what share of it is theirs.
///
/// The first person is also `assignee_id`, which is what the card's avatar,
/// `is:mine` and every query written before this existed still read — so the
/// order here is not decoration.
struct AssigneesSection: View {

    let task: BoardTask
    let model: BoardViewModel

    @State private var editingShare: String?
    @State private var shareDraft = ""

    var body: some View {
        Section("Assignees") {
            ForEach(model.assignees(of: task), id: \.personID) { assignee in
                row(assignee)
            }

            if model.assignees(of: task).isEmpty {
                Text("Nobody yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Menu("Add Someone") {
                ForEach(available) { person in
                    Button(person.name) { model.addAssignee(person.id, to: task.id) }
                }
                if available.isEmpty {
                    Text("Everybody is already on this card.")
                }
            }
            .disabled(model.people.isEmpty)

            if model.assignees(of: task).count > 1 {
                Text("""
                    The first person is the card's main assignee. Shares are \
                    optional — where nobody has given one, the workload view \
                    splits the estimate equally.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var available: [Person] {
        let already = Set(model.assignees(of: task).map(\.personID))
        return model.people.filter { !already.contains($0.id) }
    }

    private func row(_ assignee: TaskAssignee) -> some View {
        let person = model.person(id: assignee.personID)

        return HStack(spacing: 8) {
            Circle()
                .fill(person.map { PaletteColor.named($0.color).color } ?? .secondary)
                .frame(width: 8, height: 8)

            Text(person?.name ?? "Somebody who has been removed")
                .font(.callout)

            Spacer(minLength: 0)

            if editingShare == assignee.personID {
                TextField("Share", text: $shareDraft)
                    .frame(width: 56)
                    .onSubmit {
                        model.setAssigneeEstimate(Double(shareDraft), for: assignee.personID, on: task.id)
                        editingShare = nil
                    }
            } else {
                Button(assignee.estimate.map { format($0) } ?? "share") {
                    shareDraft = assignee.estimate.map { format($0) } ?? ""
                    editingShare = assignee.personID
                }
                .buttonStyle(.borderless)
                .font(.caption.monospacedDigit())
                .foregroundStyle(assignee.estimate == nil ? .secondary : .primary)
            }

            Button {
                model.removeAssignee(assignee.personID, from: task.id)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Take \(person?.name ?? "this person") off the card")
        }
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Where a card lives, and where else it is shown.
struct ListsSection: View {

    let task: BoardTask
    let model: BoardViewModel

    var body: some View {
        Section("Lists") {
            Picker("Home", selection: Binding(
                get: { task.listID ?? "" },
                set: { if !$0.isEmpty { model.setHomeList($0, forTask: task.id) } }
            )) {
                ForEach(model.lists) { list in
                    Text(list.name).tag(list.id)
                }
            }

            ForEach(model.extraLists(of: task)) { list in
                HStack {
                    Label(list.name, systemImage: "list.bullet")
                        .font(.callout)
                    Spacer()
                    Button {
                        model.removeTask(task.id, fromList: list.id)
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop showing this card in \(list.name)")
                }
            }

            Menu("Also Show In") {
                ForEach(availableLists) { list in
                    Button(list.name) { model.addTask(task.id, toList: list.id) }
                }
                if availableLists.isEmpty {
                    Text("There is nowhere else to put it.")
                }
            }

            if !model.extraLists(of: task).isEmpty {
                Text("One card, shown in several places. An edit anywhere is the same card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var availableLists: [TaskList] {
        let already = Set(model.extraLists(of: task).map(\.id) + [task.listID ?? ""])
        return model.lists.filter { !already.contains($0.id) }
    }
}

/// Whether a card comes back, and how.
struct RecurrenceSection: View {

    let task: BoardTask
    let model: BoardViewModel

    @State private var rule = RecurrenceRule()
    @State private var isOn = false
    @State private var loaded = false

    var body: some View {
        Section("Repeats") {
            Toggle("This card repeats", isOn: Binding(
                get: { isOn },
                set: { on in
                    isOn = on
                    if on { model.setRecurrence(rule, for: task.id) }
                    else { model.clearRecurrence(for: task.id) }
                }
            ))

            if isOn {
                Picker("Every", selection: binding(\.frequency)) {
                    ForEach(RecurrenceFrequency.allCases, id: \.self) { Text($0.label).tag($0) }
                }

                Stepper("Every \(rule.interval) \(unitName)", value: binding(\.interval), in: 1...52)

                if rule.frequency == .weekly {
                    weekdayPicker
                }

                if rule.frequency == .monthly {
                    monthlyShape
                }

                Picker("When", selection: binding(\.mode)) {
                    ForEach(RecurrenceMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }

                Text(rule.mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Untick the checklist each time", isOn: binding(\.resetChecklist))
                Toggle("Bring the subtasks back", isOn: binding(\.resetSubtasks))
                Toggle("Start again in the first column", isOn: binding(\.resetStatus))

                // The rule said back as one sentence, because a rule built out
                // of four controls is worth checking before it starts making
                // cards on its own.
                Label(rule.summary, systemImage: "repeat")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .onChange(of: task.id) { load() }
    }

    private func load() {
        guard let existing = model.recurrence(of: task.id) else {
            isOn = false
            rule = RecurrenceRule()
            loaded = true
            return
        }
        rule = existing.rule
        isOn = true
        loaded = true
    }

    /// Every control writes the whole rule back. One rule per card means there
    /// is no half-saved state to reconcile.
    private func binding<T>(_ path: WritableKeyPath<RecurrenceRule, T>) -> Binding<T> {
        Binding(
            get: { rule[keyPath: path] },
            set: { new in
                rule[keyPath: path] = new
                guard loaded, isOn else { return }
                model.setRecurrence(rule, for: task.id)
            }
        )
    }

    private var unitName: String {
        switch rule.frequency {
        case .daily: rule.interval == 1 ? "day" : "days"
        case .weekly: rule.interval == 1 ? "week" : "weeks"
        case .monthly: rule.interval == 1 ? "month" : "months"
        case .yearly: rule.interval == 1 ? "year" : "years"
        }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 3) {
            ForEach(1...7, id: \.self) { weekday in
                Button {
                    if rule.weekdays.contains(weekday) {
                        rule.weekdays.remove(weekday)
                    } else {
                        rule.weekdays.insert(weekday)
                    }
                    if isOn { model.setRecurrence(rule, for: task.id) }
                } label: {
                    Text(String(RecurrenceRule.weekdayName(weekday).prefix(1)))
                        .font(.caption)
                        .frame(width: 22, height: 22)
                        .background(
                            rule.weekdays.contains(weekday) ? Color.accentColor : Color.secondary.opacity(0.18),
                            in: Circle()
                        )
                        .foregroundStyle(rule.weekdays.contains(weekday) ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(RecurrenceRule.weekdayName(weekday))
            }
        }
    }

    /// The two shapes a monthly rule comes in — a date, or an *n*th weekday —
    /// are different questions, so they are chosen between rather than mixed.
    private var monthlyShape: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("On", selection: Binding(
                get: { rule.weekOfMonth == nil ? "day" : "weekday" },
                set: { shape in
                    if shape == "day" {
                        rule.weekOfMonth = nil
                        rule.monthDay = rule.monthDay ?? 1
                    } else {
                        rule.monthDay = nil
                        rule.weekOfMonth = rule.weekOfMonth ?? 1
                        if rule.weekdays.isEmpty { rule.weekdays = [2] }
                    }
                    if isOn { model.setRecurrence(rule, for: task.id) }
                }
            )) {
                Text("A day of the month").tag("day")
                Text("A weekday").tag("weekday")
            }
            .pickerStyle(.radioGroup)

            if rule.weekOfMonth == nil {
                Stepper("Day \(rule.monthDay ?? 1)", value: Binding(
                    get: { rule.monthDay ?? 1 },
                    set: { rule.monthDay = $0; if isOn { model.setRecurrence(rule, for: task.id) } }
                ), in: 1...31)

                Text("A month too short for it gets its last day, rather than spilling into the next.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("", selection: Binding(
                        get: { rule.weekOfMonth ?? 1 },
                        set: { rule.weekOfMonth = $0; if isOn { model.setRecurrence(rule, for: task.id) } }
                    )) {
                        Text("First").tag(1)
                        Text("Second").tag(2)
                        Text("Third").tag(3)
                        Text("Fourth").tag(4)
                        Text("Last").tag(-1)
                    }
                    .labelsHidden()
                    .fixedSize()

                    Picker("", selection: Binding(
                        get: { rule.weekdays.first ?? 2 },
                        set: { rule.weekdays = [$0]; if isOn { model.setRecurrence(rule, for: task.id) } }
                    )) {
                        ForEach(1...7, id: \.self) { Text(RecurrenceRule.weekdayName($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }
}

/// A date that matters, rather than work with a length.
struct MilestoneToggle: View {

    let task: BoardTask
    let model: BoardViewModel

    var body: some View {
        Toggle("This is a milestone", isOn: Binding(
            get: { task.isMilestone },
            set: { model.setMilestone($0, for: task.id) }
        ))
        .help("Drawn as a diamond on the timeline rather than a bar, because it has no length.")
    }
}
