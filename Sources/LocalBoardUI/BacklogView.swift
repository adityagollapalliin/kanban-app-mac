import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The backlog: work that has been written down but not yet committed to.
///
/// A list rather than a column, because a backlog is read top to bottom and is
/// usually far longer than a column. The line at the bottom is the point of
/// the screen: dragging a card past it is the commitment, and only then does
/// the work start counting against the board's limits.
struct BacklogView: View {

    let model: BoardViewModel
    var onOpenInWindow: ((String) -> Void)?
    var onBack: () -> Void = {}

    @State private var newTitle = ""
    @FocusState private var addFocused: Bool

    private var backlog: LoadedColumn? { model.snapshot?.backlog }

    /// Where a committed card lands: the board's first column.
    private var commitmentColumn: LoadedColumn? { model.visibleColumns.first }

    var body: some View {
        if let backlog {
            VStack(alignment: .leading, spacing: 0) {
                header(backlog)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(backlog.tasks) { task in
                            TaskCardView(
                                task: task,
                                tag: model.tag(for: task),
                                model: model,
                                onOpenInWindow: onOpenInWindow
                            )
                            .draggable(task.id)
                            .frame(maxWidth: 560)
                        }

                        if backlog.tasks.isEmpty {
                            Text("Nothing waiting. Anything added here stays off the board until you commit to it.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(16)
                }

                commitmentLine

                addField(backlog)
            }
        } else {
            ContentUnavailableView(
                "No backlog on this board",
                systemImage: "tray.2",
                description: Text("Mark a column as the backlog from its ⋯ menu.")
            )
        }
    }

    private func header(_ backlog: LoadedColumn) -> some View {
        HStack(spacing: 8) {
            Label(backlog.name, systemImage: "tray.2")
                .font(.headline)

            Text("\(backlog.tasks.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())

            Spacer()

            Button("Back to Board", systemImage: "rectangle.split.3x1", action: onBack)
            .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The commitment point, drawn as a line you drop across.
    ///
    /// Named after the column it commits to rather than "Selected for
    /// Development", because the board's own first column is what the card
    /// will actually land in and a second name for it would be a lie waiting
    /// to happen.
    @ViewBuilder
    private var commitmentLine: some View {
        if let commitmentColumn {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Rectangle().fill(.tertiary).frame(height: 1)
                    Label("Commit to \(commitmentColumn.name)", systemImage: "arrow.down.to.line")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Rectangle().fill(.tertiary).frame(height: 1)
                }

                Text("Drop a card here to start it. It counts against the column's limit from then on.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.3))
            .dropDestination(for: String.self) { ids, _ in
                guard let dragged = ids.first else { return false }
                model.move(dragged, toStatus: commitmentColumn.status.id, before: nil)
                return true
            }
        }
    }

    private func addField(_ backlog: LoadedColumn) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Add to the backlog", text: $newTitle)
                .textFieldStyle(.plain)
                .focused($addFocused)
                .onSubmit {
                    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    model.addTask(title: title, toStatus: backlog.status.id)
                    newTitle = ""
                    addFocused = true
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
