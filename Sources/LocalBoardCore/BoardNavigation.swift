import Foundation

/// Which way an arrow key is asking to go.
public enum BoardDirection: Sendable, Equatable {
    case left, right, up, down
}

/// Where the keyboard goes next on a board.
///
/// Kept here, over plain arrays of ids, rather than in the view: "what is to
/// the right of this card" is a rule, not a drawing, and a rule can be tested
/// without a window.
///
/// Two decisions the arrows depend on:
///
///   * **Sideways keeps your place in the column.** Moving right from the
///     third card lands on the third card across, or the last one if that
///     column is shorter. Landing on the top of every column would make the
///     arrow keys a way of losing your place.
///   * **Empty columns are stepped over, not stopped at.** There is nothing to
///     focus in an empty column, so stopping there would strand the focus and
///     leave the next press with nowhere to come back from.
public struct BoardGrid: Sendable, Equatable {

    /// Cards by column, in the order they are drawn.
    public let columns: [[String]]

    public init(columns: [[String]]) {
        self.columns = columns
    }

    /// The first card on the board, which is where focus starts.
    public var firstCard: String? {
        columns.first { !$0.isEmpty }?.first
    }

    public func contains(_ id: String) -> Bool {
        position(of: id) != nil
    }

    public func position(of id: String) -> (column: Int, row: Int)? {
        for (column, cards) in columns.enumerated() {
            if let row = cards.firstIndex(of: id) { return (column, row) }
        }
        return nil
    }

    public func card(column: Int, row: Int) -> String? {
        guard columns.indices.contains(column), columns[column].indices.contains(row) else { return nil }
        return columns[column][row]
    }

    /// The card an arrow key moves to, or `nil` when the board ends there.
    ///
    /// A card that is no longer on the board — trashed, or filtered away
    /// between one keypress and the next — hands focus back to the first card
    /// rather than swallowing the press.
    public func neighbour(of id: String, going direction: BoardDirection) -> String? {
        guard let here = position(of: id) else { return firstCard }

        switch direction {
        case .up:
            return card(column: here.column, row: here.row - 1)
        case .down:
            return card(column: here.column, row: here.row + 1)
        case .left:
            return sideways(from: here, step: -1)
        case .right:
            return sideways(from: here, step: +1)
        }
    }

    private func sideways(from here: (column: Int, row: Int), step: Int) -> String? {
        var column = here.column + step
        while columns.indices.contains(column) {
            let cards = columns[column]
            if let last = cards.indices.last {
                return cards[min(here.row, last)]
            }
            column += step
        }
        return nil
    }

    /// The column a card would land in after moving sideways — which is not
    /// the same question as where focus goes, because a card can be moved into
    /// an empty column even though focus cannot stop in one.
    public func adjacentColumn(of id: String, step: Int) -> Int? {
        guard let here = position(of: id) else { return nil }
        let column = here.column + step
        return columns.indices.contains(column) ? column : nil
    }
}
