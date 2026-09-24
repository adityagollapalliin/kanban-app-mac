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
        }
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

    private func checkboxBinding(_ field: CustomField, _ value: CustomFieldValue?) -> Binding<Bool> {
        Binding(
            get: { if case .checkbox(let ticked)? = value { ticked } else { false } },
            // An unticked box is nothing to say, so it clears rather than
            // storing "false" — which keeps `cf:Signed = none` meaningful.
            set: { set($0 ? .checkbox(true) : nil, field) }
        )
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
