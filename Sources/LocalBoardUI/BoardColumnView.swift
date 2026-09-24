import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// One column of the board: a header, its cards, and a place to add another.
///
/// Two drop targets, not one. Each card accepts a drop meaning "above this
/// card"; the space below them accepts "at the end". Without the second, the
/// bottom of a column would be the one place a card could not be dropped.
struct BoardColumnView: View {

    let column: LoadedColumn
    let model: BoardViewModel

    @State private var newTitle = ""
    @State private var dropTarget: String?
    @State private var isRenaming = false
    @State private var renamedTo = ""
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(column.tasks) { task in
                        TaskCardView(task: task, tag: model.tag(for: task), model: model)
                            .draggable(task.id) {
                                // Drag preview: the title alone, so the cursor
                                // carries what was picked up, not a whole card.
                                Text(task.title)
                                    .padding(6)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .overlay(alignment: .top) { insertionIndicator(above: task.id) }
                            .dropDestination(for: String.self) { ids, _ in
                                dropTarget = nil
                                guard let dragged = ids.first else { return false }
                                model.move(dragged, toStatus: column.status.id, before: task.id)
                                return true
                            } isTargeted: { targeted in
                                dropTarget = targeted ? task.id : (dropTarget == task.id ? nil : dropTarget)
                            }
                    }

                    // The rest of the column: a drop here means "put it last".
                    Color.clear
                        .frame(minHeight: 60)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .top) { insertionIndicator(above: endOfColumn) }
                        .dropDestination(for: String.self) { ids, _ in
                            dropTarget = nil
                            guard let dragged = ids.first else { return false }
                            model.move(dragged, toStatus: column.status.id, before: nil)
                            return true
                        } isTargeted: { targeted in
                            dropTarget = targeted ? endOfColumn : (dropTarget == endOfColumn ? nil : dropTarget)
                        }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }

            addCardField
        }
        .frame(width: 300)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Sentinel for "below the last card" — a column has no task id there.
    private var endOfColumn: String { "\u{0}end" }

    private func insertionIndicator(above id: String) -> some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .opacity(dropTarget == id ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: dropTarget)
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(column.name)
                .font(.subheadline.weight(.semibold))

            Text("\(column.tasks.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())

            Spacer(minLength: 0)

            columnMenu

            if let limit = column.column.wipLimit {
                Label("\(column.tasks.count)/\(limit)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(column.isOverWIPLimit ? Color.orange : .secondary)
                    .opacity(column.isOverWIPLimit ? 1 : 0.55)
                    .help(column.isOverWIPLimit
                          ? "Over the limit of \(limit). Nothing is blocked; the board is just telling you."
                          : "Work-in-progress limit: \(limit)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .alert("Rename column", isPresented: $isRenaming) {
            TextField("Name", text: $renamedTo)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                model.renameColumn(column.id, to: renamedTo)
            }
        } message: {
            Text("The name is also what `status = \"…\"` matches in a query.")
        }
    }

    private var columnMenu: some View {
        Menu {
            Button("Rename…") {
                renamedTo = column.name
                isRenaming = true
            }

            Menu("Work-in-progress limit") {
                Button("No limit") { model.setWIPLimit(nil, for: column.id) }
                Divider()
                ForEach(1...10, id: \.self) { limit in
                    Button("\(limit)") { model.setWIPLimit(limit, for: column.id) }
                }
            }

            // The category is what makes "done" mean something to the rest of
            // the app — it is what stamps completed_at.
            Menu("Counts as") {
                Button("To do") { model.setCategory(.toDo, for: column.id) }
                Button("In progress") { model.setCategory(.inProgress, for: column.id) }
                Button("Done") { model.setCategory(.done, for: column.id) }
            }

            Divider()

            Button("Move Left") { moveLeft() }
                .disabled(neighbours.left == nil)
            Button("Move Right") { moveRight() }
                .disabled(neighbours.right == nil)

            Divider()

            if column.tasks.isEmpty {
                Button("Delete Column", systemImage: "trash", role: .destructive) {
                    model.deleteColumn(column.id, movingTasksTo: nil)
                }
            } else {
                // A column holding work cannot go without somewhere for the
                // work to land, so the choice is part of the action rather
                // than a dialog that follows it.
                Menu("Delete, Moving Cards To") {
                    ForEach(otherColumns) { other in
                        Button(other.name) {
                            model.deleteColumn(column.id, movingTasksTo: other.status.id)
                        }
                    }
                }
                .disabled(otherColumns.isEmpty)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rename, limit or remove this column")
        .accessibilityLabel("Column options for \(column.name)")
    }

    private var allColumns: [LoadedColumn] { model.snapshot?.columns ?? [] }

    private var otherColumns: [LoadedColumn] { allColumns.filter { $0.id != column.id } }

    private var neighbours: (left: LoadedColumn?, right: LoadedColumn?) {
        guard let index = allColumns.firstIndex(where: { $0.id == column.id }) else { return (nil, nil) }
        return (
            index > 0 ? allColumns[index - 1] : nil,
            index < allColumns.count - 1 ? allColumns[index + 1] : nil
        )
    }

    /// Swapping with a neighbour means landing on the far side of it.
    private func moveLeft() {
        guard let left = neighbours.left else { return }
        let index = allColumns.firstIndex { $0.id == left.id } ?? 0
        model.moveColumn(column.id, after: index > 0 ? allColumns[index - 1].id : nil, before: left.id)
    }

    private func moveRight() {
        guard let right = neighbours.right else { return }
        let index = allColumns.firstIndex { $0.id == right.id } ?? 0
        let beyond = index < allColumns.count - 1 ? allColumns[index + 1].id : nil
        model.moveColumn(column.id, after: right.id, before: beyond)
    }

    private var addCardField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Add a card", text: $newTitle)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($addFieldFocused)
                .onSubmit(submit)
                .accessibilityLabel("Add a card to \(column.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { addFieldFocused = true }
    }

    private func submit() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        model.addTask(title: title, toStatus: column.status.id)
        newTitle = ""
        // Stay focused: adding cards is something people do several times in a
        // row, and reaching for the mouse between each one is the slow way.
        addFieldFocused = true
    }
}
