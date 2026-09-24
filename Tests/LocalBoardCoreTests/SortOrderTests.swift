import Foundation
import Testing
@testable import LocalBoardCore

@Suite("Sort order")
struct SortOrderTests {

    @Test("An empty list starts at the step")
    func firstItem() {
        #expect(SortOrder.between(nil, nil) == SortOrder.step)
    }

    @Test("Dropping at the ends leaves room on the outside")
    func ends() {
        #expect(SortOrder.between(2_000, nil) == 3_000)
        #expect(SortOrder.between(nil, 2_000) == 1_000)
    }

    @Test("Dropping between two neighbours takes the midpoint")
    func midpoint() {
        #expect(SortOrder.between(1_000, 2_000) == 1_500)
        #expect(SortOrder.between(1_000, 1_001) == 1_000.5)
    }

    /// The whole point of sparse ordering: one write, and the neighbours are
    /// left alone.
    @Test("A midpoint always lands strictly between its neighbours")
    func strictlyBetween() {
        let lower = 1_000.0
        let upper = 1_000.000_1
        let middle = SortOrder.between(lower, upper)
        #expect(middle > lower)
        #expect(middle < upper)
    }

    @Test("Room at the ends is never reported as exhausted")
    func endsNeverNeedRebalancing() {
        #expect(SortOrder.needsRebalance(nil, nil) == false)
        #expect(SortOrder.needsRebalance(1_000, nil) == false)
        #expect(SortOrder.needsRebalance(nil, 1_000) == false)
    }

    @Test("A gap too small to split is reported before it is split")
    func exhaustedGap() {
        #expect(SortOrder.needsRebalance(1_000, 2_000) == false)
        #expect(SortOrder.needsRebalance(1_000, 1_000 + SortOrder.minimumGap / 2) == true)
    }

    /// Repeatedly inserting into the same gap is the case sparse ordering is
    /// worst at. This walks it to the floor and checks the alarm comes before
    /// the positions actually collide, not after.
    @Test("Halving the same gap raises the alarm while order is still intact")
    func repeatedInsertsIntoOneGap() {
        var lower = 1_000.0
        let upper = 2_000.0
        var inserts = 0

        while !SortOrder.needsRebalance(lower, upper) {
            let middle = SortOrder.between(lower, upper)
            #expect(middle > lower, "position collided with its lower neighbour")
            #expect(middle < upper, "position collided with its upper neighbour")
            lower = middle
            inserts += 1
            if inserts > 200 { break }
        }

        #expect(inserts < 200, "the gap never reported exhaustion")
        #expect(SortOrder.needsRebalance(lower, upper))
    }

    @Test("Rebalancing spreads positions evenly and keeps them ascending")
    func rebalancing() {
        #expect(SortOrder.rebalanced(count: 0).isEmpty)
        #expect(SortOrder.rebalanced(count: 3) == [1_000, 2_000, 3_000])

        let positions = SortOrder.rebalanced(count: 50)
        #expect(positions.count == 50)
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })
    }
}
