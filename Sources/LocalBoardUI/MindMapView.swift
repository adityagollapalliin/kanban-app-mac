import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// Cards and their subtasks as a graph.
///
/// The nodes are not a drawing of the work — they *are* the work. Adding a
/// node creates a card; dragging one under another makes it a subtask;
/// renaming one renames the card. A mind map that was a separate picture would
/// be a second copy of the plan to keep in step by hand, which is the thing
/// nobody ever does.
///
/// Positions are computed from the tree rather than stored. That is a
/// deliberate limit: it means the map cannot be arranged by hand, and in
/// exchange there is no layout to migrate, go stale, or disagree with the
/// cards it describes.
struct MindMapView: View {

    let model: BoardViewModel
    var onOpenInWindow: ((String) -> Void)?

    @State private var scale: CGFloat = 1
    @State private var renaming: String?
    @State private var draft = ""
    @State private var addingUnder: String?

    /// How many nodes the map draws.
    ///
    /// Every node is a real view and they are all built at once — a map has no
    /// scrolling region of its own to be lazy inside, and curves have to be
    /// drawn between nodes that both exist. A thousand of them cost 297 MB,
    /// which is most of the app's whole budget for a picture nobody can read.
    /// So the map draws the first hundred and fifty and says what it is not
    /// showing; narrowing the filters is how you see the rest.
    private static let nodeCap = 150

    private static let nodeWidth: CGFloat = 150
    private static let nodeHeight: CGFloat = 34
    private static let columnGap: CGFloat = 70
    private static let rowGap: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            canvas
        }
        .alert("Rename", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Title", text: $draft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renaming { model.rename(renaming, to: draft) }
            }
        }
        .alert("New card", isPresented: Binding(
            get: { addingUnder != nil },
            set: { if !$0 { addingUnder = nil } }
        )) {
            TextField("Title", text: $draft)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                guard let parent = addingUnder else { return }
                model.addSubtask(draft, to: parent)
            }
        } message: {
            Text("It becomes a subtask of the card you added it under — a real card, on the board.")
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if hiddenCount > 0 {
                Label(
                    "Showing \(Self.nodeCap) of \(allNodes.count) cards — filter to see the rest",
                    systemImage: "eye.slash"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                Text("Cards and their subtasks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                scale = max(0.5, scale - 0.15)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Zoom out")

            Text("\(Int(scale * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44)

            Button {
                scale = min(2, scale + 0.15)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Zoom in")

            Button("Fit") { scale = 1 }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canvas: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                // The lines are drawn once underneath rather than per node, so
                // a map of two hundred cards is one shape, not two hundred.
                Canvas { context, _ in
                    for node in nodes where node.parent != nil {
                        guard let parent = nodes.first(where: { $0.id == node.parent }) else { continue }
                        var path = Path()
                        let from = CGPoint(x: parent.x + Self.nodeWidth, y: parent.y + Self.nodeHeight / 2)
                        let to = CGPoint(x: node.x, y: node.y + Self.nodeHeight / 2)
                        path.move(to: from)
                        path.addCurve(
                            to: to,
                            control1: CGPoint(x: from.x + Self.columnGap / 2, y: from.y),
                            control2: CGPoint(x: to.x - Self.columnGap / 2, y: to.y)
                        )
                        context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
                    }
                }
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)

                ForEach(nodes) { node in
                    nodeView(node)
                        .offset(x: node.x, y: node.y)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mind map of \(nodes.count) cards")
    }

    private func nodeView(_ node: Node) -> some View {
        let task = node.task

        return HStack(spacing: 5) {
            Image(systemName: CardAppearance.symbol(forType: task.type))
                .font(.system(size: 9))
                .foregroundStyle(CardAppearance.color(forType: task.type))

            Text(task.title)
                .font(.caption)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: Self.nodeWidth, height: Self.nodeHeight, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(
                    model.selectedTaskID == task.id ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: model.selectedTaskID == task.id ? 2 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { model.selectedTaskID = task.id }
        .draggable(task.id) {
            Text(task.title).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let dragged = ids.first, dragged != task.id else { return false }
            // Dropping one node on another is how the tree is rearranged, and
            // it is the same edit as choosing a parent in the card's panel.
            model.setParent(task.id, for: dragged)
            return true
        }
        .contextMenu {
            Button("Add a Card Under This", systemImage: "plus") {
                draft = ""
                addingUnder = task.id
            }
            Button("Rename…", systemImage: "pencil") {
                draft = task.title
                renaming = task.id
            }
            if task.parentID != nil {
                Button("Detach from Its Parent", systemImage: "scissors") {
                    model.setParent(nil, for: task.id)
                }
            }
            Divider()
            Button("Open in a Window", systemImage: "macwindow") { onOpenInWindow?(task.id) }
        }
        .accessibilityLabel("\(model.tag(for: task)), \(task.title)")
        .accessibilityHint(node.parent == nil ? "A card with no parent" : "A subtask")
    }

    // MARK: - Layout

    private struct Node: Identifiable {
        let id: String
        let task: BoardTask
        let parent: String?
        let depth: Int
        var x: CGFloat
        var y: CGFloat
    }

    /// What is drawn: the first `nodeCap` of them.
    private var nodes: [Node] {
        Array(allNodes.prefix(Self.nodeCap))
    }

    private var hiddenCount: Int { max(0, allNodes.count - Self.nodeCap) }

    /// Laid out depth-first, so a card's children sit directly under it rather
    /// than wherever a breadth-first pass happens to leave them.
    private var allNodes: [Node] {
        let all = model.visibleTasks
        let byParent = Dictionary(grouping: all.filter { $0.parentID != nil }) { $0.parentID! }
        // A card whose parent is filtered away is a root here rather than an
        // orphan floating with no line back: the map draws what is on screen.
        let present = Set(all.map(\.id))
        let roots = all.filter { task in
            guard let parentID = task.parentID else { return true }
            return !present.contains(parentID)
        }

        var made: [Node] = []
        var row: CGFloat = 0

        func place(_ task: BoardTask, depth: Int) {
            made.append(Node(
                id: task.id,
                task: task,
                parent: task.parentID,
                depth: depth,
                x: CGFloat(depth) * (Self.nodeWidth + Self.columnGap),
                y: row * (Self.nodeHeight + Self.rowGap)
            ))
            row += 1
            for child in (byParent[task.id] ?? []).sorted(by: { $0.sortOrder < $1.sortOrder }) {
                place(child, depth: depth + 1)
            }
        }

        for root in roots.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            place(root, depth: 0)
        }
        return made
    }

    private var size: CGSize {
        let depth = (nodes.map(\.depth).max() ?? 0) + 1
        let rows = max(1, nodes.count)
        return CGSize(
            width: CGFloat(depth) * (Self.nodeWidth + Self.columnGap),
            height: CGFloat(rows) * (Self.nodeHeight + Self.rowGap)
        )
    }
}
