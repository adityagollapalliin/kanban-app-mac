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
