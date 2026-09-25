import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// An infinite canvas: sticky notes, shapes, text, freehand ink and
/// connectors between them.
///
/// Everything on it is a row in one table, because they differ in what they
/// draw rather than in what they are. And a sticky can become a card — which
/// is the point of having a canvas inside a task app rather than beside one:
/// the thinking and the work end up in the same file.
struct WhiteboardView: View {

    let model: BoardViewModel

    @State private var boards: [Whiteboard] = []
    @State private var selectedBoard: String?
    @State private var items: [WhiteboardItem] = []
    @State private var tool: Tool = .select
    @State private var selectedItem: String?
    @State private var editingItem: String?
    @State private var draft = ""
    @State private var stroke: [CGPoint] = []
    @State private var connectFrom: String?
    @State private var dragOffsets: [String: CGSize] = [:]

    enum Tool: String, CaseIterable, Identifiable {
        case select, sticky, shape, text, ink, connector
        var id: String { rawValue }

        var label: String {
            switch self {
            case .select: "Select"
            case .sticky: "Sticky"
            case .shape: "Shape"
            case .text: "Text"
            case .ink: "Draw"
            case .connector: "Connect"
            }
        }

        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .sticky: "note.text"
            case .shape: "square.on.circle"
            case .text: "textformat"
            case .ink: "scribble"
            case .connector: "arrow.right"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if selectedBoard == nil {
                ContentUnavailableView(
                    "No whiteboard yet",
                    systemImage: "rectangle.dashed",
                    description: Text("Make one above. Stickies on it can become cards.")
                )
            } else {
                canvas
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        boards = model.whiteboards()
        if selectedBoard == nil || !boards.contains(where: { $0.id == selectedBoard }) {
            selectedBoard = boards.first?.id
        }
        reloadItems()
    }

    private func reloadItems() {
        items = selectedBoard.map { model.items(onWhiteboard: $0) } ?? []
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Board", selection: $selectedBoard) {
                Text("—").tag(String?.none)
                ForEach(boards) { board in
                    Text(board.name).tag(String?.some(board.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: selectedBoard) { reloadItems() }

            Button {
                if let made = model.createWhiteboard(named: "Whiteboard \(boards.count + 1)") {
                    boards = model.whiteboards()
                    selectedBoard = made.id
                    reloadItems()
                }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("A new whiteboard")

            Divider().frame(height: 16)

            Picker("Tool", selection: $tool) {
                ForEach(Tool.allCases) { option in
                    Label(option.label, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .fixedSize()

            if tool == .connector {
                Text(connectFrom == nil ? "Click the first thing" : "Now click the second")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)

            if let selectedItem, let item = items.first(where: { $0.id == selectedItem }) {
                selectionControls(item)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func selectionControls(_ item: WhiteboardItem) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(PaletteColor.allCases) { colour in
                    Button(colour.displayName) {
                        model.setItemColor(colour.rawValue, for: item.id)
                        reloadItems()
                    }
                }
            } label: {
                Circle()
                    .fill(PaletteColor.named(item.color).color)
                    .frame(width: 12, height: 12)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if item.kind == .sticky {
                if let taskID = item.taskID, let task = model.task(id: taskID) {
                    Button(model.tag(for: task)) { model.selectedTaskID = taskID }
                        .buttonStyle(.borderless)
                        .font(.caption.monospaced())
                        .help("This sticky is already a card")
                } else {
                    Button("Make a Card") {
                        model.convertStickyToTask(item.id)
                        reloadItems()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            Button {
                model.deleteItem(item.id)
                selectedItem = nil
                reloadItems()
            } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove it")
        }
    }

    // MARK: - The canvas

    private var canvas: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawInk(in: &context)
                    drawConnectors(in: &context)
                }
                .frame(width: 3000, height: 2000)
                .accessibilityHidden(true)

                ForEach(items.filter { $0.kind != .ink && $0.kind != .connector }) { item in
                    itemView(item)
                }
            }
            .frame(width: 3000, height: 2000, alignment: .topLeading)
            .background(canvasBackground)
            .contentShape(Rectangle())
            .gesture(canvasGesture)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Whiteboard with \(items.count) things on it")
    }

    private var canvasBackground: some View {
        Canvas { context, size in
            // A dot grid rather than lines: enough to judge alignment by,
            // quiet enough to draw over.
            let step: CGFloat = 24
            for x in stride(from: 0, to: size.width, by: step) {
                for y in stride(from: 0, to: size.height, by: step) {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                        with: .color(.secondary.opacity(0.25))
                    )
                }
            }
        }
    }

    private func drawInk(in context: inout GraphicsContext) {
        for item in items where item.kind == .ink {
            var path = Path()
            let points = item.points
            guard let first = points.first else { continue }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(
                path,
                with: .color(PaletteColor.named(item.color).color),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }

        // The stroke being drawn right now, before it is a row in the table.
        if stroke.count > 1 {
            var path = Path()
            path.move(to: stroke[0])
            for point in stroke.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    private func drawConnectors(in context: inout GraphicsContext) {
        for item in items where item.kind == .connector {
            guard let from = items.first(where: { $0.id == item.fromItem }),
                  let to = items.first(where: { $0.id == item.toItem }) else { continue }

            let start = CGPoint(x: from.x + from.width / 2, y: from.y + from.height / 2)
            let end = CGPoint(x: to.x + to.width / 2, y: to.y + to.height / 2)

            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(.secondary), lineWidth: 1.5)

            // An arrowhead, so a connector says which way round it is.
            let angle = atan2(end.y - start.y, end.x - start.x)
            var head = Path()
            head.move(to: end)
            head.addLine(to: CGPoint(
                x: end.x - 10 * cos(angle - .pi / 7), y: end.y - 10 * sin(angle - .pi / 7)
            ))
            head.move(to: end)
            head.addLine(to: CGPoint(
                x: end.x - 10 * cos(angle + .pi / 7), y: end.y - 10 * sin(angle + .pi / 7)
            ))
            context.stroke(head, with: .color(.secondary), lineWidth: 1.5)
        }
    }

    // MARK: - Items

    @ViewBuilder
    private func itemView(_ item: WhiteboardItem) -> some View {
        let offset = dragOffsets[item.id] ?? .zero

        Group {
            switch item.kind {
            case .sticky: sticky(item)
            case .shape: shape(item)
            case .text: text(item)
            default: EmptyView()
            }
        }
        .frame(width: item.width, height: item.height)
        .offset(x: item.x + offset.width, y: item.y + offset.height)
        .overlay(alignment: .topLeading) {
            if selectedItem == item.id {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: item.width, height: item.height)
                    .offset(x: item.x + offset.width, y: item.y + offset.height)
                    .allowsHitTesting(false)
            }
        }
        .onTapGesture { tap(item) }
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard tool == .select else { return }
                    dragOffsets[item.id] = value.translation
                }
                .onEnded { value in
                    guard tool == .select else { return }
                    dragOffsets[item.id] = nil
                    model.moveItem(item.id, to: item.x + value.translation.width,
                                   item.y + value.translation.height)
                    reloadItems()
                }
        )
    }

    private func tap(_ item: WhiteboardItem) {
        switch tool {
        case .connector:
            if let from = connectFrom, from != item.id {
                addConnector(from: from, to: item.id)
                connectFrom = nil
            } else {
                connectFrom = item.id
            }
        default:
            selectedItem = item.id
        }
    }

    private func sticky(_ item: WhiteboardItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            editableText(item)
            Spacer(minLength: 0)
            if item.taskID != nil {
                Label("a card", systemImage: "checkmark.square")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PaletteColor.named(item.color).color.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("Sticky note: \(item.text)")
    }

    private func shape(_ item: WhiteboardItem) -> some View {
        ZStack {
            switch item.shape {
            case .rectangle:
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(PaletteColor.named(item.color).color, lineWidth: 2)
            case .ellipse:
                Ellipse().strokeBorder(PaletteColor.named(item.color).color, lineWidth: 2)
            case .diamond:
                Rectangle()
                    .strokeBorder(PaletteColor.named(item.color).color, lineWidth: 2)
                    .rotationEffect(.degrees(45))
                    .scaleEffect(0.7)
            }
            editableText(item)
        }
        .accessibilityLabel("\(item.shape.label): \(item.text)")
    }

    private func text(_ item: WhiteboardItem) -> some View {
        editableText(item)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityLabel("Text: \(item.text)")
    }

    @ViewBuilder
    private func editableText(_ item: WhiteboardItem) -> some View {
        if editingItem == item.id {
            TextEditor(text: $draft)
                .font(.caption)
                .scrollContentBackground(.hidden)
                .onDisappear { commit(item) }
        } else {
            Text(item.text.isEmpty ? "…" : item.text)
                .font(.caption)
                .foregroundStyle(item.text.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.leading)
                .padding(2)
                .onTapGesture(count: 2) {
                    draft = item.text
                    editingItem = item.id
                }
        }
    }

    private func commit(_ item: WhiteboardItem) {
        model.setItemText(draft, for: item.id)
        editingItem = nil
        reloadItems()
    }

    // MARK: - Making things

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard tool == .ink else { return }
                stroke.append(value.location)
            }
            .onEnded { value in
                switch tool {
                case .ink:
                    if stroke.count > 1 { addInk() }
                    stroke = []
                case .sticky, .shape, .text:
                    add(tool, at: value.location)
                case .select:
                    // A click on empty canvas is how a selection is let go.
                    selectedItem = nil
                    if editingItem != nil, let item = items.first(where: { $0.id == editingItem }) {
                        commit(item)
                    }
                case .connector:
                    connectFrom = nil
                }
            }
    }

    private func add(_ tool: Tool, at point: CGPoint) {
        guard let boardID = selectedBoard else { return }

        let kind: WhiteboardItemKind = switch tool {
        case .sticky: .sticky
        case .shape: .shape
        case .text: .text
        default: .sticky
        }

        let item = WhiteboardItem(
            id: UUID().uuidString, boardID: boardID, kind: kind,
            x: point.x, y: point.y,
            width: kind == .text ? 160 : 140, height: kind == .text ? 40 : 100,
            text: "", color: kind == .sticky ? "yellow" : "blue",
            sortOrder: 0, createdAt: .now
        )
        model.add(item)
        reloadItems()

        // Straight into typing: a sticky you have to double-click before you
        // can write on it is a sticky nobody writes on.
        draft = ""
        editingItem = item.id
        selectedItem = item.id
    }

    private func addInk() {
        guard let boardID = selectedBoard else { return }
        model.add(WhiteboardItem(
            id: UUID().uuidString, boardID: boardID, kind: .ink,
            color: "graphite",
            strokeValues: WhiteboardItem.strokeValues(from: stroke),
            sortOrder: 0, createdAt: .now
        ))
        reloadItems()
    }

    private func addConnector(from: String, to: String) {
        guard let boardID = selectedBoard else { return }
        model.add(WhiteboardItem(
            id: UUID().uuidString, boardID: boardID, kind: .connector,
            color: "graphite", fromItem: from, toItem: to,
            sortOrder: 0, createdAt: .now
        ))
        reloadItems()
    }
}
