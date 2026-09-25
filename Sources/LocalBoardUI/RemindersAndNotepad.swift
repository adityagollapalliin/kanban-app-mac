import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// Reminders: things to be reminded about that are not work.
///
/// Deliberately not cards. "Ring the dentist" has no column, no assignee and
/// no estimate, and making it a task would put it into the project's
/// cycle-time statistics and onto somebody's workload bar.
struct RemindersView: View {

    let model: BoardViewModel

    @State private var draft = ""
    @State private var showsDone = false

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()

            if visible.isEmpty {
                ContentUnavailableView(
                    "No reminders",
                    systemImage: "bell",
                    description: Text("Type one above. “Ring the dentist tomorrow 3pm” sets its own time.")
                )
            } else {
                List {
                    ForEach(visible) { reminder in
                        row(reminder)
                    }
                }
            }
        }
        .onAppear { model.loadReminders() }
    }

    private var visible: [Reminder] {
        showsDone ? model.reminders : model.reminders.filter { !$0.isDone }
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell")
                .foregroundStyle(.secondary)

            TextField("Remind me to…", text: $draft)
                .textFieldStyle(.plain)
                .onSubmit(add)

            if !draft.isEmpty {
                // The same hint line as quick-add, so what the parser
                // understood is visible before it is committed to.
                QuickAddHints(result: model.preview(draft), model: model)
            }

            Toggle("Done", isOn: $showsDone)
                .toggleStyle(.button)
                .buttonStyle(.accessoryBar)
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.addReminder(text)
        draft = ""
    }

    private func row(_ reminder: Reminder) -> some View {
        HStack(spacing: 8) {
            Button {
                model.setReminderDone(!reminder.isDone, for: reminder.id)
            } label: {
                Image(systemName: reminder.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reminder.isDone ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.isDone ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title)
                    .strikethrough(reminder.isDone)
                    .foregroundStyle(reminder.isDone ? .secondary : .primary)

                if let due = reminder.dueAt {
                    Text(due.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isLate(reminder) ? .red : .secondary)
                }
            }

            Spacer(minLength: 0)

            if let until = reminder.snoozedUntil, until > .now {
                Label(until.formatted(date: .abbreviated, time: .shortened), systemImage: "zzz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Menu {
                ForEach(SnoozeOption.allCases, id: \.self) { option in
                    Button(option.label) { model.snoozeReminder(reminder.id, option) }
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    model.deleteReminder(reminder.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(reminder.title)
    }

    private func isLate(_ reminder: Reminder) -> Bool {
        guard let due = reminder.dueAt, !reminder.isDone else { return false }
        return due < .now && !reminder.isSnoozed(now: .now)
    }
}

/// What quick-add understood, shown while it is being typed.
///
/// A parser that silently ate a word is worse than one that did not try, so
/// everything it took is on screen before the card is made.
struct QuickAddHints: View {

    let result: QuickAddResult
    let model: BoardViewModel

    var body: some View {
        HStack(spacing: 5) {
            if let due = result.dueDate {
                chip(
                    due.formatted(
                        date: .abbreviated,
                        time: result.hasTime ? .shortened : .omitted
                    ),
                    symbol: "calendar"
                )
            }
            if let priority = result.priority {
                chip(CardAppearance.label(forPriority: priority),
                     symbol: CardAppearance.symbol(forPriority: priority))
            }
            ForEach(result.labels, id: \.self) { label in
                chip(label, symbol: "tag", known: model.labels.contains { $0.name.lowercased() == label.lowercased() })
            }
            ForEach(result.assignees, id: \.self) { name in
                chip(name, symbol: "person",
                     known: model.people.contains { $0.name.lowercased().hasPrefix(name.lowercased()) })
            }
        }
        .accessibilityHidden(result.isBare)
    }

    /// A tag or name that matches nothing is drawn faintly rather than
    /// hidden: it tells you the card will not get it, before you press Return.
    private func chip(_ text: String, symbol: String, known: Bool = true) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(known ? Color.accentColor : .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                (known ? Color.accentColor : Color.secondary).opacity(0.12),
                in: Capsule()
            )
            .help(known ? text : "\(text) — nothing here is called that, so it will be left off")
    }
}

/// A scratch pad that is always the same pad.
///
/// One pad, not many: a pad you have to name and file is a document, and the
/// point of this one is that it needs no decision to start writing in.
struct NotepadView: View {

    let model: BoardViewModel

    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Notepad")
                    .font(.headline)

                Text("Any line can become a card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button {
                    text.append(text.isEmpty ? "- [ ] " : "\n- [ ] ")
                } label: {
                    Label("Checklist line", systemImage: "checklist")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            HStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .onChange(of: text) { model.saveNotepad(text) }

                Divider()
                lines
            }
        }
        .onAppear {
            model.loadNotepad()
            text = model.notepad
            loaded = true
        }
    }

    /// Each line with a button beside it. A line becomes a card and is ticked
    /// off in the pad, so the same line cannot quietly become two cards.
    private var lines: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(actionable.enumerated()), id: \.offset) { _, line in
                    Button {
                        model.makeCard(fromNotepadLine: line)
                        text = model.notepad
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.right.circle")
                                .font(.caption)
                            Text(line.trimmingCharacters(in: .whitespaces))
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Make a card out of this line")
                }

                if actionable.isEmpty {
                    Text("Lines starting with “- ” can be made into cards.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(10)
        }
        .frame(width: 240)
    }

    /// Only the unticked list lines. A line already ticked has been dealt
    /// with, and offering to make a card of it again is how duplicates happen.
    private var actionable: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { return false }
                return !trimmed.hasPrefix("- [x]")
            }
    }
}

/// Cards set aside rather than closed.
///
/// The inspector shows one card. The tray is how several stay to hand without
/// a window each — a row of names along the bottom, one click back into any
/// of them.
struct TaskTray: View {

    let model: BoardViewModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.trayTaskIDs, id: \.self) { id in
                if let task = model.task(id: id) {
                    Button {
                        model.restoreFromTray(id)
                    } label: {
                        HStack(spacing: 4) {
                            Text(model.tag(for: task))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(task.title)
                                .font(.caption)
                                .lineLimit(1)
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .onTapGesture { model.removeFromTray(id) }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 200)
                    .help("Open \(task.title) again")
                }
            }

            Spacer(minLength: 0)

            Button("Clear") { model.clearTray() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.trayTaskIDs.count) cards set aside")
    }
}
