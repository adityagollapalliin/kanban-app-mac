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
        case title, description, flag, estimate
    }

    @State private var title: String = ""
    @State private var descriptionMarkdown: String = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var newChecklistText = ""
    @State private var newSubtaskTitle = ""
    @State private var newLabelName = ""
    @State private var flagReason = ""
    @State private var estimateText = ""
    @State private var isShowingHistory = false
    @FocusState private var focused: Field?

    var body: some View {
        Form {
            titleSection
            flagSection
            placementSection
            dueSection
            estimateSection
            AssigneesSection(task: task, model: model)
            ListsSection(task: task, model: model)
            RecurrenceSection(task: task, model: model)
            SprintAndTimerSection(task: task, model: model)
            CardVocabularySection(task: task, model: model)
            CustomFieldSection(task: task, model: model)
            labelsSection
            checklistSection
            subtasksSection
            notesSection
            LinksSection(task: task, model: model)
            BacklinksSection(task: task, model: model)
            CommentsSection(task: task, model: model)
            AttachmentsSection(task: task, model: model)
            WorkLogSection(task: task, model: model)
            repositorySection
            historySection
            actionsSection
        }
        .formStyle(.grouped)
        .task(id: task.id) { loadFields() }
        // Focus leaving a text field is a finished edit. Committing here means
        // clicking straight onto another card does not lose what was typed.
        .onChange(of: focused) { previous, _ in
            if previous == .title { commitTitle() }
            if previous == .description { commitDescription() }
            if previous == .flag { commitFlagReason() }
            if previous == .estimate { commitEstimate() }
        }
        .onDisappear {
            commitTitle()
            commitDescription()
            commitFlagReason()
            commitEstimate()
        }
    }

    // MARK: - Sections

    /// The flag, above everything but the title.
    ///
    /// What is standing in a card's way is the first thing anyone opening it
    /// needs to know — ahead of where it sits, when it is due, or who has it.
    private var flagSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { task.flagged },
                set: { model.setFlag($0, reason: $0 ? flagReason : "", for: task.id) }
            )) {
                Label("Flagged", systemImage: task.flagged ? "flag.fill" : "flag")
                    .foregroundStyle(task.flagged ? Color.red : .primary)
            }

            if task.flagged {
                TextField("What is in the way?", text: $flagReason)
                    .focused($focused, equals: .flag)
                    .onSubmit(commitFlagReason)

                Text("Searchable: `flag = \"legal\"` finds everything held up by the same thing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Points and the release, together: both are answers to "how big is this
    /// and when is it going out".
    private var estimateSection: some View {
        Section("Size and release") {
            TextField("Points", text: $estimateText)
                .focused($focused, equals: .estimate)
                .onSubmit(commitEstimate)

            Picker("Release", selection: versionBinding) {
                Text("None").tag(String?.none)
                ForEach(model.versions) { version in
                    Text(version.name).tag(String?.some(version.id))
                }
            }
            .disabled(model.versions.isEmpty)

            // The column clock, in words rather than dots, because there is
            // room here for the exact answer.
            LabeledContent("In this column") {
                let days = task.daysInColumn(now: .now)
                Text(days == 1 ? "1 day" : "\(days) days")
                    .foregroundStyle(isStale ? Color.orange : .secondary)
            }
        }
    }

    /// Branches and commits in the linked checkout that name this card.
    ///
    /// Absent unless a repository has been linked, which is off by default.
    /// Nothing is fetched: this is what is already on this Mac.
    @ViewBuilder
    private var repositorySection: some View {
        let references = model.gitReferences(for: task)
        if !references.isEmpty {
            Section("In the repository") {
                ForEach(references) { reference in
                    Label {
                        Text(reference.text)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: reference.kind == .branch ? "arrow.triangle.branch" : "checkmark.seal")
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Read from the local checkout. Nothing is fetched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Where the card has been, newest first.
    private var historySection: some View {
        Section {
            DisclosureGroup("History", isExpanded: $isShowingHistory) {
                let history = model.history(of: task.id).reversed()
                ForEach(Array(history)) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(change.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if let from = change.fromStatusID {
                            Text("\(model.statusName(from)) → \(model.statusName(change.toStatusID))")
                                .font(.caption)
                        } else {
                            Text("Created in \(model.statusName(change.toStatusID))")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var isStale: Bool {
        task.daysInColumn(now: .now) >= (model.snapshot?.board.staleDays ?? 3)
    }

    private var versionBinding: Binding<String?> {
        Binding(
            get: { task.versionID },
            set: { model.setVersion($0, for: task.id) }
        )
    }

    private func commitFlagReason() {
        let trimmed = flagReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.flagged, trimmed != task.flagReason else { return }
        model.setFlag(true, reason: trimmed, for: task.id)
    }

    /// An empty field means unestimated, which is different from zero: a card
    /// nobody has sized is not a card everyone agreed was free.
    private func commitEstimate() {
        let trimmed = estimateText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            if task.estimate != nil { model.setEstimate(nil, for: task.id) }
            return
        }
        guard let value = Double(trimmed) else {
            estimateText = task.estimate.map { String(format: "%g", $0) } ?? ""
            return
        }
        guard value != task.estimate else { return }
        model.setEstimate(value, for: task.id)
    }

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
                // Only the moves whose conditions this card satisfies, plus
                // the column it is already in.
                ForEach(model.offeredStatuses(for: task)) { status in
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

            MilestoneToggle(task: task, model: model)
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

    /// A snoozed card says when it comes back, because the whole point of a
    /// snooze is that nothing else will remind you.
    private var snoozeLabel: String {
        guard let until = task.snoozedUntil, until > .now else { return "Snooze" }
        return "Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))"
    }

    private var actionsSection: some View {
        Section {
            // Setting a card aside is not closing it: the tray keeps several
            // to hand at once without a window each.
            Button("Set Aside in the Tray", systemImage: "tray.and.arrow.down") {
                model.addToTray(task.id)
            }

            Menu {
                ForEach(SnoozeOption.allCases, id: \.self) { option in
                    Button(option.label) { model.snooze(task.id, option) }
                }
                if task.snoozedUntil != nil {
                    Divider()
                    Button("Wake It Now") { model.wake(task.id) }
                }
            } label: {
                Label(snoozeLabel, systemImage: "zzz")
            }

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
        flagReason = task.flagReason
        estimateText = task.estimate.map { String(format: "%g", $0) } ?? ""
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
