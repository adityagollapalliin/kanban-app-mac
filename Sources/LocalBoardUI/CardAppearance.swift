import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// What colour a card is drawn in, and why.
///
/// Kept apart from the card view because it is the one piece of the card that
/// is a *decision* rather than a layout: five rules, each answering "what does
/// this stripe mean" differently, and the answer has to be consistent
/// everywhere a card appears — on the board, in the backlog, in a lane.
@MainActor
enum CardAppearance {

    /// `nil` means no stripe: the rule is off, or this card is not one the
    /// rule has anything to say about.
    static func stripe(for task: BoardTask, model: BoardViewModel) -> Color? {
        guard let board = model.snapshot?.board else { return nil }

        switch board.colorRule {
        case .none:
            return nil

        case .priority:
            // Only the priorities that are worth a colour. Painting every card
            // means the stripe stops being a signal and becomes decoration.
            switch task.priority {
            case .highest: return .red
            case .high: return .orange
            case .low, .lowest: return Color(nsColor: .systemGray)
            case .normal: return nil
            }

        case .type:
            switch task.type {
            case .epic: return .purple
            case .story: return .green
            case .bug: return .red
            case .task: return nil
            }

        case .assignee:
            guard let person = model.person(id: task.assigneeID) else { return nil }
            return PaletteColor.named(person.color).color

        case .query:
            return model.colorQueryMatches.contains(task.id) ? .accentColor : nil
        }
    }

    /// Someone's initials, for the avatar. At most two, because three is no
    /// longer something you recognise at a glance.
    static func initials(of name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// A person's initials in a circle.
struct AssigneeAvatar: View {
    let person: Person
    var size: CGFloat = 20

    var body: some View {
        Text(CardAppearance.initials(of: person.name))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(PaletteColor.named(person.color).color, in: Circle())
            .help(person.name)
            .accessibilityLabel("Assigned to \(person.name)")
    }
}

/// How long a card has been where it is, as dots.
///
/// Dots rather than a number because the question is never "how many days
/// exactly", it is "has this been sitting here". Five is the most that can be
/// counted without counting; past that it says so in words.
struct DaysInColumnDots: View {
    let days: Int
    let threshold: Int

    private var isStale: Bool { days >= threshold }

    var body: some View {
        HStack(spacing: 2) {
            if days > 5 {
                Text("\(days)d")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(isStale ? Color.orange : .secondary)
            } else {
                ForEach(0..<max(days, 0), id: \.self) { _ in
                    Circle()
                        .fill(isStale ? Color.orange : Color.secondary.opacity(0.5))
                        .frame(width: 4, height: 4)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(days == 1 ? "One day in this column" : "\(days) days in this column")
        .help(isStale
              ? "Here \(days) days — past this board's \(threshold)-day threshold"
              : "Here \(days) day\(days == 1 ? "" : "s")")
    }
}

// MARK: - What a type and a priority look like

/// The card, the list and the calendar all draw a type icon and a priority
/// arrow, and they have to be the same icon and the same arrow. One answer,
/// here, rather than three that agree until somebody edits one of them.
extension CardAppearance {

    static func symbol(forType type: TaskType) -> String {
        switch type {
        case .epic: "flag.fill"
        case .story: "book.closed.fill"
        case .task: "checkmark.square"
        case .bug: "ladybug.fill"
        }
    }

    static func label(forType type: TaskType) -> String {
        switch type {
        case .epic: "Epic"
        case .story: "Story"
        case .task: "Task"
        case .bug: "Bug"
        }
    }

    static func color(forType type: TaskType) -> Color {
        switch type {
        case .epic: .purple
        case .story: .green
        case .task: .secondary
        case .bug: .red
        }
    }

    /// Priority reads as a direction, so the arrow carries it and the colour
    /// only reinforces it — the board stays legible without colour.
    static func symbol(forPriority priority: Priority) -> String {
        switch priority {
        case .lowest: "chevron.down.2"
        case .low: "chevron.down"
        case .normal: "minus"
        case .high: "chevron.up"
        case .highest: "chevron.up.2"
        }
    }

    static func label(forPriority priority: Priority) -> String {
        switch priority {
        case .lowest: "Lowest"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .highest: "Highest"
        }
    }

    static func color(forPriority priority: Priority) -> Color {
        switch priority {
        case .lowest, .low, .normal: .secondary
        case .high: .orange
        case .highest: .red
        }
    }
}
