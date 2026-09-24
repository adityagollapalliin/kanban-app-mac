import Foundation

/// Placement within an ordered list.
///
/// Rows carry a sparse `REAL` position rather than a contiguous index, so
/// dropping a card between two others writes one row instead of renumbering
/// everything below it. The cost is that repeated inserts into the same gap
/// halve it each time, and a `Double` runs out of mantissa after about fifty
/// of them — hence `needsRebalance`, and `rebalanced` to spread a column out
/// again when it says so.
public enum SortOrder {

    /// Distance between freshly seeded neighbours. Large enough that the first
    /// several thousand drags never come near the precision floor.
    public static let step: Double = 1_000

    /// Below this, midpoints stop being reliably distinct and the column needs
    /// spreading out. Two adjacent doubles near 1000 differ by ~1e-13, so this
    /// leaves several orders of magnitude of headroom.
    public static let minimumGap: Double = 0.000_001

    /// The position for a row dropped between two neighbours. A `nil` neighbour
    /// means the end of the list.
    public static func between(_ lower: Double?, _ upper: Double?) -> Double {
        switch (lower, upper) {
        case (nil, nil):
            return step
        case (nil, .some(let upper)):
            return upper - step
        case (.some(let lower), nil):
            return lower + step
        case (.some(let lower), .some(let upper)):
            return lower + (upper - lower) / 2
        }
    }

    /// Whether the gap these two neighbours leave is too small to split again.
    /// Checked before the write, so a rebalance happens while the order is
    /// still correct rather than after positions have collided.
    public static func needsRebalance(_ lower: Double?, _ upper: Double?) -> Bool {
        guard let lower, let upper else { return false }
        return abs(upper - lower) < minimumGap
    }

    /// Evenly spaced positions for a column being spread out again.
    public static func rebalanced(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return (1...count).map { Double($0) * step }
    }
}
