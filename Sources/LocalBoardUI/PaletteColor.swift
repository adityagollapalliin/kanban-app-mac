import SwiftUI

/// The colours labels and people can be given.
///
/// Stored as names rather than hex, so the same label reads correctly in light
/// and dark and follows the system's own palette rather than freezing a colour
/// that was chosen against one background.
enum PaletteColor: String, CaseIterable, Identifiable {
    case slate, graphite, red, orange, yellow, green, teal, blue, indigo, purple, pink, brown

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .slate: Color(nsColor: .systemGray)
        case .graphite: Color(nsColor: .darkGray)
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        }
    }

    var displayName: String { rawValue.capitalized }

    /// Unknown names keep working rather than disappearing: a colour written
    /// by a newer build, or by hand in the CLI, still draws as something.
    static func named(_ name: String) -> PaletteColor {
        PaletteColor(rawValue: name.lowercased()) ?? .slate
    }
}
