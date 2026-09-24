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
