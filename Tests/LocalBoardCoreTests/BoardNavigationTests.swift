import Testing
@testable import LocalBoardCore

/// Where the arrow keys go. A rule rather than a drawing, so it can be tested
/// without a window — which is the reason it lives in the core at all.
@Suite("Moving around a board by keyboard")
struct BoardNavigationTests {

    private let grid = BoardGrid(columns: [
        ["a1", "a2", "a3"],
        ["b1"],
        [],
        ["d1", "d2"],
    ])

    @Test("Up and down stay in the column")
    func verticalStaysPut() {
        #expect(grid.neighbour(of: "a1", going: .down) == "a2")
        #expect(grid.neighbour(of: "a2", going: .up) == "a1")
    }

    /// Wrapping from the bottom of one column to the top of the next would
    /// make the down arrow a way of leaving the column you are reading.
    @Test("The ends of a column are ends")
    func verticalDoesNotWrap() {
        #expect(grid.neighbour(of: "a1", going: .up) == nil)
        #expect(grid.neighbour(of: "a3", going: .down) == nil)
    }

    /// The rule that makes the arrows usable: moving sideways keeps your place
    /// in the column rather than jumping to the top of every one.
    @Test("Sideways keeps your place in the column")
    func horizontalKeepsRow() {
        #expect(grid.neighbour(of: "d1", going: .left) == "b1")
        #expect(grid.neighbour(of: "a2", going: .right) == "b1")
        #expect(grid.neighbour(of: "a2", going: .right).map { grid.position(of: $0)?.column } == 1)
    }

    /// A shorter column cannot hold the row you came from, so you land on its
    /// last card rather than nowhere.
    @Test("A shorter column catches you at its end")
    func clampsToShorterColumn() {
        #expect(grid.neighbour(of: "a3", going: .right) == "b1")
    }

    /// There is nothing to focus in an empty column, and stopping there would
    /// strand the focus with nowhere to come back from.
    @Test("Empty columns are stepped over, not stopped at")
    func skipsEmptyColumns() {
        #expect(grid.neighbour(of: "b1", going: .right) == "d1")
        #expect(grid.neighbour(of: "d1", going: .left) == "b1")
    }

    @Test("The board ends where it ends")
    func edgesReturnNothing() {
        #expect(grid.neighbour(of: "a1", going: .left) == nil)
        #expect(grid.neighbour(of: "d2", going: .right) == nil)
    }

    /// A card trashed or filtered away between one keypress and the next must
    /// not swallow the press: focus goes back to the first card instead.
    @Test("A card that is no longer there hands focus back to the first")
    func unknownCardRecovers() {
        #expect(grid.neighbour(of: "gone", going: .down) == "a1")
        #expect(grid.contains("gone") == false)
    }

    /// An empty board has nowhere to be, and saying so beats inventing a card.
    @Test("An empty board has no first card")
    func emptyBoard() {
        let empty = BoardGrid(columns: [[], []])
        #expect(empty.firstCard == nil)
        #expect(empty.neighbour(of: "anything", going: .right) == nil)
    }

    /// A board whose first column is empty still starts somewhere.
    @Test("Focus starts at the first card there is")
    func firstCardSkipsEmptyColumns() {
        #expect(BoardGrid(columns: [[], ["x"]]).firstCard == "x")
    }

    /// Moving a *card* is not the same question as moving the focus: a card
    /// can be put into an empty column even though focus cannot stop in one.
    @Test("A card can be moved into a column focus would step over")
    func cardMovesIntoEmptyColumn() {
        #expect(grid.adjacentColumn(of: "b1", step: 1) == 2)
        #expect(grid.adjacentColumn(of: "a1", step: -1) == nil)
        #expect(grid.adjacentColumn(of: "d2", step: 1) == nil)
    }
}
