import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The inspector for one card.
///
/// Text fields hold a local copy and write when the user finishes with them —
/// on return, or on moving focus elsewhere. Writing every keystroke would put
/// a transaction and a full board reload behind each letter typed. Pickers,
/// toggles and the date write immediately, because a choice has no
/// half-finished state.
///
/// The sections are separate properties rather than one long `Form`: SwiftUI's
/// type checker gives up on a body this size, and they read better named.
struct TaskDetailView: View {

    let task: BoardTask
    let model: BoardViewModel

    private enum Field: Hashable {
        case title, description
    }

    @State private var title: String = ""
    @State private var descriptionMarkdown: String = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var newChecklistText = ""
    @State private var newSubtaskTitle = ""
    @State private var newLabelName = ""
    @FocusState private var focused: Field?

    var body: some View {
        Form {
            titleSection
            placementSection
            dueSection
            labelsSection
            checklistSection
            subtasksSection
            notesSection
            actionsSection
        }
        .formStyle(.grouped)
        .task(id: task.id) { loadFields() }
        // Focus leaving a text field is a finished edit. Committing here means
        // clicking straight onto another card does not lose what was typed.
        .onChange(of: focused) { previous, _ in
            if previous == .title { commitTitle() }
            if previous == .description { commitDescription() }
        }
        .onDisappear {
            commitTitle()
            commitDescription()
        }
    }

    // MARK: - Sections

    private var titleSection: some View {
        Section {
            TextField("Title", text: $title, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused, equals: .title)
                .onSubmit(commitTitle)
                .accessibilityLabel("Task title")
        } header: {
            HStack(spacing: 6) {
                Text(model.tag(for: task))
                    .font(.caption.monospaced())
                if task.parentID != nil {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("This is a subtask")
                }
                Spacer()
            }
        }
    }

    private var placementSection: some View {
        Section("Placement") {
            Picker("Status", selection: statusBinding) {
                ForEach(model.statuses) { status in
                    Text(status.name).tag(status.id)
                }
            }

            Picker("Type", selection: typeBinding) {
                ForEach(TaskType.allCases, id: \.self) { type in
                    Text(label(for: type)).tag(type)
                }
            }

            Picker("Priority", selection: priorityBinding) {
                ForEach(Priority.allCases, id: \.self) { priority in
                    Text(label(for: priority)).tag(priority)
                }
            }

            Picker("Epic", selection: epicBinding) {
                Text("None").tag(String?.none)
                ForEach(model.epics.filter { $0.id != task.id }) { epic in
                    Text(epic.title).tag(String?.some(epic.id))
                }
            }
            .help(model.epics.isEmpty
                  ? "Make a card of type Epic and other cards can be filed under it"
                  : "The epic this rolls up to")

            Picker("Assignee", selection: assigneeBinding) {
                Text("Unassigned").tag(String?.none)
                ForEach(model.people) { person in
                    Text(person.name).tag(String?.some(person.id))
                }
            }
            .help(model.people.isEmpty
                  ? "Add people in Settings, or with `localboard people add`"
                  : "Who is carrying this card")
        }
    }

    private var dueSection: some View {
        Section("Due") {
            Toggle("Has a due date", isOn: dueToggleBinding)

            if hasDueDate {
                DatePicker("Due", selection: dueDateBinding, displayedComponents: .date)
                    .datePickerStyle(.compact)
            }
        }
    }

    @ViewBuilder
    private var labelsSection: some View {
        Section("Labels") {
            if model.labels.isEmpty {
                Text("No labels in this project yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.labels) { label in
                Toggle(isOn: labelBinding(label)) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(PaletteColor.named(label.color).color)
                            .frame(width: 8, height: 8)
                        Text(label.name)
                    }
                }
            }

            addRow(placeholder: "New label", text: $newLabelName, action: addLabel)
        }
    }

    @ViewBuilder
    private var checklistSection: some View {
        Section("Checklist") {
            if let progress = model.checklistProgress(for: task), progress.total > 0 {
                ProgressView(value: progress.fraction) {
                    Text("\(progress.done) of \(progress.total) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(model.checklist) { item in
                checklistRow(item)
            }

            addRow(placeholder: "Add a step", text: $newChecklistText, action: addChecklistItem)
        }
    }

    private func checklistRow(_ item: ChecklistItem) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { item.done },
                set: { model.setChecklistItem(item.id, done: $0) }
            )) {
                Text(item.text)
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? Color.secondary : Color.primary)
            }

            Spacer(minLength: 0)

            Button {
                model.deleteChecklistItem(item.id)
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(item.text)")
        }
    }

    @ViewBuilder
    private var subtasksSection: some View {
        Section("Subtasks") {
            ForEach(model.subtasks) { subtask in
                subtaskRow(subtask)
            }

            addRow(placeholder: "Add a subtask", text: $newSubtaskTitle, action: addSubtask)
        }
    }

    private func subtaskRow(_ subtask: BoardTask) -> some View {
        HStack(spacing: 6) {
            Image(systemName: subtask.completedAt == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(subtask.completedAt == nil ? Color.secondary : Color.green)

            Text(subtask.title)
                .lineLimit(1)

            Spacer(minLength: 0)

            // Opening a subtask is opening a card: it has its own labels,
            // checklist and subtasks like any other.
            Button("Open") { model.selectedTaskID = subtask.id }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextEditor(text: $descriptionMarkdown)
                .font(.body)
                .frame(minHeight: 120)
                .focused($focused, equals: .description)
                .accessibilityLabel("Task notes")
        }
    }

    private var actionsSection: some View {
        Section {
            if task.trashed {
                Button("Put Back", systemImage: "arrow.uturn.backward") {
                    model.restore(task.id)
                }
            } else {
                Button("Move to Trash", systemImage: "trash", role: .destructive) {
                    model.setTrashed(true, for: task.id)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if task.trashed {
                    Text("In the trash. Nothing has been deleted.")
                        .foregroundStyle(.secondary)
                }
                Text("Created \(task.createdAt.formatted(date: .abbreviated, time: .shortened))")
                Text("Updated \(task.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                if let completed = task.completedAt {
                    Text("Completed \(completed.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// The same shape in three places: type something, press return or Add.
    private func addRow(placeholder: String, text: Binding<String>, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(action)

            Button("Add", action: action)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Local copies

    private func loadFields() {
        title = task.title
        descriptionMarkdown = task.descriptionMarkdown
        hasDueDate = task.dueDate != nil
        dueDate = task.dueDate ?? Date()
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty title is a slip, not an instruction. Put the old one back
        // rather than rejecting the edit with an error the user must dismiss.
        guard !trimmed.isEmpty else {
            title = task.title
            return
        }
        guard trimmed != task.title else { return }
        model.rename(task.id, to: trimmed)
    }

    private func commitDescription() {
        guard descriptionMarkdown != task.descriptionMarkdown else { return }
        model.setDescription(descriptionMarkdown, for: task.id)
    }

    private func addLabel() {
        let name = newLabelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.createLabel(named: name)
        // Making a label from a card almost always means putting it on that
        // card, so the new one goes straight on.
        if let created = model.labels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            model.setLabel(created.id, on: task.id, attached: true)
        }
        newLabelName = ""
    }

    private func addChecklistItem() {
        let text = newChecklistText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.addChecklistItem(text, to: task.id)
        newChecklistText = ""
    }

    private func addSubtask() {
        let title = newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        model.addSubtask(title, to: task.id)
        newSubtaskTitle = ""
    }

    // MARK: - Immediate bindings

    private var statusBinding: Binding<String> {
        Binding(
            get: { task.statusID },
            set: { model.moveToEnd(of: $0, taskID: task.id) }
        )
    }

    private var typeBinding: Binding<TaskType> {
        Binding(get: { task.type }, set: { model.setType($0, for: task.id) })
    }

    private var priorityBinding: Binding<Priority> {
        Binding(get: { task.priority }, set: { model.setPriority($0, for: task.id) })
    }

    private var epicBinding: Binding<String?> {
        Binding(get: { task.epicID }, set: { model.setEpic($0, for: task.id) })
    }

    private var assigneeBinding: Binding<String?> {
        Binding(get: { task.assigneeID }, set: { model.setAssignee($0, for: task.id) })
    }

    private func labelBinding(_ label: CardLabel) -> Binding<Bool> {
        Binding(
            get: { model.labels(for: task).contains { $0.id == label.id } },
            set: { model.setLabel(label.id, on: task.id, attached: $0) }
        )
    }

    private var dueToggleBinding: Binding<Bool> {
        Binding(
            get: { hasDueDate },
            set: { isOn in
                hasDueDate = isOn
                model.setDueDate(isOn ? dueDate : nil, for: task.id)
            }
        )
    }

    private var dueDateBinding: Binding<Date> {
        Binding(
            get: { dueDate },
            set: { newValue in
                dueDate = newValue
                model.setDueDate(newValue, for: task.id)
            }
        )
    }

    // MARK: - Labels

    private func label(for type: TaskType) -> String {
        switch type {
        case .epic: "Epic"
        case .story: "Story"
        case .task: "Task"
        case .bug: "Bug"
        }
    }

    private func label(for priority: Priority) -> String {
        switch priority {
        case .lowest: "Lowest"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .highest: "Highest"
        }
    }
}
