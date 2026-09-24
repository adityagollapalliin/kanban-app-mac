import AppKit
import SwiftUI

/// Where every card is, so a rectangle dragged over the board can say which
/// ones it covers.
///
/// A preference rather than a lookup: the cards know where they are and the
/// board does not, and this is the direction SwiftUI lets that information
/// travel. The frames are reported in a named coordinate space shared with the
/// board, so they stay correct as it scrolls.
struct CardFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this card's frame for the lasso.
    func reportingFrame(id: String, in space: CoordinateSpace) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(key: CardFrames.self, value: [id: geometry.frame(in: space)])
            }
        )
    }
}

/// The rectangle being dragged, and what it covers.
///
/// Held as a value rather than in the view model: a lasso in progress is not
/// state the rest of the app has any business seeing, and it ends either as a
/// selection or as nothing at all.
struct Lasso: Equatable {
    var start: CGPoint
    var current: CGPoint

    var rect: CGRect {
        CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    /// A stray click is not a lasso. Below this the drag is treated as a click
    /// on the background, which deselects — the thing people actually mean by
    /// clicking empty space.
    var isMeaningful: Bool { rect.width > 4 || rect.height > 4 }

    func covers(_ frame: CGRect) -> Bool { rect.intersects(frame) }
}

/// The band drawn while dragging.
struct LassoOverlay: View {
    let lasso: Lasso

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.12))
            .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
            .frame(width: lasso.rect.width, height: lasso.rect.height)
            .position(x: lasso.rect.midX, y: lasso.rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
