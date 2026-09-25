import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// What the space is aiming at.
///
/// A goal is a bar and a number, so the screen is a list of bars rather than a
/// grid or a chart: the question it answers is "are we going to make it", and
/// that is read one line at a time.
struct GoalsView: View {

    let model: BoardViewModel

    @State private var isAdding = false
    @State private var editing: Goal?
    @State private var isNamingFolder = false
    @State private var folderName = ""
    @State private var showsArchived = false

    /// The folders, plus the goals that are in no folder at all — which are
    /// ordinary rather than a leftover, so they are drawn the same way.
    private var sections: [(folder: GoalFolder?, goals: [Goal])] {
        var built: [(GoalFolder?, [Goal])] = []
        let loose = model.goals(inFolder: nil)
        if !loose.isEmpty { built.append((nil, loose)) }
        for folder in model.goalFolders {
            built.append((folder, model.goals(inFolder: folder.id)))
        }
        return built.map { (folder: $0.0, goals: $0.1) }
    }

    var body: some View {
        Group {
            if model.goals.isEmpty && model.goalFolders.isEmpty {
                ContentUnavailableView {
                    Label("No goals yet", systemImage: "target")
                } description: {
                    Text("A goal is a number you want to reach by a date — revenue, cards finished, or simply done or not.")
                } actions: {
                    Button("Add a goal") { isAdding = true }
                }
            } else {
                List {
                    ForEach(sections, id: \.folder?.id) { section in
                        Section {
                            if section.goals.isEmpty {
                                Text("Nothing in here yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(section.goals) { goal in
                                GoalRow(goal: goal, model: model) { editing = goal }
                            }
                        } header: {
                            if let folder = section.folder {
                                HStack {
                                    Label(folder.name, systemImage: "folder")
                                    Spacer()
                                    Button("Delete folder", systemImage: "trash") {
                                        model.deleteGoalFolder(folder.id)
                                    }
                                    .buttonStyle(.borderless)
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.secondary)
                                    .help("The goals in it move up to the space; nothing is thrown away.")
                                }
                            } else {
                                Text("Goals")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Goals")
        .toolbar {
            ToolbarItemGroup {
                Button("New Folder", systemImage: "folder.badge.plus") {
                    folderName = ""
                    isNamingFolder = true
                }
                Button("New Goal", systemImage: "plus") { isAdding = true }
            }
        }
        // Recounted on arrival rather than on every card move: a goal a few
        // seconds behind is a better trade than every drag on the board going
        // looking for goals that might care.
        .task(id: model.goals.count) { model.refreshGoals() }
        .sheet(isPresented: $isAdding) { GoalEditor(model: model, goal: nil) }
        .sheet(item: $editing) { goal in GoalEditor(model: model, goal: goal) }
        .alert("New folder", isPresented: $isNamingFolder) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { model.createGoalFolder(named: folderName) }
        }
    }
}

/// One goal: a bar, where it stands, and when it is due.
struct GoalRow: View {

    let goal: Goal
    let model: BoardViewModel
    let onEdit: () -> Void

    @State private var typed = ""
    @State private var isTyping = false

    private var isLate: Bool { goal.isOverdue(now: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: goal.kind.symbol)
                    .foregroundStyle(.secondary)
                Text(goal.name)
                    .font(.headline)
                if goal.isMet {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .help("Met")
                }
                Spacer()
                Text(goal.percentDescription)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(goal.isMet ? .green : .secondary)
            }

            ProgressView(value: goal.fraction)
                .tint(goal.isMet ? .green : (isLate ? .orange : .accentColor))

            HStack(spacing: 10) {
                Text(goal.progressDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let due = goal.dueAt {
                    Label(dueText(due), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(isLate ? .orange : .secondary)
                }

                if goal.kind.isAutomatic {
                    Label("Counted from the cards", systemImage: "wand.and.stars")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(goal.query.isEmpty ? "Every card in the space" : goal.query)
                }

                Spacer()

                // Only a goal somebody keeps by hand has a figure to type.
                if !goal.kind.isAutomatic {
                    if isTyping {
                        TextField("Now", text: $typed)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit(commit)
                        Button("Save", action: commit).buttonStyle(.borderless)
                    } else {
                        Button("Update") {
                            typed = Goal.plain(goal.current)
                            isTyping = true
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if !goal.notes.isEmpty {
                Text(goal.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Menu("Move to") {
                Button("No folder") { model.setGoalFolder(nil, for: goal.id) }
                ForEach(model.goalFolders) { folder in
                    Button(folder.name) { model.setGoalFolder(folder.id, for: goal.id) }
                }
            }
            Button("Archive") { model.archiveGoal(goal.id) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteGoal(goal.id) }
        }
    }

    private func commit() {
        // Rubbish typed into the box leaves the figure alone rather than
        // zeroing a goal somebody has been keeping for a quarter.
        if let value = Double(typed.trimmingCharacters(in: .whitespaces)) {
            model.setGoalCurrent(value, for: goal.id)
        }
        isTyping = false
    }

    private func dueText(_ due: Date) -> String {
        guard let days = goal.daysRemaining(from: Date()) else { return "" }
        if days == 0 { return "Due today" }
        if days > 0 { return days == 1 ? "1 day left" : "\(days) days left" }
        return days == -1 ? "1 day late" : "\(-days) days late"
    }
}

/// Making a goal, or changing one.
struct GoalEditor: View {

    let model: BoardViewModel
    let goal: Goal?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var notes = ""
    @State private var kind: GoalKind = .number
    @State private var start = "0"
    @State private var target = "10"
    @State private var currency = "USD"
    @State private var query = ""
    @State private var listID: String?
    @State private var folderID: String?
    @State private var hasDueDate = false
    @State private var dueDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(goal == nil ? "New goal" : "Edit goal")
                .font(.headline)
                .padding()

            Form {
                TextField("Name", text: $name)

                Picker("Measured as", selection: $kind) {
                    ForEach(GoalKind.allCases, id: \.self) { option in
                        Label(option.label, systemImage: option.symbol).tag(option)
                    }
                }

                switch kind {
                case .boolean:
                    // Nothing to set: the target is "done", which is not a
                    // number anybody should be typing.
                    Text("It is either done or it is not.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .tasksCompleted:
                    TextField("How many to finish", text: $target)
                    Picker("In list", selection: $listID) {
                        Text("Anywhere in the space").tag(String?.none)
                        ForEach(model.lists) { list in
                            Text(list.name).tag(String?.some(list.id))
                        }
                    }
                    TextField("Only cards matching", text: $query, prompt: Text("type:bug priority >= high"))
                    Text("Leave the query empty to count everything in the space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .number, .currency:
                    TextField("Starting figure", text: $start)
                    TextField("Target", text: $target)
                    if kind == .currency {
                        TextField("Currency", text: $currency)
                    }
                    Text("Progress is measured from the starting figure, so a goal to bring a number down works as well as one to push it up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Folder", selection: $folderID) {
                    Text("None").tag(String?.none)
                    ForEach(model.goalFolders) { folder in
                        Text(folder.name).tag(String?.some(folder.id))
                    }
                }

                Toggle("Has a deadline", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                }

                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(goal == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private func load() {
        guard let goal else { return }
        name = goal.name
        notes = goal.notes
        kind = goal.kind
        start = Goal.plain(goal.start)
        target = Goal.plain(goal.target)
        currency = goal.currency
        query = goal.query
        listID = goal.listID
        folderID = goal.folderID
        hasDueDate = goal.dueAt != nil
        dueDate = goal.dueAt ?? Date()
    }

    private func save() {
        let startValue = Double(start) ?? 0
        let targetValue = kind == .boolean ? 1 : (Double(target) ?? 1)

        if var existing = goal {
            existing.name = name
            existing.notes = notes
            existing.kind = kind
            existing.start = startValue
            existing.target = targetValue
            existing.currency = currency
            existing.query = query
            existing.listID = listID
            existing.folderID = folderID
            existing.dueAt = hasDueDate ? dueDate : nil
            model.updateGoal(existing)
        } else {
            model.createGoal(
                named: name, kind: kind, target: targetValue, start: startValue,
                currency: currency, query: query, listID: listID, folderID: folderID,
                dueAt: hasDueDate ? dueDate : nil, notes: notes
            )
        }
        dismiss()
    }
}
