import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The project's own fields on one card.
///
/// One control per kind rather than a text box for everything: a date field
/// that takes typed text is a date field people get wrong, and a choice field
/// that does not offer the choices is a list nobody can remember.
struct CustomFieldSection: View {

    let task: BoardTask
    let model: BoardViewModel

    var body: some View {
        if !model.customFields.isEmpty {
            Section("Fields") {
                ForEach(model.customFields) { field in
                    row(field)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ field: CustomField) -> some View {
        let value = model.customValues(for: task)[field.id]

        switch field.kind {
        case .text:
            TextField(field.name, text: textBinding(field, value))

        case .number:
            TextField(field.name, text: numberBinding(field, value))

        case .date:
            // A toggle beside it, because "no date" is a real answer and a
            // date picker on its own has no way to say it.
            HStack {
                Toggle(isOn: dateToggle(field, value)) { Text(field.name) }
                    .toggleStyle(.checkbox)
                if case .date(let day)? = value {
                    DatePicker("", selection: dateBinding(field, day), displayedComponents: .date)
                        .labelsHidden()
                }
            }

        case .choice:
            Picker(field.name, selection: choiceBinding(field, value)) {
                Text("—").tag(String?.none)
                ForEach(field.options, id: \.self) { option in
                    Text(option).tag(String?.some(option))
                }
            }

        case .checkbox:
            Toggle(field.name, isOn: checkboxBinding(field, value))

        case .money:
            // The currency belongs to the field, so it is a label beside the
            // box rather than something to type into it.
            HStack {
                TextField(field.name, text: numberBinding(field, value))
                Text(field.currency)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .rating:
            RatingField(name: field.name, stars: ratingBinding(field, value))

        case .progress:
            ProgressField(
                name: field.name,
                mode: field.progressMode,
                percent: progressBinding(field, value),
                automatic: automaticPercent(field)
            )

        case .relationship:
            RelationshipField(field: field, task: task, model: model)

        case .formula, .rollup:
            // Nothing to edit: a computed field is read, and the only useful
            // thing to say beside it is where the figure came from.
            LabeledContent(field.name) {
                let computed = model.computedValue(field.id, for: task.id)
                Text(computed.isEmpty ? "—" : model.display(field, for: task))
                    .foregroundStyle(computed.isEmpty ? .secondary : .primary)
                    .help(explanation(of: field))
            }
        }
    }

    /// What a computed field is working from, for the tooltip beside it.
    private func explanation(of field: CustomField) -> String {
        switch field.kind {
        case .formula:
            return field.formula
        case .rollup:
            let source = field.rollupSource == .subtasks ? "the subtasks" : "the related cards"
            return "\(field.rollupFunction.label) of \(source)"
        default:
            return ""
        }
    }

    /// The percentage a progress field is counting for itself, if it is.
    private func automaticPercent(_ field: CustomField) -> Double? {
        guard field.progressMode != .manual else { return nil }
        guard case .number(let percent) = model.computedValue(field.id, for: task.id) else { return nil }
        return percent
    }

    // MARK: - Bindings

    private func set(_ value: CustomFieldValue?, _ field: CustomField) {
        model.setCustomValue(value, forField: field.id, on: task.id)
    }

    private func textBinding(_ field: CustomField, _ value: CustomFieldValue?) -> Binding<String> {
        Binding(
            get: { if case .text(let text)? = value { text } else { "" } },
            set: { set(.text($0), field) }
        )
    }

    /// Typed text that is not a number leaves the stored value alone rather
    /// than clearing it: half of "12" is "1", and every keystroke would
    /// otherwise be a write.
    private func numberBinding(_ field: CustomField, _ value: CustomFieldValue?) -> Binding<String> {
        Binding(
            get: {
                if case .number(let amount)? = value {
                    amount == amount.rounded() ? String(Int(amount)) : String(amount)
                } else { "" }
            },
            set: { typed in
                let trimmed = typed.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    set(nil, field)
                } else if let amount = Double(trimmed) {
                    set(.number(amount), field)
                }
            }
        )
    }

    private func dateToggle(_ field: CustomField, _ value: CustomFieldValue?) -> Binding<Bool> {
        Binding(
            get: { if case .date? = value { true } else { false } },
            set: { on in set(on ? .date(Date()) : nil, field) }
        )
    }

    private func dateBinding(_ field: CustomField, _ current: Date) -> Binding<Date> {
        Binding(get: { current }, set: { set(.date($0), field) })
    }

    private func choiceBinding(_ field: CustomField, _ value: CustomFieldValue?) -> Binding<String?> {
        Binding(
            get: { if case .choice(let choice)? = value { choice } else { nil } },
            set: { set($0.map(CustomFieldValue.choice), field) }
        )
    }

    private func ratingBinding(_ field: CustomField, _ value: CustomFieldValue?) -> Binding<Int> {
        Binding(
            get: { if case .number(let stars)? = value { Int(stars) } else { 0 } },
            // No stars is no answer, so it clears rather than storing zero —
            // which keeps a rating column sortable without a floor of noughts.
            set: { set($0 <= 0 ? nil : .number(Double(min($0, 5))), field) }
        )
    }

    private func progressBinding(_ field: CustomField, _ value: CustomFieldValue?) -> Binding<Double> {
        Binding(
            get: { if case .number(let percent)? = value { percent } else { 0 } },
            set: { set(.number(min(max($0, 0), 100)), field) }
        )
    }

    private func checkboxBinding(_ field: CustomField, _ value: CustomFieldValue?) -> Binding<Bool> {
        Binding(
            get: { if case .checkbox(let ticked)? = value { ticked } else { false } },
            // An unticked box is nothing to say, so it clears rather than
            // storing "false" — which keeps `cf:Signed = none` meaningful.
            set: { set($0 ? .checkbox(true) : nil, field) }
        )
    }
}

/// Five stars, clickable.
///
/// Clicking the star that is already the rating clears it, because otherwise
/// a one-star rating is the only one nobody can take back.
struct RatingField: View {
    let name: String
    @Binding var stars: Int

    var body: some View {
        LabeledContent(name) {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { position in
                    Button {
                        stars = (stars == position) ? 0 : position
                    } label: {
                        Image(systemName: position <= stars ? "star.fill" : "star")
                            .foregroundStyle(position <= stars ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(position == stars ? "Clear the rating" : "\(position) of 5")
                }
                if stars > 0 {
                    Text("\(stars)/5")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

/// A percentage, either typed in or counted.
///
/// When it counts itself there is nothing to drag, so the slider is replaced
/// by the bar and a line saying where the figure comes from — a control that
/// looks adjustable and is not is worse than no control.
struct ProgressField: View {
    let name: String
    let mode: ProgressMode
    @Binding var percent: Double
    let automatic: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text("\(Int((automatic ?? percent).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let automatic {
                ProgressView(value: automatic, total: 100)
                Text(mode == .subtasks ? "Counted from the subtasks" : "Counted from the checklist")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if mode == .manual {
                Slider(value: $percent, in: 0...100, step: 5)
            } else {
                ProgressView(value: 0, total: 100)
                Text(mode == .subtasks ? "No subtasks yet" : "Nothing on the checklist yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Cards this one is linked to, through a relationship field.
struct RelationshipField: View {
    let field: CustomField
    let task: BoardTask
    let model: BoardViewModel

    @State private var isPicking = false

    private var related: [BoardTask] { model.relatedTasks(field, for: task) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.name)
                Spacer()
                Button("Link…", systemImage: "plus") { isPicking = true }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("Link a card to this one")
            }

            if related.isEmpty {
                Text("Nothing linked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(related) { other in
                    HStack(spacing: 6) {
                        Text(model.tag(for: other))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Button(other.title) { model.selectedTaskID = other.id }
                            .buttonStyle(.plain)
                            .lineLimit(1)
                        Spacer()
                        Button("Unlink", systemImage: "minus.circle") {
                            model.setRelated(
                                related.map(\.id).filter { $0 != other.id }, field: field, on: task.id
                            )
                        }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $isPicking) {
            RelationshipPicker(field: field, task: task, model: model, alreadyLinked: Set(related.map(\.id)))
        }
    }
}

/// Picking a card to link to.
struct RelationshipPicker: View {
    let field: CustomField
    let task: BoardTask
    let model: BoardViewModel
    let alreadyLinked: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// Capped, because this is a list inside a sheet: a thousand rows would be
    /// a thousand nobody scrolls to. Typing narrows it, which is how anybody
    /// finds a card anyway.
    private var choices: [BoardTask] {
        let all = model.relationshipChoices(for: field)
            .filter { $0.id != task.id && !alreadyLinked.contains($0.id) }
        let trimmed = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = trimmed.isEmpty ? all : all.filter { $0.title.lowercased().contains(trimmed) }
        return Array(matching.prefix(100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Link a card to \(task.title)")
                .font(.headline)
                .padding()

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            List(choices) { other in
                Button {
                    model.setRelated(
                        Array(alreadyLinked) + [other.id], field: field, on: task.id
                    )
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Text(model.tag(for: other))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(other.title).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 240)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 400)
    }
}

/// The sprint a card is in, and the timer running on it.
struct SprintAndTimerSection: View {

    let task: BoardTask
    let model: BoardViewModel

    /// Ticks the elapsed display. One second is the smallest unit anybody
    /// reads off a timer, and nothing else on this screen needs a clock.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section("Sprint and time") {
            Picker("Sprint", selection: sprintBinding) {
                Text("None").tag(String?.none)
                ForEach(model.sprints.filter { $0.state != .complete }) { sprint in
                    Text(sprint.name).tag(String?.some(sprint.id))
                }
            }
            .disabled(model.sprints.allSatisfy { $0.state == .complete })

            if let running = model.runningTimer, running.taskID == task.id {
                HStack {
                    Label(running.elapsed(now: now), systemImage: "stopwatch")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Stop") { model.stopTimer() }
                    Button("Discard") { model.stopTimer(discarding: true) }
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Start Timer", systemImage: "play.circle") {
                    model.startTimer(on: task.id)
                }
                .help(model.runningTimer == nil
                      ? "Time spent on this card"
                      : "Stops the timer running on another card first")
            }
        }
        .onReceive(tick) { now = $0 }
    }

    private var sprintBinding: Binding<String?> {
        Binding(
            get: { task.sprintID },
            set: { model.setSprint($0, for: task.id) }
        )
    }
}

/// The running timer, in the toolbar.
///
/// It belongs here rather than only on the card because a timer is running
/// whether or not the card that owns it is on screen — and a timer you have
/// forgotten about is the way time tracking stops being trusted.
struct TimerToolbarItem: View {

    let task: BoardTask
    let model: BoardViewModel

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Button {
            model.selectedTaskID = task.id
        } label: {
            Label(model.runningTimer?.elapsed(now: now) ?? "0:00", systemImage: "stopwatch.fill")
                .labelStyle(.titleAndIcon)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.red)
        }
        .help("Timing \(model.tag(for: task)) — \(task.title). Click to open it.")
        .onReceive(tick) { now = $0 }
        .contextMenu {
            Button("Stop and Log") { model.stopTimer() }
            Button("Discard", role: .destructive) { model.stopTimer(discarding: true) }
        }
    }
}
