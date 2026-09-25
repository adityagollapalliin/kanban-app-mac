import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The workflow as a diagram: columns as nodes, allowed moves as arrows.
///
/// A diagram rather than the matrix of tick-boxes this replaced, because the
/// question people actually have is "how does work get from here to there",
/// and a grid answers "is this pair ticked" instead. Nodes are dragged and
/// their positions remembered — an automatic layout of the same graph moves
/// everything whenever one status is added, and a diagram that rearranges
/// itself is one nobody can learn.
struct WorkflowEditorView: View {

    let model: BoardViewModel

    @State private var selectedTransition: WorkflowTransition?
    @State private var draggingFrom: String?
    @State private var dragPoint: CGPoint = .zero
    @State private var positions: [String: CGPoint] = [:]

    private static let nodeSize = CGSize(width: 150, height: 52)

    private var statuses: [Status] {
        model.snapshot?.columns.map(\.status) ?? []
    }

    private var transitions: [WorkflowTransition] { model.transitions }

    var body: some View {
        VStack(spacing: 0) {
            header
            canvas
        }
        .navigationTitle("Workflow")
        .sheet(item: $selectedTransition) { transition in
            TransitionRuleSheet(transition: transition, model: model)
        }
        .onAppear(perform: layoutIfNeeded)
        .onChange(of: statuses.count) { layoutIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Toggle("Only allow these moves", isOn: Binding(
                get: { model.enforcesWorkflow },
                set: { model.setWorkflowEnforced($0) }
            ))
            .toggleStyle(.switch)

            Text(model.enforcesWorkflow
                 ? "A move with no arrow is refused."
                 : "Every move is allowed; the arrows are a description rather than a rule.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text("Drag from one column's edge to another to allow a move. Click an arrow to give it rules.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())

                // Arrows first, so a node dragged over one covers it rather
                // than being covered by it.
                ForEach(transitions) { transition in
                    arrow(transition)
                }

                if let draggingFrom, let start = positions[draggingFrom] {
                    Path { path in
                        path.move(to: start)
                        path.addLine(to: dragPoint)
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }

                ForEach(statuses) { status in
                    node(status, in: geometry.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Nodes

    private func node(_ status: Status, in size: CGSize) -> some View {
        let centre = positions[status.id] ?? .zero

        return VStack(spacing: 2) {
            Text(status.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(categoryLabel(status.category))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
        .background(categoryColor(status.category).opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(draggingFrom == status.id ? Color.accentColor : Color.secondary.opacity(0.4),
                              lineWidth: draggingFrom == status.id ? 2 : 1)
        )
        .position(centre)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Dragging from the middle moves the node; dragging from
                    // an edge draws a new arrow. One gesture, decided by where
                    // it began, so there is no mode to be in.
                    if draggingFrom == nil, isNearEdge(value.startLocation, of: centre) {
                        draggingFrom = status.id
                    }
                    if draggingFrom == status.id {
                        dragPoint = value.location
                    } else {
                        positions[status.id] = clamp(value.location, in: size)
                    }
                }
                .onEnded { value in
                    if draggingFrom == status.id {
                        if let target = statusNode(at: value.location), target.id != status.id {
                            model.setTransition(from: status.id, to: target.id, allowed: true)
                        }
                        draggingFrom = nil
                    } else {
                        let settled = clamp(value.location, in: size)
                        positions[status.id] = settled
                        model.setDiagramPosition(x: settled.x, y: settled.y, forStatus: status.id)
                    }
                }
        )
    }

    /// Whether a drag started close enough to a node's border to mean "draw an
    /// arrow" rather than "move me".
    private func isNearEdge(_ point: CGPoint, of centre: CGPoint) -> Bool {
        let dx = abs(point.x - centre.x)
        let dy = abs(point.y - centre.y)
        return dx > Self.nodeSize.width / 2 - 14 || dy > Self.nodeSize.height / 2 - 12
    }

    private func statusNode(at point: CGPoint) -> Status? {
        statuses.first { status in
            guard let centre = positions[status.id] else { return false }
            return abs(point.x - centre.x) <= Self.nodeSize.width / 2
                && abs(point.y - centre.y) <= Self.nodeSize.height / 2
        }
    }

    private func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, Self.nodeSize.width / 2 + 8), max(size.width - Self.nodeSize.width / 2 - 8, Self.nodeSize.width / 2 + 8)),
            y: min(max(point.y, Self.nodeSize.height / 2 + 8), max(size.height - Self.nodeSize.height / 2 - 8, Self.nodeSize.height / 2 + 8))
        )
    }

    // MARK: Arrows

    @ViewBuilder
    private func arrow(_ transition: WorkflowTransition) -> some View {
        if let from = positions[transition.fromStatusID],
           let to = positions[transition.toStatusID] {
            let rules = model.transitionRules[transition.id] ?? []

            ZStack {
                ArrowShape(from: from, to: to, nodeSize: Self.nodeSize)
                    .stroke(rules.isEmpty ? Color.secondary : Color.accentColor,
                            style: StrokeStyle(lineWidth: rules.isEmpty ? 1.5 : 2.5))

                // A wider invisible line to click: a one-point stroke is a
                // target nobody can hit.
                ArrowShape(from: from, to: to, nodeSize: Self.nodeSize)
                    .stroke(Color.clear, lineWidth: 14)
                    .contentShape(ArrowShape(from: from, to: to, nodeSize: Self.nodeSize)
                        .stroke(style: StrokeStyle(lineWidth: 14)))
                    .onTapGesture { selectedTransition = transition }

                if !rules.isEmpty || !transition.name.isEmpty {
                    // On the bow rather than the straight midpoint, so A→B and
                    // B→A do not print their labels on top of each other.
                    label(transition, rules: rules, at: bowMidpoint(from: from, to: to))
                }
            }
            .contextMenu {
                Button("Rules…") { selectedTransition = transition }
                Divider()
                Button("Remove this move", role: .destructive) {
                    model.setTransition(from: transition.fromStatusID, to: transition.toStatusID, allowed: false)
                }
            }
        }
    }

    /// The middle of the curve, which is where the line actually is.
    private func bowMidpoint(from: CGPoint, to: CGPoint) -> CGPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = max(sqrt(dx * dx + dy * dy), 1)
        // Bowed *and* slid along the line, not merely bowed.
        //
        // A perpendicular offset cannot separate two labels wider than the
        // offset, so the two halves of an A→B/B→A pair still printed on top of
        // each other. Sliding each one towards its own start puts them at
        // opposite ends of the curve, which works whatever they say.
        let bow = 22.0
        let along = 0.32
        let midX = from.x + dx * along
        let midY = from.y + dy * along
        return CGPoint(
            x: midX - dy / distance * bow,
            y: midY + dx / distance * bow
        )
    }

    private func label(_ transition: WorkflowTransition, rules: [TransitionRule], at point: CGPoint) -> some View {
        HStack(spacing: 3) {
            if !transition.name.isEmpty {
                Text(transition.name).font(.caption2)
            }
            ForEach(TransitionRulePhase.allCases, id: \.self) { phase in
                let count = rules.filter { $0.phase == phase }.count
                if count > 0 {
                    Label("\(count)", systemImage: phase.symbol)
                        .font(.system(size: 9))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                }
            }
            if transition.hasScreen {
                Image(systemName: "text.cursor")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("Stops to ask for something")
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.background, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .position(point)
    }

    // MARK: Laying out

    /// Positions every node, using the remembered place where there is one and
    /// a row across the top where there is not.
    private func layoutIfNeeded() {
        for (index, status) in statuses.enumerated() where positions[status.id] == nil {
            if status.isPositioned {
                positions[status.id] = CGPoint(x: status.diagramX, y: status.diagramY)
            } else {
                // The order the board already shows, which is the order people
                // already have in their heads.
                positions[status.id] = CGPoint(
                    x: 110 + Double(index) * (Self.nodeSize.width + 60),
                    y: 90
                )
            }
        }
    }

    private func categoryLabel(_ category: StatusCategory) -> String {
        switch category {
        case .toDo: "To do"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }

    private func categoryColor(_ category: StatusCategory) -> Color {
        switch category {
        case .toDo: .secondary
        case .inProgress: .blue
        case .done: .green
        }
    }
}

/// An arrow between two node edges, curved enough to tell two apart when they
/// run between the same pair in opposite directions.
struct ArrowShape: Shape {
    let from: CGPoint
    let to: CGPoint
    let nodeSize: CGSize

    /// Where the ray from one node's centre towards another crosses its
    /// border. Scaling by whichever axis the ray leaves through is what makes
    /// this right for a rectangle rather than only for a square.
    private func edgePoint(from centre: CGPoint, towards other: CGPoint) -> CGPoint {
        let dx = other.x - centre.x
        let dy = other.y - centre.y
        guard dx != 0 || dy != 0 else { return centre }

        let halfWidth = nodeSize.width / 2 + 4
        let halfHeight = nodeSize.height / 2 + 4

        // How far along the ray each border lies; the nearer one is the one it
        // actually crosses.
        let scaleX = dx == 0 ? Double.infinity : halfWidth / abs(dx)
        let scaleY = dy == 0 ? Double.infinity : halfHeight / abs(dy)
        let scale = min(scaleX, scaleY)

        return CGPoint(x: centre.x + dx * scale, y: centre.y + dy * scale)
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = max(sqrt(dx * dx + dy * dy), 1)

        // Start and end where the line actually leaves each box, rather than
        // at a fixed distance from its centre.
        //
        // A fixed radius is only right for a square. With a node half as tall
        // as it is wide, a *vertical* arrow was inset by the width and all but
        // disappeared — the two nodes stacked above each other showed a label
        // between two chevrons and no line at all.
        let start = edgePoint(from: from, towards: to)
        let end = edgePoint(from: to, towards: from)

        // Bowed to one side, consistently, so A→B and B→A do not lie on top of
        // each other.
        let bow = 22.0
        let control = CGPoint(
            x: (start.x + end.x) / 2 - dy / distance * bow,
            y: (start.y + end.y) / 2 + dx / distance * bow
        )

        path.move(to: start)
        path.addQuadCurve(to: end, control: control)

        // The head, angled along the curve's final direction.
        let angle = atan2(end.y - control.y, end.x - control.x)
        let head = 8.0
        for side in [angle + .pi * 0.82, angle - .pi * 0.82] {
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x + cos(side) * head, y: end.y + sin(side) * head))
        }

        return path
    }
}

/// The rules on one move, and what it stops to ask for.
struct TransitionRuleSheet: View {

    let transition: WorkflowTransition
    let model: BoardViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var screenTitle = ""
    @State private var screenFields: Set<String> = []
    @State private var adding: TransitionRulePhase?
    @State private var newKind: TransitionRuleKind = .allSubtasksDone
    @State private var newTarget = ""
    @State private var newValue = ""
    @State private var newQuery = ""
    @State private var newSyntax: QuerySyntax = .simple

    private var rules: [TransitionRule] { model.transitionRules[transition.id] ?? [] }

    private var route: String {
        let from = model.statusName(id: transition.fromStatusID)
        let to = model.statusName(id: transition.toStatusID)
        return "\(from) → \(to)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(route)
                .font(.headline)
                .padding()

            Form {
                Section {
                    TextField("Name this move", text: $name, prompt: Text("Start work"))
                    Text("Shown on the button instead of the column's name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(TransitionRulePhase.allCases, id: \.self) { phase in
                    phaseSection(phase)
                }

                Section("Stop and ask for") {
                    ForEach(FieldReference.builtInNames, id: \.self) { name in
                        Toggle(name.prefix(1).uppercased() + name.dropFirst(), isOn: Binding(
                            get: { screenFields.contains(FieldReference.builtIn(name).stored) },
                            set: { on in
                                let key = FieldReference.builtIn(name).stored
                                if on { screenFields.insert(key) } else { screenFields.remove(key) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                    if !screenFields.isEmpty {
                        TextField("Prompt", text: $screenTitle, prompt: Text("Before starting, please…"))
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.updateTransition(
                        transition.id, name: name, screenTitle: screenTitle,
                        screenFields: screenFields.map { FieldReference(stored: $0) }
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
        .onAppear {
            name = transition.name
            screenTitle = transition.screenTitle
            screenFields = Set(transition.screenFields.map(\.stored))
        }
    }

    @ViewBuilder
    private func phaseSection(_ phase: TransitionRulePhase) -> some View {
        Section(phase.label) {
            let mine = rules.filter { $0.phase == phase }

            if mine.isEmpty {
                Text(phase == .condition ? "Always offered." : "Nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(mine) { rule in
                HStack(spacing: 6) {
                    Image(systemName: phase.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(describe(rule)).font(.callout)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle", role: .destructive) {
                        model.removeTransitionRule(rule.id)
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                }
            }

            if adding == phase {
                addingRow(phase)
            } else {
                Button("Add…", systemImage: "plus") {
                    adding = phase
                    newKind = TransitionRuleKind.kinds(in: phase).first ?? .allSubtasksDone
                    newTarget = ""
                    newValue = ""
                    newQuery = ""
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func addingRow(_ phase: TransitionRulePhase) -> some View {
        Picker("", selection: $newKind) {
            ForEach(TransitionRuleKind.kinds(in: phase), id: \.self) { kind in
                Text(kind.label).tag(kind)
            }
        }
        .labelsHidden()

        if newKind.needsTarget {
            Picker("Which", selection: $newTarget) {
                Text("Pick one").tag("")
                switch newKind {
                case .assign:
                    ForEach(model.people) { person in
                        Text(person.name).tag(person.id)
                    }
                case .setResolution:
                    ForEach(model.resolutions) { resolution in
                        Text(resolution.name).tag(resolution.id)
                    }
                default:
                    ForEach(FieldReference.builtInNames, id: \.self) { name in
                        Text(name.prefix(1).uppercased() + name.dropFirst())
                            .tag(FieldReference.builtIn(name).stored)
                    }
                    ForEach(model.customFields) { field in
                        Text(field.name).tag(FieldReference.custom(field.id).stored)
                    }
                }
            }
        }

        if newKind.needsValue {
            TextField("Value", text: $newValue)
        }

        if newKind.needsQuery {
            Picker("Written in", selection: $newSyntax) {
                ForEach(QuerySyntax.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            TextField("Query", text: $newQuery, prompt: Text("priority >= high"))
                .font(.callout.monospaced())
            if let problem = model.problem(with: newQuery, syntax: newSyntax) {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        HStack {
            Button("Cancel") { adding = nil }
                .buttonStyle(.borderless)
            Spacer()
            Button("Add") {
                model.addTransitionRule(
                    newKind, to: transition.id, target: newTarget,
                    value: newValue, query: newQuery, syntax: newSyntax
                )
                adding = nil
            }
            .disabled(newKind.needsTarget && newTarget.isEmpty)
        }
    }

    private func describe(_ rule: TransitionRule) -> String {
        switch rule.kind {
        case .matchesQuery:
            return "the card matches “\(rule.query)”"
        case .fieldRequired, .setField:
            let field = FieldReference(stored: rule.target)
            let name: String
            switch field {
            case .builtIn(let builtIn): name = builtIn
            case .custom(let id): name = model.customFields.first { $0.id == id }?.name ?? "a field"
            }
            return rule.kind == .setField
                ? "Set \(name) to “\(rule.value)”"
                : "\(name) is filled in"
        case .assign:
            return "Assign to \(model.people.first { $0.id == rule.target }?.name ?? "nobody")"
        case .setResolution:
            return "Resolve as \(model.resolutions.first { $0.id == rule.target }?.name ?? "—")"
        case .addComment:
            return "Comment “\(rule.value)”"
        default:
            return rule.kind.label
        }
    }
}
