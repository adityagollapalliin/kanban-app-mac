import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// How this project works: its own fields, which moves it allows, the rules it
/// applies to itself, and the shapes it keeps.
///
/// One window with four tabs rather than four menu items, because these are
/// the settings you sit down and configure once, not the ones you flick
/// between while working.
struct ProjectSettingsView: View {

    let model: BoardViewModel

    var body: some View {
        TabView {
            CustomFieldsPane(model: model)
                .tabItem { Label("Fields", systemImage: "list.bullet.rectangle") }
            WorkflowPane(model: model)
                .tabItem { Label("Workflow", systemImage: "arrow.triangle.branch") }
            AutomationsPane(model: model)
                .tabItem { Label("Rules", systemImage: "wand.and.stars") }
            VocabularyPane(model: model)
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            ComponentsPane(model: model)
                .tabItem { Label("Components", systemImage: "square.stack.3d.up") }
            TemplatesPane(model: model)
                .tabItem { Label("Templates", systemImage: "doc.on.doc") }
        }
        .frame(width: 620, height: 460)
    }
}

// MARK: - Fields

private struct CustomFieldsPane: View {
    let model: BoardViewModel

    @State private var name = ""
    @State private var kind: CustomFieldKind = .text
    @State private var options = ""
    @State private var currency = "USD"
    @State private var progressMode: ProgressMode = .manual
    @State private var targetListID: String?
    @State private var formula = ""
    @State private var rollupSource: RollupSource = .subtasks
    @State private var rollupLinkID: String?
    @State private var rollupFieldID: String?
    @State private var rollupFunction: RollupFunction = .sum

    /// The fields a rollup can read. A computed field is left out: rolling up
    /// something that is itself worked out from the cards being rolled up is a
    /// question with no bottom to it.
    private var rollupTargets: [CustomField] {
        model.customFields.filter { $0.kind.storage == .number || $0.kind == .checkbox }
    }

    private var relationshipFields: [CustomField] {
        model.customFields.filter { $0.kind == .relationship }
    }

    /// Whether what has been typed could actually be saved.
    private var canAdd: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch kind {
        case .choice:
            return !options.trimmingCharacters(in: .whitespaces).isEmpty
        case .formula:
            return (try? FormulaEvaluator.validate(formula)) != nil
                && !formula.trimmingCharacters(in: .whitespaces).isEmpty
        case .rollup:
            if rollupSource == .relationship && rollupLinkID == nil { return false }
            return rollupFunction == .count || rollupFieldID != nil
        default:
            return true
        }
    }

    /// What is wrong with the formula, while it is being typed.
    private var formulaProblem: String? {
        let trimmed = formula.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        do {
            try FormulaEvaluator.validate(trimmed)
            return nil
        } catch let error as FormulaError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fields this project keeps on its cards, alongside the built-in ones. They can be searched with `cf:Name`.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.customFields) { field in
                    HStack(spacing: 8) {
                        Image(systemName: field.kind.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(field.name)
                            Text(field.kind == .choice
                                 ? field.options.joined(separator: ", ")
                                 : field.kind.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.deleteCustomField(field.id)
                        }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .help("Removes the field and every value anyone put in it")
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)

                Picker("", selection: $kind) {
                    ForEach(CustomFieldKind.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 110)

                if kind == .choice {
                    TextField("Choices, comma separated", text: $options)
                        .textFieldStyle(.roundedBorder)
                }

                if kind == .money {
                    TextField("Currency", text: $currency)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }

                Button("Add", action: add).disabled(!canAdd)
            }

            // The kinds that need more than a name and a word get their own
            // row, rather than a dialog that hides what is being set.
            settings


            // Said here rather than discovered later: a field's kind decides
            // which column its values live in, so it cannot move afterwards.
            Text("A field's kind is fixed once it is made — changing it would strand every value already written.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    @ViewBuilder
    private var settings: some View {
        switch kind {
        case .progress:
            Picker("Counted", selection: $progressMode) {
                ForEach(ProgressMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }

        case .relationship:
            Picker("Links to cards in", selection: $targetListID) {
                Text("Anywhere in the space").tag(String?.none)
                ForEach(model.lists) { list in
                    Text(list.name).tag(String?.some(list.id))
                }
            }

        case .formula:
            VStack(alignment: .leading, spacing: 4) {
                TextField("Formula", text: $formula, prompt: Text("{Due} - {Start}"))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())

                if let problem = formulaProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text("Arithmetic over the other fields. `{Name}` reads a field; `Due`, `Start`, `Created`, `Estimate`, `Logged` and `Priority` are built in. `if`, `days`, `today`, `round`, `concat` and `coalesce` are available.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .rollup:
            VStack(alignment: .leading, spacing: 6) {
                Picker("Gather from", selection: $rollupSource) {
                    ForEach(RollupSource.allCases, id: \.self) { source in
                        Text(source.label).tag(source)
                    }
                }

                if rollupSource == .relationship {
                    Picker("Through", selection: $rollupLinkID) {
                        Text("Pick a relationship field").tag(String?.none)
                        ForEach(relationshipFields) { field in
                            Text(field.name).tag(String?.some(field.id))
                        }
                    }
                    .disabled(relationshipFields.isEmpty)
                    if relationshipFields.isEmpty {
                        Text("Make a relationship field first — a rollup needs to know which cards to gather from.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Work out the", selection: $rollupFunction) {
                    ForEach(RollupFunction.allCases, id: \.self) { function in
                        Text(function.label).tag(function)
                    }
                }

                if rollupFunction != .count {
                    Picker("Of field", selection: $rollupFieldID) {
                        Text("Pick a field").tag(String?.none)
                        ForEach(rollupTargets) { field in
                            Text(field.name).tag(String?.some(field.id))
                        }
                    }
                    .disabled(rollupTargets.isEmpty)
                }
            }

        default:
            EmptyView()
        }
    }

    private func add() {
        model.createCustomField(
            named: name,
            kind: kind,
            options: options.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            currency: currency,
            progressMode: progressMode,
            targetListID: targetListID,
            formula: formula,
            rollupSource: rollupSource,
            rollupLinkID: rollupLinkID,
            rollupFieldID: rollupFieldID,
            rollupFunction: rollupFunction
        )
        name = ""
        options = ""
        formula = ""
    }
}

// MARK: - Workflow

private struct WorkflowPane: View {
    let model: BoardViewModel

    private var columns: [LoadedColumn] { model.snapshot?.columns ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Only allow the moves ticked below", isOn: Binding(
                get: { model.enforcesWorkflow },
                set: { model.setWorkflowEnforced($0) }
            ))

            // The one place the app refuses rather than reports, so it says so.
            Text("This is the only rule in the app that refuses a move rather than reporting it. With nothing ticked, everything is still allowed — a half-configured project must not trap its own cards.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if columns.count < 2 {
                Text("Add a second column first.").foregroundStyle(.secondary)
            } else {
                grid
            }

            HStack {
                Button("Allow One Step Either Way") { model.seedWorkflow() }
                    .help("Ticks every move to the next column and back, as a starting point")
                Spacer()
            }
        }
        .padding(16)
    }

    private var grid: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("From ╲ To").font(.caption2).foregroundStyle(.secondary)
                    ForEach(columns) { column in
                        Text(column.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .frame(width: 70)
                    }
                }

                ForEach(columns) { from in
                    GridRow {
                        Text(from.name)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(width: 90, alignment: .leading)

                        ForEach(columns) { to in
                            if from.id == to.id {
                                // A card staying put is never a transition, so
                                // there is nothing here to allow or forbid.
                                Text("—")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 70)
                            } else {
                                Toggle("", isOn: Binding(
                                    get: { model.permitsTransition(from: from.status.id, to: to.status.id) },
                                    set: { model.setTransition(from: from.status.id, to: to.status.id, allowed: $0) }
                                ))
                                .labelsHidden()
                                .frame(width: 70)
                                .accessibilityLabel("Allow moving from \(from.name) to \(to.name)")
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Rules

private struct AutomationsPane: View {
    let model: BoardViewModel

    @State private var name = ""
    @State private var trigger: AutomationTrigger = .statusChanged
    @State private var triggerStatus: String?
    @State private var action: AutomationAction = .setFlag
    @State private var actionValue = ""

    private var columns: [LoadedColumn] { model.snapshot?.columns ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One trigger, one action. Rules run the moment the change happens, so a card never briefly sits in the state a rule was meant to prevent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.automations) { rule in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { model.setAutomationEnabled($0, for: rule.id) }
                        ))
                        .labelsHidden()

                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.name)
                            Text(describe(rule))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.deleteAutomation(rule.id)
                        }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)

                HStack(spacing: 6) {
                    Picker("", selection: $trigger) {
                        ForEach(AutomationTrigger.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()

                    if trigger == .statusChanged {
                        Picker("", selection: $triggerStatus) {
                            Text("a column").tag(String?.none)
                            ForEach(columns) { column in
                                Text(column.name).tag(String?.some(column.status.id))
                            }
                        }
                        .labelsHidden()
                    }
                }

                HStack(spacing: 6) {
                    Picker("", selection: $action) {
                        ForEach(AutomationAction.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()

                    actionValueControl

                    Button("Add", action: add).disabled(!isComplete)
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var actionValueControl: some View {
        switch action {
        case .moveToStatus:
            Picker("", selection: $actionValue) {
                Text("a column").tag("")
                ForEach(columns) { column in
                    Text(column.name).tag(column.status.id)
                }
            }
            .labelsHidden()

        case .setAssignee:
            Picker("", selection: $actionValue) {
                Text("someone").tag("")
                ForEach(model.people) { person in
                    Text(person.name).tag(person.id)
                }
            }
            .labelsHidden()

        case .setPriority:
            Picker("", selection: $actionValue) {
                Text("a priority").tag("")
                ForEach(Priority.allCases.sorted(by: >), id: \.self) { priority in
                    Text(priorityName(priority)).tag(String(priority.rawValue))
                }
            }
            .labelsHidden()

        case .addLabel:
            Picker("", selection: $actionValue) {
                Text("a label").tag("")
                ForEach(model.labels) { label in
                    Text(label.name).tag(label.id)
                }
            }
            .labelsHidden()

        case .setFlag:
            TextField("Reason", text: $actionValue).textFieldStyle(.roundedBorder)

        case .clearFlag:
            EmptyView()
        }
    }

    private var isComplete: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if trigger == .statusChanged, triggerStatus == nil { return false }
        if action.needsValue, actionValue.isEmpty { return false }
        return true
    }

    private func add() {
        model.createAutomation(
            named: name, trigger: trigger, triggerStatusID: triggerStatus,
            action: action, actionValue: actionValue
        )
        name = ""
        actionValue = ""
    }

    private func describe(_ rule: Automation) -> String {
        var parts: [String] = [rule.trigger.label]
        if rule.trigger == .statusChanged {
            parts.append(model.statusName(rule.triggerStatusID))
        }
        parts.append("→")
        parts.append(rule.action.label)
        if rule.action.needsValue { parts.append(valueName(rule)) }
        return parts.joined(separator: " ")
    }

    private func valueName(_ rule: Automation) -> String {
        switch rule.action {
        case .moveToStatus: model.statusName(rule.actionValue)
        case .setAssignee: model.person(id: rule.actionValue)?.name ?? "someone since removed"
        case .setPriority: Int(rule.actionValue).flatMap(Priority.init(rawValue:)).map(priorityName) ?? "?"
        case .addLabel: model.labels.first { $0.id == rule.actionValue }?.name ?? "a label since removed"
        case .setFlag: "“\(rule.actionValue)”"
        case .clearFlag: ""
        }
    }

    private func priorityName(_ priority: Priority) -> String {
        switch priority {
        case .lowest: "Lowest"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .highest: "Highest"
        }
    }
}

// MARK: - Templates

private struct TemplatesPane: View {
    let model: BoardViewModel

    @State private var projectTemplateName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Card templates")
                .font(.headline)
            Text("Made from a card that already exists — open one and choose Save as Template. Using a template creates its labels if the project does not have them yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.cardTemplates.isEmpty {
                Text("None yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(model.cardTemplates) { template in
                        HStack {
                            Label(template.name, systemImage: "doc.text")
                            Spacer()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.deleteTemplate(template.id)
                            }
                            .buttonStyle(.borderless)
                            .labelStyle(.iconOnly)
                        }
                    }
                }
                .frame(height: 100)
            }

            Divider()

            Text("Project templates")
                .font(.headline)
            Text("The columns, limits and labels of this project, without its work — a shape to start another project from.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.projectTemplates.isEmpty {
                List {
                    ForEach(model.projectTemplates) { template in
                        HStack {
                            Label(template.name, systemImage: "square.grid.2x2")
                            Spacer()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.deleteTemplate(template.id)
                            }
                            .buttonStyle(.borderless)
                            .labelStyle(.iconOnly)
                        }
                    }
                }
                .frame(height: 90)
            }

            HStack(spacing: 8) {
                TextField("Name this project's shape", text: $projectTemplateName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    model.saveProjectTemplate(named: projectTemplateName)
                    projectTemplateName = ""
                }
                .disabled(projectTemplateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }
}

// MARK: - Vocabulary

/// The words this project uses for its own work.
///
/// Four lists rather than four tabs: they are short, they are related, and the
/// question "what do we call things here" is answered by seeing them together.
private struct VocabularyPane: View {
    let model: BoardViewModel

    @State private var newTypeName = ""
    @State private var newTypeSymbol = "square"
    @State private var newTypeLevel = 0
    @State private var newResolution = ""
    @State private var newLinkOutward = ""
    @State private var newLinkInward = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                issueTypes
                Divider()
                priorities
                Divider()
                linkTypes
                Divider()
                resolutions
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Kinds of card

    private var issueTypes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kinds of card")
                .font(.headline)
            Text("A level above 0 sits over the rest — an Epic is 1, and an Initiative over that would be 2.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.issueTypes) { type in
                HStack(spacing: 8) {
                    Image(systemName: type.symbol.isEmpty ? "square" : type.symbol)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    TextField("Name", text: nameBinding(type))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Text(type.level == 0 ? "Work" : "Level \(type.level)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        model.deleteIssueType(type)
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("Refused while any card is still this kind")
                }
            }

            HStack(spacing: 8) {
                TextField("New kind", text: $newTypeName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                TextField("SF Symbol", text: $newTypeSymbol)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Stepper("Level \(newTypeLevel)", value: $newTypeLevel, in: 0...3)
                    .fixedSize()
                Button("Add") {
                    model.addIssueType(named: newTypeName, symbol: newTypeSymbol, level: newTypeLevel)
                    newTypeName = ""
                }
                .disabled(newTypeName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func nameBinding(_ type: IssueType) -> Binding<String> {
        Binding(
            get: { type.name },
            set: { typed in
                var edited = type
                edited.name = typed
                if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                    model.updateIssueType(edited)
                }
            }
        )
    }

    // MARK: Priorities

    private var priorities: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Priorities")
                .font(.headline)

            ForEach(model.priorityValues) { value in
                HStack(spacing: 8) {
                    Image(systemName: value.symbol.isEmpty ? "minus" : value.symbol)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    TextField("Name", text: Binding(
                        get: { value.name },
                        set: { typed in
                            var edited = value
                            edited.name = typed
                            if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                                model.updatePriority(edited)
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    Text("Rank \(value.rank)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            // Said plainly rather than shown as a disabled button nobody can
            // explain: `priority >= high` compiles to a comparison against the
            // rank, and the query language is frozen behind its regression
            // baseline until 8.5b.
            Text("Steps can be renamed, but not added or reordered yet — searching with `priority >= high` compares ranks, and that comparison is frozen until the query language work.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Link types

    private var linkTypes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kinds of link")
                .font(.headline)
            Text("A link is one relationship read from two ends, so each is a pair.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.linkTypes) { type in
                HStack(spacing: 8) {
                    Image(systemName: type.symbol.isEmpty ? "link" : type.symbol)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    TextField("Outward", text: Binding(
                        get: { type.outward },
                        set: { typed in
                            var edited = type
                            edited.outward = typed
                            if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                                model.updateLinkType(edited)
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Inward", text: Binding(
                        get: { type.inward },
                        set: { typed in
                            var edited = type
                            edited.inward = typed
                            if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                                model.updateLinkType(edited)
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 8) {
                TextField("Causes", text: $newLinkOutward)
                    .textFieldStyle(.roundedBorder)
                TextField("Is caused by", text: $newLinkInward)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    model.addLinkType(outward: newLinkOutward, inward: newLinkInward)
                    newLinkOutward = ""
                    newLinkInward = ""
                }
                .disabled(
                    newLinkOutward.trimmingCharacters(in: .whitespaces).isEmpty
                    || newLinkInward.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
    }

    // MARK: Resolutions

    private var resolutions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Resolutions")
                .font(.headline)
            Text("Why a card was closed. The default is applied when a card reaches a Done column without one.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.resolutions) { resolution in
                HStack(spacing: 8) {
                    Button {
                        model.setDefaultResolution(resolution.id)
                    } label: {
                        Image(systemName: resolution.isDefault ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(resolution.isDefault ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(resolution.isDefault ? "The default" : "Make this the default")

                    TextField("Name", text: Binding(
                        get: { resolution.name },
                        set: { typed in
                            if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                                model.renameResolution(resolution.id, to: typed)
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)

                    Spacer()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        model.deleteResolution(resolution.id)
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .disabled(resolution.isDefault)
                }
            }

            HStack(spacing: 8) {
                TextField("New resolution", text: $newResolution)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button("Add") {
                    model.addResolution(named: newResolution)
                    newResolution = ""
                }
                .disabled(newResolution.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Components

/// Parts of the thing being built, and who looks after each.
private struct ComponentsPane: View {
    let model: BoardViewModel

    @State private var name = ""
    @State private var assignee: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A component is a part of what you are building. Work filed against one lands on its owner without anybody choosing — unless the card is already assigned, in which case somebody already chose.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.components) { component in
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        TextField("Name", text: Binding(
                            get: { component.name },
                            set: { typed in
                                var edited = component
                                edited.name = typed
                                if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                                    model.updateComponent(edited)
                                }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)

                        Picker("", selection: Binding(
                            get: { component.defaultAssigneeID },
                            set: { chosen in
                                var edited = component
                                edited.defaultAssigneeID = chosen
                                model.updateComponent(edited)
                            }
                        )) {
                            Text("Nobody").tag(String?.none)
                            ForEach(model.people) { person in
                                Text(person.name).tag(String?.some(person.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)

                        Spacer()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.deleteComponent(component.id)
                        }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .help("Cards lose the tag; nothing else about them changes")
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack(spacing: 8) {
                TextField("New component", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Picker("Owner", selection: $assignee) {
                    Text("Nobody").tag(String?.none)
                    ForEach(model.people) { person in
                        Text(person.name).tag(String?.some(person.id))
                    }
                }
                .frame(width: 200)
                Button("Add") {
                    model.createComponent(named: name, defaultAssigneeID: assignee)
                    name = ""
                    assignee = nil
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }
}
