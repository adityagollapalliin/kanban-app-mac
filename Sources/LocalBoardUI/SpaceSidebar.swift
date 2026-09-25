import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The sidebar: spaces, the folders and lists inside them, and the shortcuts
/// back to wherever you were.
///
/// The hierarchy is drawn as deep as it goes and no deeper. A space with no
/// folders shows its lists directly rather than an empty "Lists" heading; a
/// space with one list — which is every space on a file that has never made a
/// second — shows it the way it always did. Structure the user has not created
/// does not appear as scaffolding they have to read past.
struct SpaceSidebar: View {

    @Bindable var model: BoardViewModel
    /// Making a space asks for a name *and* a key, which is two fields and a
    /// validation rule — so it stays in the board's own sheet rather than
    /// being a third kind of alert in here.
    var onNewSpace: () -> Void

    @State private var isAddingFolder = false
    @State private var isAddingList = false
    @State private var newName = ""
    @State private var folderForNewList: String?
    @State private var renaming: (kind: ShortcutTarget, id: String)?
    @State private var renamedTo = ""
    @State private var deletingList: TaskList?
    @State private var showsArchive = false
    @State private var showsTrash = false

    var body: some View {
        List(selection: $model.selectedBoardID) {
            if !model.favorites.isEmpty { shortcutSection(model.favorites, kind: .favorite) }
            if !model.pinnedViews.isEmpty { shortcutSection(model.pinnedViews, kind: .pinnedView) }

            ForEach(model.projects) { project in
                spaceSection(project)
            }

            Section("Views") {
                ForEach(model.savedViews) { view in
                    savedViewRow(view)
                }
                trashRow
                archiveRow
            }

            if !model.recents.isEmpty { shortcutSection(model.recents, kind: .recent) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { newSpaceBar }
        .sheet(isPresented: $showsArchive) { ArchiveSheet(model: model) }
        .sheet(isPresented: $showsTrash) { TrashSheet(model: model) }
        .alert("New folder", isPresented: $isAddingFolder) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { model.createFolder(named: newName) }
        } message: {
            Text("A folder holds lists. It is optional — a list can sit straight in the space.")
        }
        .alert("New list", isPresented: $isAddingList) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { model.createList(named: newName, inFolder: folderForNewList) }
        } message: {
            Text("A list holds cards. Every card has one it calls home.")
        }
        .alert("Rename", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renamedTo)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let renaming else { return }
                switch renaming.kind {
                case .folder: model.renameFolder(renaming.id, to: renamedTo)
                case .list: model.renameList(renaming.id, to: renamedTo)
                default: break
                }
            }
        }
        .sheet(item: $deletingList) { list in
            DeleteListSheet(list: list, model: model)
        }
    }

    // MARK: - One space

    private func spaceSection(_ project: Project) -> some View {
        Section {
            ForEach(model.boards.filter { $0.projectID == project.id }) { board in
                boardRow(board, in: project)
            }

            if project.id == model.currentProjectID {
                ForEach(model.folders) { folder in
                    folderRow(folder)
                }
                ForEach(model.looseLists) { list in
                    listRow(list).padding(.leading, 2)
                }
            }
        } header: {
            spaceHeader(project)
        }
    }

    private func spaceHeader(_ project: Project) -> some View {
        HStack(spacing: 6) {
            if !project.icon.isEmpty {
                Image(systemName: project.icon)
                    .font(.caption)
                    .foregroundStyle(spaceColor(project))
            } else {
                // A space with no icon still gets a mark, so the sidebar reads
                // as a column of spaces rather than a column of words.
                Circle()
                    .fill(spaceColor(project))
                    .frame(width: 7, height: 7)
            }

            Text(project.name)

            Text(project.key)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
        .contextMenu {
            Button("New List…", systemImage: "list.bullet") {
                newName = ""
                folderForNewList = nil
                isAddingList = true
            }
            Button("New Folder…", systemImage: "folder.badge.plus") {
                newName = ""
                isAddingFolder = true
            }
            Button("New Board…", systemImage: "rectangle.split.3x1") {
                model.createBoard(named: "Board", inProject: project.id)
            }

            Divider()

            Menu("Colour") {
                Button("None") { model.setSpaceAppearance(color: "", icon: project.icon, for: project.id) }
                ForEach(PaletteColor.allCases) { colour in
                    Button(colour.displayName) {
                        model.setSpaceAppearance(color: colour.rawValue, icon: project.icon, for: project.id)
                    }
                }
            }
            Menu("Icon") {
                Button("None") { model.setSpaceAppearance(color: project.color, icon: "", for: project.id) }
                ForEach(Self.icons, id: \.self) { symbol in
                    Button {
                        model.setSpaceAppearance(color: project.color, icon: symbol, for: project.id)
                    } label: {
                        Label(symbol, systemImage: symbol)
                    }
                }
            }
            Button(model.isFavorite(.space, id: project.id) ? "Remove from Favourites" : "Add to Favourites",
                   systemImage: "star") {
                model.toggleFavorite(.space, id: project.id, label: project.name)
            }

            Divider()

            Button("Archive Space", systemImage: "archivebox") {
                model.setSpaceArchived(true, for: project.id)
            }
            Button("Delete Space", systemImage: "trash", role: .destructive) {
                model.deleteProject(project.id)
            }
        }
    }

    /// A short, deliberately small set. A picker over every SF Symbol is a
    /// search problem; a dozen recognisable ones is a choice.
    static let icons = [
        "square.stack.3d.up", "hammer", "paintbrush", "bolt", "chart.line.uptrend.xyaxis",
        "cart", "heart", "graduationcap", "airplane", "house", "leaf", "flame",
    ]

    private func spaceColor(_ project: Project) -> Color {
        project.color.isEmpty ? Color.accentColor : PaletteColor.named(project.color).color
    }

    private func boardRow(_ board: Board, in project: Project) -> some View {
        Label(board.name, systemImage: "rectangle.split.3x1")
            .tag(board.id)
            .contextMenu {
                Button("Rename Board…") {
                    renamedTo = board.name
                }
                Button(model.isFavorite(.board, id: board.id) ? "Remove from Favourites" : "Add to Favourites",
                       systemImage: "star") {
                    model.toggleFavorite(.board, id: board.id, label: board.name)
                }
                Button("Delete Board", systemImage: "trash", role: .destructive) {
                    model.deleteBoard(board.id)
                }
                .disabled(model.boards.filter { $0.projectID == project.id }.count < 2)
            }
    }

    // MARK: - Folders and lists

    private func folderRow(_ folder: Folder) -> some View {
        DisclosureGroup {
            ForEach(model.lists(inFolder: folder.id)) { list in
                listRow(list)
            }
        } label: {
            Label(folder.name, systemImage: "folder")
                .contextMenu {
                    Button("New List Here…", systemImage: "list.bullet") {
                        newName = ""
                        folderForNewList = folder.id
                        isAddingList = true
                    }
                    Button("Rename…") {
                        renamedTo = folder.name
                        renaming = (.folder, folder.id)
                    }
                    Button("Archive", systemImage: "archivebox") {
                        model.setFolderArchived(true, for: folder.id)
                    }
                    // Deliberately not destructive to the lists: they fall
                    // back into the space, and the menu says so.
                    Button("Delete Folder, Keeping Its Lists", systemImage: "trash", role: .destructive) {
                        model.deleteFolder(folder.id)
                    }
                }
        }
    }

    private func listRow(_ list: TaskList) -> some View {
        let isActive = model.selectedListID == list.id

        return Button {
            model.selectedListID = isActive ? nil : list.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: list.icon.isEmpty ? "list.bullet" : list.icon)
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)

                Text(list.name)
                    .foregroundStyle(isActive ? Color.accentColor : .primary)

                Spacer(minLength: 0)

                let count = model.taskCount(inList: list.id)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(list.name), \(model.taskCount(inList: list.id)) cards")
        .accessibilityHint(isActive ? "Shows the whole space again" : "Narrows the board to this list")
        .contextMenu {
            Button("Rename…") {
                renamedTo = list.name
                renaming = (.list, list.id)
            }
            Menu("Move to Folder") {
                Button("None") { model.moveList(list.id, toFolder: nil) }
                ForEach(model.folders) { folder in
                    Button(folder.name) { model.moveList(list.id, toFolder: folder.id) }
                }
            }
            Button(model.isFavorite(.list, id: list.id) ? "Remove from Favourites" : "Add to Favourites",
                   systemImage: "star") {
                model.toggleFavorite(.list, id: list.id, label: list.name)
            }

            Divider()

            Button("Archive", systemImage: "archivebox") {
                model.setListArchived(true, for: list.id)
            }
            Button("Delete…", systemImage: "trash", role: .destructive) {
                deletingList = list
            }
        }
    }

    // MARK: - Shortcuts

    private func shortcutSection(_ shortcuts: [Shortcut], kind: ShortcutKind) -> some View {
        Section(kind.label) {
            ForEach(shortcuts) { shortcut in
                Button {
                    model.open(shortcut)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: shortcut.target.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(shortcut.label.isEmpty ? "Untitled" : shortcut.label)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(kind == .recent ? "Forget" : "Remove", systemImage: "minus.circle") {
                        model.unpin(shortcut)
                    }
                }
            }
        }
    }

    private var trashRow: some View {
        Button {
            showsTrash = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                Text("Trash")
                Spacer(minLength: 0)
                if !model.trashedTasks.isEmpty {
                    Text("\(model.trashedTasks.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Cards you have thrown away. They are removed thirty days after that.")
    }

    private var archiveRow: some View {
        Button {
            showsArchive = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                Text("Archive")
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Spaces, folders and lists you have put away. Nothing here is deleted.")
    }

    private func savedViewRow(_ view: SavedView) -> some View {
        let isActive = model.queryText == view.query

        return Button {
            model.apply(view)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle\(isActive ? ".fill" : "")")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(view.name)
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(view.query)
        .accessibilityHint("Filters the board by: \(view.query)")
        .contextMenu {
            Button("Pin to the Sidebar", systemImage: "pin") {
                model.pinView(view.name, query: view.query)
            }
            Button("Delete View", systemImage: "trash", role: .destructive) {
                model.deleteSavedView(view.id)
            }
        }
    }

    private var newSpaceBar: some View {
        HStack(spacing: 10) {
            Button {
                newName = ""
                folderForNewList = nil
                isAddingList = true
            } label: {
                Label("New List", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(model.currentProjectID == nil)

            Button(action: onNewSpace) {
                Label("New Space", systemImage: "square.stack.3d.up")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Deleting a list has to say where its cards go, because a list cannot be
/// taken out from under them.
private struct DeleteListSheet: View {
    let list: TaskList
    let model: BoardViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var destination: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete “\(list.name)”")
                .font(.headline)

            Text("""
                This list holds \(model.taskCount(inList: list.id)) cards. \
                They have to go somewhere: another list, or the trash — which \
                keeps them for thirty days.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Move its cards to", selection: $destination) {
                Text("The trash").tag(String?.none)
                ForEach(model.lists.filter { $0.id != list.id }) { other in
                    Text(other.name).tag(String?.some(other.id))
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete the List") {
                    model.deleteList(list.id, movingCardsTo: destination)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// What has been put away. Archiving keeps everything and hides it, so this is
/// the way back rather than a record of what was lost.
private struct ArchiveSheet: View {
    let model: BoardViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Archive")
                .font(.headline)

            if model.archivedFolders.isEmpty, model.archivedLists.isEmpty {
                ContentUnavailableView(
                    "Nothing is archived",
                    systemImage: "archivebox",
                    description: Text("Archiving a list or folder puts it here and hides it from the sidebar.")
                )
                .frame(height: 200)
            } else {
                List {
                    if !model.archivedFolders.isEmpty {
                        Section("Folders") {
                            ForEach(model.archivedFolders) { folder in
                                row(folder.name, symbol: "folder") {
                                    model.setFolderArchived(false, for: folder.id)
                                }
                            }
                        }
                    }
                    if !model.archivedLists.isEmpty {
                        Section("Lists") {
                            ForEach(model.archivedLists) { list in
                                row(list.name, symbol: "list.bullet") {
                                    model.setListArchived(false, for: list.id)
                                }
                            }
                        }
                    }
                }
                .frame(height: 280)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func row(_ name: String, symbol: String, restore: @escaping () -> Void) -> some View {
        HStack {
            Label(name, systemImage: symbol)
            Spacer()
            Button("Put Back", action: restore)
                .buttonStyle(.borderless)
        }
    }
}

/// The trash, with how long each card has left.
private struct TrashSheet: View {
    let model: BoardViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trash")
                .font(.headline)

            Text("Cards are removed thirty days after they are thrown away.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.trashedTasks.isEmpty {
                ContentUnavailableView(
                    "The trash is empty",
                    systemImage: "trash",
                    description: Text("Nothing has been thrown away.")
                )
                .frame(height: 200)
            } else {
                List(model.trashedTasks) { task in
                    HStack(spacing: 8) {
                        Text(model.tag(for: task))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        Text(task.title)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if let days = model.daysLeftInTrash(task) {
                            Text(days == 0 ? "Goes today" : "\(days) days left")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(days <= 3 ? .orange : .secondary)
                        }

                        Button("Put Back") { model.restoreFromTrash(task.id) }
                            .buttonStyle(.borderless)
                    }
                }
                .frame(height: 280)
            }

            HStack {
                Button("Empty the Trash", role: .destructive) { isConfirmingEmpty = true }
                    .disabled(model.trashedTasks.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .alert("Empty the trash?", isPresented: $isConfirmingEmpty) {
            Button("Cancel", role: .cancel) {}
            Button("Empty It", role: .destructive) { model.emptyTrash() }
        } message: {
            Text("This deletes \(model.trashedTasks.count) cards for good. It cannot be undone.")
        }
    }
}
