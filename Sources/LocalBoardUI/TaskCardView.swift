import AppKit
import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// One card on the board.
///
/// The card shows what can be read at a glance and judged without opening it.
/// Two rules keep it that way as it gains fields:
///
///  * **Intrinsic markers appear only when set.** A card with normal priority
///    and no flag shows neither, so the ones that do carry meaning stand out
///    instead of being lost in a row of defaults.
///  * **Everything else is the board's choice.** The extra rows come from
///    `board.cardFields`, capped at three. A card that shows everything shows
///    nothing, because nobody reads it.
struct TaskCardView: View {

    let task: BoardTask
    let tag: String
    let model: BoardViewModel

    /// Opening a card in its own window is the board's job, not the card's —
    /// it owns the window group.
    var onOpenInWindow: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            stripe

            VStack(alignment: .leading, spacing: model.density.cardSpacing - 2) {
                headerRow
                if fields.contains(.labels) { labelChips }
                titleRow
                if !footerIsEmpty { footerRow }
            }
            .padding(model.density.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        // Where the keyboard is, drawn as a ring outside the border so it can
        // be seen on a card that is also open or picked — three different
        // things that can all be true of one card at once.
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
                .padding(-3)
        }
        .opacity(task.trashed ? 0.6 : 1)
        .overlay(border)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: handleTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isOpen || isPicked ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isOpen ? "Closes the card" : "Opens the card for editing")
        .contextMenu { menu }
    }

    // MARK: - Pieces

    /// The colour rule's answer, drawn down the leading edge rather than as a
    /// tint: a full-card wash fights the text, and a stripe does not.
    @ViewBuilder
    private var stripe: some View {
        if let color = CardAppearance.stripe(for: task, model: model) {
            Rectangle()
                .fill(color)
                .frame(width: 4)
                .accessibilityHidden(true)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(tag)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            // The flag leads the markers: what is in the way matters more than
            // what kind of thing it is.
            if task.flagged {
                Image(systemName: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .help(task.flagReason.isEmpty ? "Flagged" : task.flagReason)
            }

            if task.type != .task {
                Image(systemName: typeSymbol)
                    .font(.caption2)
                    .foregroundStyle(typeColor)
                    .help(typeLabel)
            }

            if task.trashed {
                Image(systemName: "trash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("In the trash")
            }

            if task.priority != .normal {
                Image(systemName: prioritySymbol)
                    .font(.caption2)
                    .foregroundStyle(priorityColor)
                    .help("\(priorityLabel) priority")
            }
        }
    }

    private var labelChips: some View {
        let labels = model.labels(for: task)
        return Group {
            if !labels.isEmpty {
                // Wrapped rather than truncated: a card's labels are the part
                // you scan for, and a hidden one may as well not be set.
                FlowLayout(spacing: 4) {
                    ForEach(labels) { label in
                        Text(label.name)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(PaletteColor.named(label.color).color.opacity(0.22), in: Capsule())
                            .overlay(
                                Capsule().strokeBorder(
                                    PaletteColor.named(label.color).color.opacity(0.45), lineWidth: 1
                                )
                            )
                    }
                }
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(task.title)
                .font(.callout)
                .foregroundStyle(task.trashed ? .secondary : .primary)
                .strikethrough(task.trashed, color: .secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if fields.contains(.assignee), let person = model.person(id: task.assigneeID) {
                AssigneeAvatar(person: person)
            }
        }
    }

    /// The board's chosen rows, plus the two structural markers a card always
    /// carries: that it is a subtask, and the flag's reason.
    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if task.flagged, !task.flagReason.isEmpty {
                Label(task.flagReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if fields.contains(.epic), let epic = model.epic(for: task) {
                Label(epic.title, systemImage: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                if fields.contains(.dueDate), let due = task.dueDate {
                    Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(isOverdue ? Color.red : .secondary)
                }

                if fields.contains(.points), let estimate = task.estimate {
                    Label(Self.points.string(from: estimate as NSNumber) ?? "\(estimate)",
                          systemImage: "number")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if fields.contains(.checklist), let checklist = model.checklistProgress(for: task),
                   checklist.total > 0 {
                    Label("\(checklist.done)/\(checklist.total)", systemImage: "checklist")
                        .font(.caption2)
                        .foregroundStyle(checklist.isComplete ? Color.green : .secondary)
                }

                if fields.contains(.version), let version = model.version(id: task.versionID) {
                    Label(version.name, systemImage: "shippingbox")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let subtasks = model.subtaskProgress(for: task), subtasks.total > 0 {
                    Label("\(subtasks.done)/\(subtasks.total)", systemImage: "list.bullet.indent")
                        .font(.caption2)
                        .foregroundStyle(subtasks.isComplete ? Color.green : .secondary)
                }

                if task.parentID != nil {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("A subtask")
                }

                // Not among the board's chosen rows: a conversation or a file
                // on a card is something you need to know is there before you
                // decide whether to open it, whatever else the board is showing.
                if model.commentCount(for: task) > 0 {
                    Label("\(model.commentCount(for: task))", systemImage: "text.bubble")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if model.attachmentCount(for: task) > 0 {
                    Label("\(model.attachmentCount(for: task))", systemImage: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // The project's own fields, named on the chip because "8"
                // alone says nothing about which field it came from.
                ForEach(shownCustomFields, id: \.field.id) { entry in
                    Text("\(entry.field.name) \(entry.value.display())")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if fields.contains(.daysInColumn) {
                    DaysInColumnDots(days: daysInColumn, threshold: staleThreshold)
                }
            }
        }
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(borderColor, lineWidth: isOpen || isPicked ? 2 : 1)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Get Info", systemImage: "info.circle") {
            model.selectedTaskID = task.id
        }
        if let onOpenInWindow {
            Button("Open in New Window", systemImage: "macwindow.on.rectangle") {
                onOpenInWindow(task.id)
            }
        }

        Divider()

        if task.flagged {
            Button("Remove Flag", systemImage: "flag.slash") {
                model.setFlag(false, for: task.id)
            }
        } else {
            Button("Flag", systemImage: "flag") {
                model.setFlag(true, for: task.id)
            }
        }

        Button(isPicked ? "Deselect" : "Select", systemImage: "checkmark.circle") {
            model.togglePicked(task.id)
        }

        Divider()

        if task.trashed {
            Button("Put Back", systemImage: "arrow.uturn.backward") {
                model.restore(task.id)
            }
        } else {
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                model.setTrashed(true, for: task.id)
            }
        }
    }

    // MARK: - Behaviour

    /// Plain click opens the card; ⌘-click and shift-click build a selection.
    ///
    /// The modifiers are read from the live event rather than from a SwiftUI
    /// gesture modifier, because the gesture APIs that report them are newer
    /// than this app's deployment target and this is exactly the macOS
    /// convention people already have in their fingers.
    private func handleTap() {
        let modifiers = NSEvent.modifierFlags

        // Clicking a card is also where the keyboard picks up from, so the
        // arrow keys continue from what was last touched rather than jumping
        // back to the top left.
        model.focus(task.id)

        if modifiers.contains(.shift) {
            model.extendPick(to: task.id)
        } else if modifiers.contains(.command) {
            model.togglePicked(task.id)
        } else if modifiers.contains(.option), let onOpenInWindow {
            onOpenInWindow(task.id)
        } else {
            // A plain click on the board is also how a selection is dismissed,
            // so it does not linger invisibly behind the inspector.
            if model.hasSelection { model.clearPicks() }
            model.toggleSelection(of: task.id)
        }
    }

    // MARK: - Reading

    private var fields: [CardField] { model.snapshot?.board.cardFields ?? [] }

    /// The project's own fields this board shows, skipping the ones this card
    /// has nothing to say about.
    private var shownCustomFields: [(field: CustomField, value: CustomFieldValue)] {
        let chosen = model.snapshot?.board.customCardFieldIDs ?? []
        guard !chosen.isEmpty else { return [] }

        let values = model.customValues(for: task)
        return chosen.compactMap { id in
            guard let field = model.customFields.first(where: { $0.id == id }),
                  let value = values[id], !value.isEmpty else { return nil }
            return (field, value)
        }
    }

    private var staleThreshold: Int { model.snapshot?.board.staleDays ?? 3 }

    private var daysInColumn: Int { task.daysInColumn(now: .now) }

    private var isOpen: Bool { model.selectedTaskID == task.id }

    /// Where the keyboard is. Not the same as open and not the same as
    /// picked: focus travels without changing anything.
    private var isFocused: Bool { model.focusedTaskID == task.id }

    private var isPicked: Bool { model.isPicked(task.id) }

    private var borderColor: Color {
        if isPicked { return .accentColor }
        if isOpen { return .accentColor }
        return Color(nsColor: .separatorColor)
    }

    private var footerIsEmpty: Bool {
        if task.flagged, !task.flagReason.isEmpty { return false }
        if task.parentID != nil { return false }
        if model.commentCount(for: task) > 0 { return false }
        if model.attachmentCount(for: task) > 0 { return false }
        if !shownCustomFields.isEmpty { return false }
        if let subtasks = model.subtaskProgress(for: task), subtasks.total > 0 { return false }
        if fields.contains(.daysInColumn) { return false }
        if fields.contains(.dueDate), task.dueDate != nil { return false }
        if fields.contains(.points), task.estimate != nil { return false }
        if fields.contains(.version), task.versionID != nil { return false }
        if fields.contains(.epic), task.epicID != nil { return false }
        if fields.contains(.checklist), let checklist = model.checklistProgress(for: task),
           checklist.total > 0 { return false }
        return true
    }

    private var accessibilityLabel: String {
        var parts = ["\(tag). \(task.title)"]
        if task.flagged {
            parts.append(task.flagReason.isEmpty ? "Flagged" : "Flagged: \(task.flagReason)")
        }
        if isPicked { parts.append("Selected") }
        return parts.joined(separator: ". ")
    }

    private var isOverdue: Bool {
        guard let due = task.dueDate, task.completedAt == nil else { return false }
        return due < Date()
    }

    private static let points: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    // The board, the list and the calendar draw these the same way, so the
    // answer lives in one place rather than in each view.
    private var typeSymbol: String { CardAppearance.symbol(forType: task.type) }
    private var typeLabel: String { CardAppearance.label(forType: task.type) }
    private var typeColor: Color { CardAppearance.color(forType: task.type) }
    private var prioritySymbol: String { CardAppearance.symbol(forPriority: task.priority) }
    private var priorityLabel: String { CardAppearance.label(forPriority: task.priority) }
    private var priorityColor: Color { CardAppearance.color(forPriority: task.priority) }
}
