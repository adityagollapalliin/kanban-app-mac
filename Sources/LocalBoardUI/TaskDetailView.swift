import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The inspector for one card.
///
/// Text fields hold a local copy and write when the user finishes with them —
/// on return, or on moving focus elsewhere. Writing every keystroke would put
/// a transaction and a full board reload behind each letter typed. Pickers and
/// the date write immediately, because a choice has no half-finished state.
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
    @FocusState private var focused: Field?

    var body: some View {
        Form {
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
                    Spacer()
                }
            }

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

                Picker("Assignee", selection: assigneeBinding) {
                    Text("Unassigned").tag(String?.none)
                    ForEach(model.people) { person in
                        Text(person.name).tag(String?.some(person.id))
                    }
                }
                // With nobody added yet the picker has one entry and no
                // purpose; the hint says where people come from.
                .help(model.people.isEmpty
                      ? "Add people in Settings, or with `localboard people add`"
                      : "Who is carrying this card")
            }

            Section("Due") {
                Toggle("Has a due date", isOn: dueToggleBinding)

                if hasDueDate {
                    DatePicker(
                        "Due",
                        selection: dueDateBinding,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                }
            }

            Section("Notes") {
                TextEditor(text: $descriptionMarkdown)
                    .font(.body)
                    .frame(minHeight: 120)
                    .focused($focused, equals: .description)
                    .accessibilityLabel("Task notes")
            }

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

    private var assigneeBinding: Binding<String?> {
        Binding(get: { task.assigneeID }, set: { model.setAssignee($0, for: task.id) })
    }

    private var priorityBinding: Binding<Priority> {
        Binding(get: { task.priority }, set: { model.setPriority($0, for: task.id) })
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
