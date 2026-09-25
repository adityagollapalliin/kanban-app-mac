import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// Documents: pages of Markdown that can nest, mention cards, and turn a
/// sentence into one.
///
/// The document *is* Markdown. Every slash command inserts Markdown rather
/// than some private structure, so the text stays readable by anything that
/// reads Markdown — which is the one thing a local-first document must not
/// give up.
struct DocsView: View {

    let model: BoardViewModel
    var onOpenInWindow: ((String) -> Void)?

    @State private var selected: String?
    @State private var title = ""
    @State private var body_ = ""
    @State private var docs: [Doc] = []
    @State private var isShowingSlashMenu = false
    @State private var selectionText = ""
    @State private var saveNotice: String?

    var body: some View {
        // A plain sidebar rather than an HSplitView: the split view sized the
        // page tree to its content and left it floating in the middle of the
        // window, because an empty List has no height to give it.
        HStack(spacing: 0) {
            tree
                .frame(width: 220)
                .frame(maxHeight: .infinity)

            Divider()

            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        docs = model.docs()
        if selected == nil { select(docs.first) }
    }

    private func select(_ doc: Doc?) {
        // Whatever was open is saved before moving: an editor that loses a
        // paragraph because somebody clicked the wrong page is not one people
        // keep writing in.
        save()
        selected = doc?.id
        title = doc?.title ?? ""
        body_ = doc?.bodyMarkdown ?? ""
    }

    private func save() {
        guard let selected, !title.isEmpty || !body_.isEmpty else { return }
        model.saveDoc(selected, title: title, body: body_)
        docs = model.docs()
    }

    // MARK: - The tree

    private var tree: some View {
        VStack(spacing: 0) {
            List {
                ForEach(rows) { row in
                    docRow(row.doc, depth: row.depth)
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Button {
                    if let made = model.createDoc(titled: "Untitled") {
                        docs = model.docs()
                        select(made)
                    }
                } label: {
                    Label("New Page", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// The tree, flattened to rows with a depth each.
    ///
    /// Written out rather than as a recursive view: a SwiftUI view that
    /// contains itself defines its own opaque type in terms of itself and
    /// will not compile. Flattening also means one list rather than a nest of
    /// scroll views, which is the arrangement that has bitten this app twice.
    private struct Row: Identifiable {
        let doc: Doc
        let depth: Int
        var id: String { doc.id }
    }

    private var rows: [Row] {
        var made: [Row] = []
        let byParent = Dictionary(grouping: docs.filter { $0.parentID != nil }) { $0.parentID! }

        func walk(_ doc: Doc, depth: Int) {
            made.append(Row(doc: doc, depth: depth))
            // A depth limit rather than trust: the store refuses to make a
            // ring, and this refuses to hang if one ever exists anyway.
            guard depth < 8 else { return }
            for child in (byParent[doc.id] ?? []).sorted(by: { $0.sortOrder < $1.sortOrder }) {
                walk(child, depth: depth + 1)
            }
        }

        for root in docs.filter({ $0.parentID == nil }).sorted(by: { $0.sortOrder < $1.sortOrder }) {
            walk(root, depth: 0)
        }
        return made
    }

    private func docRow(_ doc: Doc, depth: Int) -> some View {
        Button {
            select(doc)
        } label: {
            HStack(spacing: 5) {
                // Nesting is shown by indent rather than by a disclosure
                // triangle per level: a page inside a page inside a page is
                // three triangles to open before anything can be read.
                if depth > 0 {
                    Spacer().frame(width: CGFloat(depth) * 12)
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: doc.icon.isEmpty ? "doc.text" : doc.icon)
                    .font(.caption)
                    .foregroundStyle(selected == doc.id ? Color.accentColor : .secondary)

                Text(doc.title)
                    .foregroundStyle(selected == doc.id ? Color.accentColor : .primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("New Page Inside", systemImage: "plus") {
                if let made = model.createDoc(titled: "Untitled", parent: doc.id) {
                    docs = model.docs()
                    select(made)
                }
            }
            Button("Delete Page and Its Pages", systemImage: "trash", role: .destructive) {
                model.deleteDoc(doc.id)
                docs = model.docs()
                if selected == doc.id { select(docs.first) }
            }
        }
        .accessibilityLabel(depth == 0 ? doc.title : "\(doc.title), a page inside another")
    }

    // MARK: - The editor

    @ViewBuilder
    private var editor: some View {
        if selected == nil {
            ContentUnavailableView(
                "No page open",
                systemImage: "doc.text",
                description: Text("Make one with New Page, or pick one on the left.")
            )
        } else {
            VStack(spacing: 0) {
                toolbar
                Divider()

                TextEditor(text: $body_)
                    .font(.system(.body, design: .default))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .onChange(of: body_) { save() }

                if !linked.isEmpty {
                    Divider()
                    mentions
                }
            }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .onSubmit(save)

                Spacer(minLength: 0)

                if let saveNotice {
                    Text(saveNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Menu {
                    ForEach(SlashCommand.allCases) { command in
                        Button {
                            insert(command)
                        } label: {
                            Label(command.label, systemImage: command.symbol)
                        }
                    }
                } label: {
                    Label("Insert", systemImage: "slash.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("The same things “/” inserts: headings, lists, tables, code, callouts")

                Menu {
                    if model.visibleTasks.isEmpty {
                        Text("No cards to mention.")
                    }
                    ForEach(model.visibleTasks.prefix(25)) { task in
                        Button("\(model.tag(for: task))  \(task.title)") {
                            body_.append("@\(model.tag(for: task)) ")
                            save()
                        }
                    }
                } label: {
                    Label("Mention a card", systemImage: "at")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: 8) {
                TextField("Selected text to turn into a card", text: $selectionText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                Button("Make a Card") {
                    guard let selected else { return }
                    model.makeCard(fromDocText: selectionText, in: selected, body: body_, title: title)
                    body_ = model.docs().first { $0.id == selected }?.bodyMarkdown ?? body_
                    selectionText = ""
                    docs = model.docs()
                }
                .disabled(selectionText.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Makes a card and leaves a mention of it in its place, so the page still says what was decided")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func insert(_ command: SlashCommand) {
        if !body_.isEmpty, !body_.hasSuffix("\n") { body_.append("\n") }
        body_.append(command.snippet)
        save()
    }

    private var linked: [BoardTask] {
        guard let selected else { return [] }
        return model.linkedTasks(ofDoc: selected)
    }

    /// The cards this page mentions, with their state now rather than as it
    /// was when somebody typed the mention — which is the whole point of a
    /// link over a copied title.
    private var mentions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mentions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(linked) { task in
                        Button {
                            model.selectedTaskID = task.id
                        } label: {
                            HStack(spacing: 4) {
                                Text(model.tag(for: task))
                                    .font(.caption2.monospaced())
                                Text(task.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(model.statusName(task.statusID))
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(statusColor(task).opacity(0.22), in: Capsule())
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open in a Window", systemImage: "macwindow") {
                                onOpenInWindow?(task.id)
                            }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func statusColor(_ task: BoardTask) -> Color {
        switch model.category(of: task) {
        case .toDo: .secondary
        case .inProgress: .blue
        case .done: .green
        }
    }
}

/// The pages that mention a card, shown on the card.
///
/// The other half of a mention: a document says what was decided, and the card
/// says where that was written down.
struct BacklinksSection: View {

    let task: BoardTask
    let model: BoardViewModel

    var body: some View {
        Section("Mentioned in") {
            if model.backlinks.isEmpty {
                Text("No page mentions this card.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.backlinks) { doc in
                Label(doc.title, systemImage: doc.icon.isEmpty ? "doc.text" : doc.icon)
                    .font(.callout)
            }
        }
        .onAppear { model.loadBacklinks(forTask: task.id) }
        .onChange(of: task.id) { model.loadBacklinks(forTask: task.id) }
    }
}
