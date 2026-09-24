import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// One card on the board.
///
/// The card shows what can be read at a glance and judged without opening it:
/// the tag, the title, and only those markers that are actually set. A card
/// with no due date and normal priority shows neither, so the ones that do
/// carry meaning stand out instead of being lost in a row of default badges.
struct TaskCardView: View {

    let task: BoardTask
    let tag: String
    let model: BoardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(tag)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if task.type != .task {
                    Image(systemName: typeSymbol)
                        .font(.caption2)
                        .foregroundStyle(typeColor)
                        .help(typeLabel)
                }

                if task.priority != .normal {
                    Image(systemName: prioritySymbol)
                        .font(.caption2)
                        .foregroundStyle(priorityColor)
                        .help("\(priorityLabel) priority")
                }
            }

            Text(task.title)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let due = task.dueDate {
                Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    .font(.caption2)
                    .foregroundStyle(isOverdue ? Color.red : .secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tag). \(task.title)")
        .contextMenu {
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                model.setTrashed(true, for: task.id)
            }
        }
    }

    private var isOverdue: Bool {
        guard let due = task.dueDate, task.completedAt == nil else { return false }
        return due < Date()
    }

    private var typeSymbol: String {
        switch task.type {
        case .epic: "flag.fill"
        case .story: "book.closed.fill"
        case .task: "checkmark.square"
        case .bug: "ladybug.fill"
        }
    }

    private var typeLabel: String {
        switch task.type {
        case .epic: "Epic"
        case .story: "Story"
        case .task: "Task"
        case .bug: "Bug"
        }
    }

    private var typeColor: Color {
        switch task.type {
        case .epic: .purple
        case .story: .green
        case .task: .secondary
        case .bug: .red
        }
    }

    /// Priority reads as a direction, so the arrow carries it and the colour
    /// only reinforces it — the board stays legible without colour.
    private var prioritySymbol: String {
        switch task.priority {
        case .lowest: "chevron.down.2"
        case .low: "chevron.down"
        case .normal: "minus"
        case .high: "chevron.up"
        case .highest: "chevron.up.2"
        }
    }

    private var priorityLabel: String {
        switch task.priority {
        case .lowest: "Lowest"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .highest: "Highest"
        }
    }

    private var priorityColor: Color {
        switch task.priority {
        case .lowest, .low: .secondary
        case .normal: .secondary
        case .high: .orange
        case .highest: .red
        }
    }
}
