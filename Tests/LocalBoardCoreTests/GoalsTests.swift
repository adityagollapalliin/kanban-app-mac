import Foundation
import Testing
@testable import LocalBoardCore

private func goal(
    start: Double = 0,
    target: Double = 10,
    current: Double = 0,
    kind: GoalKind = .number,
    dueAt: Date? = nil
) -> Goal {
    Goal(
        id: "g", projectID: "p", name: "A goal", kind: kind,
        start: start, target: target, current: current, dueAt: dueAt,
        sortOrder: 1_000, createdAt: Date(), updatedAt: Date()
    )
}

@Suite("How far along a goal is")
struct GoalProgressTests {

    @Test("Progress runs from the starting figure, not from zero")
    func fromStart() {
        // Cutting open bugs from 40 to 10 is at no progress at 40, and half
        // way at 25. Measuring from zero would call 40 four hundred per cent.
        let cutting = goal(start: 40, target: 10, current: 40)
        #expect(cutting.fraction == 0)

        var halfway = cutting
        halfway.current = 25
        #expect(halfway.fraction == 0.5)

        var done = cutting
        done.current = 10
        #expect(done.fraction == 1)
    }

    @Test("A goal that counts upwards behaves the same way round")
    func upwards() {
        #expect(goal(start: 0, target: 10, current: 0).fraction == 0)
        #expect(goal(start: 0, target: 10, current: 5).fraction == 0.5)
        #expect(goal(start: 0, target: 10, current: 10).fraction == 1)
    }

    @Test("The bar never runs past either end")
    func clamped() {
        // A bar past its own end says less than a full one; a negative bar is
        // not a thing that can be drawn at all.
        #expect(goal(start: 0, target: 10, current: 25).fraction == 1)
        #expect(goal(start: 0, target: 10, current: -5).fraction == 0)
        #expect(goal(start: 40, target: 10, current: 60).fraction == 0)
    }

    @Test("A target equal to the start is met the moment it is reached")
    func noDistance() {
        // No span to divide by, so the arithmetic has to be told what to say.
        #expect(goal(start: 5, target: 5, current: 5).fraction == 1)
        #expect(goal(start: 5, target: 5, current: 4).fraction == 0)
    }

    @Test("A goal counting down is met at or below its target")
    func metEitherDirection() {
        #expect(goal(start: 40, target: 10, current: 10).isMet)
        #expect(goal(start: 40, target: 10, current: 5).isMet)
        #expect(!goal(start: 40, target: 10, current: 11).isMet)

        #expect(goal(start: 0, target: 10, current: 10).isMet)
        #expect(!goal(start: 0, target: 10, current: 9).isMet)
    }

    @Test("Days remaining is counted on whole days, and goes negative when late")
    func daysRemaining() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 23))!
        let due = calendar.date(from: DateComponents(year: 2026, month: 6, day: 18, hour: 1))!

        // Late in the evening against early morning three days later is still
        // three days, not two and a bit rounded down.
        let soon = goal(dueAt: due)
        #expect(soon.daysRemaining(from: now, calendar: calendar) == 3)
        #expect(!soon.isOverdue(now: now, calendar: calendar))

        let past = goal(dueAt: calendar.date(from: DateComponents(year: 2026, month: 6, day: 10))!)
        #expect(past.daysRemaining(from: now, calendar: calendar) == -5)
        #expect(past.isOverdue(now: now, calendar: calendar))
    }

    @Test("A goal that is already met is not overdue, however late the date")
    func metIsNotOverdue() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        let past = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!

        var met = goal(start: 0, target: 10, current: 10, dueAt: past)
        #expect(!met.isOverdue(now: now, calendar: calendar))
        met.current = 3
        #expect(met.isOverdue(now: now, calendar: calendar))
    }

    @Test("How it reads beside the bar")
    func wording() {
        #expect(goal(start: 0, target: 10, current: 4).progressDescription == "4 of 10")
        #expect(goal(start: 0, target: 10, current: 4).percentDescription == "40%")

        var money = goal(start: 0, target: 5_000, current: 1_250, kind: .currency)
        money.currency = "GBP"
        #expect(money.progressDescription == "GBP 1250 of GBP 5000")

        let flag = goal(start: 0, target: 1, current: 1, kind: .boolean)
        #expect(flag.progressDescription == "Done")

        // "22 of 10" reads as a count that has overshot, which is the opposite
        // of what a goal to bring a number down is saying.
        let cutting = goal(start: 40, target: 10, current: 22)
        #expect(cutting.descending)
        #expect(cutting.progressDescription == "22, down to 10")
    }
}

@Suite("Rolling values up")
struct RollupTests {

    @Test("Sum, average, minimum and maximum over the values that are there")
    func reductions() {
        let values: [Double?] = [2, 4, 6]
        #expect(RollupFunction.sum.reduce(values) == 12)
        #expect(RollupFunction.average.reduce(values) == 4)
        #expect(RollupFunction.minimum.reduce(values) == 2)
        #expect(RollupFunction.maximum.reduce(values) == 6)
    }

    @Test("An average divides by the cards that answered, not by all of them")
    func averageIgnoresBlanks() {
        // Averaging a blank in as zero drags the figure down with data nobody
        // entered, which is the quiet way a rollup starts lying.
        #expect(RollupFunction.average.reduce([4, nil, 8]) == 6)
        #expect(RollupFunction.sum.reduce([4, nil, 8]) == 12)
    }

    @Test("A count counts the cards, including the ones that left it blank")
    func countCountsRows() {
        #expect(RollupFunction.count.reduce([4, nil, 8]) == 3)
        #expect(RollupFunction.count.reduce([nil, nil]) == 2)
    }

    @Test("Nothing related at all is blank, except for a count")
    func nothingRelated() {
        // A card with nothing rolled up has no total, and zero is a figure
        // somebody might act on.
        #expect(RollupFunction.sum.reduce([]) == nil)
        #expect(RollupFunction.average.reduce([]) == nil)
        #expect(RollupFunction.minimum.reduce([]) == nil)
        #expect(RollupFunction.count.reduce([]) == 0)
    }

    @Test("Related cards that all left the field blank sum to nothing, not zero")
    func allBlank() {
        #expect(RollupFunction.sum.reduce([nil, nil]) == nil)
        #expect(RollupFunction.count.reduce([nil, nil]) == 2)
    }

    @Test("A progress percentage needs something to count")
    func progressPercentage() {
        #expect(ProgressMode.percentage(done: 1, of: 4) == 25)
        #expect(ProgressMode.percentage(done: 4, of: 4) == 100)
        #expect(ProgressMode.percentage(done: 0, of: 4) == 0)
        // A card with no subtasks has not finished its subtasks; it has none.
        #expect(ProgressMode.percentage(done: 0, of: 0) == nil)
    }
}

@Suite("Where the widgets sit")
struct DashboardLayoutTests {

    private func widget(_ id: String, width: Int = 1, height: Int = 1) -> DashboardWidget {
        DashboardWidget(
            id: id, dashboardID: "d", kind: .taskCount,
            width: width, height: height, createdAt: Date()
        )
    }

    @Test("Widgets flow across the row, then on to the next")
    func flows() {
        let packed = DashboardLayout.pack(
            [widget("a"), widget("b"), widget("c")], columns: 2
        )
        #expect(packed.map { [$0.column, $0.row] } == [[0, 0], [1, 0], [0, 1]])
    }

    @Test("A wide widget takes the cells it needs and pushes the rest along")
    func spans() {
        let packed = DashboardLayout.pack(
            [widget("wide", width: 2), widget("a"), widget("b")], columns: 2
        )
        #expect(packed[0].column == 0 && packed[0].row == 0)
        #expect(packed[1].row == 1)
        #expect(packed[2].row == 1)
    }

    @Test("A tall widget is drawn taller, and still sits on one row")
    func tallWidgets() {
        // Height is how tall the box is, not how many rows it straddles:
        // neither of SwiftUI's grids can draw a cell across two rows, so a
        // layout that claimed one would come back wrong.
        let packed = DashboardLayout.pack(
            [widget("tall", height: 2), widget("a"), widget("b")], columns: 2
        )
        #expect(packed[0].column == 0 && packed[0].row == 0)
        #expect(packed[1].column == 1 && packed[1].row == 0)
        #expect(packed[2].column == 0 && packed[2].row == 1)
        #expect(packed[0].height == 2)
    }

    @Test("The rows are handed over in reading order, ready to draw")
    func rows() {
        // `c` lands beside `a` rather than under `wide`, because the packer
        // fills the gap the wide one could not fit into.
        let rows = DashboardLayout.rows(
            [widget("a"), widget("wide", width: 2), widget("c")], columns: 2
        )
        #expect(rows.map { $0.map(\.id) } == [["a", "c"], ["wide"]])
    }

    @Test("A widget wider than the grid is narrowed rather than dropped")
    func tooWide() {
        // Reopening a four-column dashboard in a narrow window should still
        // show every widget the person made.
        let packed = DashboardLayout.pack([widget("wide", width: 4)], columns: 2)
        #expect(packed[0].width == 2)
        #expect(packed[0].column == 0)
    }

    @Test("Nothing ever overlaps, whatever the sizes")
    func noOverlap() {
        let widgets = [
            widget("a", width: 2), widget("b"), widget("c", height: 2),
            widget("d", width: 3), widget("e"), widget("f", width: 2, height: 2),
        ]
        let packed = DashboardLayout.pack(widgets, columns: 3)

        var taken: Set<String> = []
        for widget in packed {
            for column in widget.column..<(widget.column + widget.width) {
                #expect(taken.insert("\(column),\(widget.row)").inserted,
                        "\(widget.id) overlaps at \(column),\(widget.row)")
            }
        }
        // And nothing hangs off the right-hand edge.
        #expect(packed.allSatisfy { $0.column + $0.width <= 3 })
    }

    @Test("A gap a later widget fits into is used rather than left empty")
    func fillsGaps() {
        // The wide one cannot start at column 1, so it goes to the next row —
        // and the single that follows belongs in the hole it left behind.
        let packed = DashboardLayout.pack(
            [widget("a"), widget("wide", width: 3), widget("filler")], columns: 3
        )
        #expect(packed[0].row == 0 && packed[0].column == 0)
        #expect(packed[1].row == 1)
        #expect(packed[2].row == 0 && packed[2].column == 1)
    }

    @Test("Dragging downwards accounts for the gap the widget leaves behind")
    func reorderDown() {
        let widgets = [widget("a"), widget("b"), widget("c")]
        // SwiftUI hands over an insertion point in the *original* list.
        #expect(DashboardLayout.reorder(widgets, from: 0, to: 2).map(\.id) == ["b", "a", "c"])
        #expect(DashboardLayout.reorder(widgets, from: 0, to: 3).map(\.id) == ["b", "c", "a"])
    }

    @Test("Dragging upwards puts it where it was dropped")
    func reorderUp() {
        let widgets = [widget("a"), widget("b"), widget("c")]
        #expect(DashboardLayout.reorder(widgets, from: 2, to: 0).map(\.id) == ["c", "a", "b"])
        #expect(DashboardLayout.reorder(widgets, from: 1, to: 0).map(\.id) == ["b", "a", "c"])
    }

    @Test("A drag that makes no sense leaves the order alone")
    func reorderOutOfRange() {
        let widgets = [widget("a"), widget("b")]
        #expect(DashboardLayout.reorder(widgets, from: 5, to: 0).map(\.id) == ["a", "b"])
        #expect(DashboardLayout.reorder(widgets, from: 0, to: -1).map(\.id) == ["a", "b"])
    }

    @Test("A widget's settings survive a trip through storage")
    func configRoundTrip() {
        var config = DashboardWidgetConfig()
        config.goalID = "g1"
        config.text = "Remember the milk"
        config.days = 14
        #expect(DashboardWidgetConfig.decoded(from: config.stored) == config)
    }

    @Test("Settings written by an older build read as the defaults")
    func configDefaults() {
        // Every property has a default, so a widget stored before a setting
        // existed still opens.
        let old = DashboardWidgetConfig.decoded(from: "{\"text\":\"note\"}")
        #expect(old.text == "note")
        #expect(old.days == 30)
        #expect(old.limit == 10)

        // And something that is not settings at all does not crash the grid.
        #expect(DashboardWidgetConfig.decoded(from: "not json") == DashboardWidgetConfig())
        #expect(DashboardWidgetConfig.decoded(from: "") == DashboardWidgetConfig())
    }
}
