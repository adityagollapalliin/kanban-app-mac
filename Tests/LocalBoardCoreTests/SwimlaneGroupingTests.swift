import Foundation
import Testing
@testable import LocalBoardCore

@Suite("Swimlane grouping")
struct SwimlaneGroupingTests {

    private func task(
        _ id: String,
        epic: String? = nil,
        assignee: String? = nil,
        parent: String? = nil,
        priority: Priority = .normal
    ) -> BoardTask {
        BoardTask(
            id: id, projectID: "p", statusID: "s", number: 1, title: id,
            assigneeID: assignee, priority: priority, parentID: parent, epicID: epic,
            sortOrder: 0, createdAt: .now, updatedAt: .now
        )
    }

    private let expedite = Swimlane(
        id: "expedite", boardID: "b", name: "Expedite", query: "priority >= highest",
        pinned: true, sortOrder: 100
    )

    @Test("No grouping is one lane holding everything")
    func noGrouping() {
        let lanes = SwimlaneGrouping.lanes(
            for: [task("a"), task("b")],
            mode: .none, swimlanes: [], queryMatches: [:], names: .init()
        )
        #expect(lanes.count == 1)
        #expect(lanes[0].taskIDs == ["a", "b"])
    }

    @Test("A pinned lane sits above the grouping, whatever the grouping is")
    func pinnedLaneComesFirst() {
        for mode in [SwimlaneMode.none, .epic, .assignee, .priority] {
            let lanes = SwimlaneGrouping.lanes(
                for: [task("urgent", priority: .highest), task("ordinary")],
                mode: mode,
                swimlanes: [expedite],
                queryMatches: ["expedite": ["urgent"]],
                names: .init()
            )
            #expect(lanes.first?.isPinned == true, "in \(mode)")
            #expect(lanes.first?.taskIDs == ["urgent"], "in \(mode)")
            // And the card it claimed does not also appear below it.
            #expect(lanes.dropFirst().allSatisfy { !$0.taskIDs.contains("urgent") }, "in \(mode)")
        }
    }

    /// Without this rule every lane total on the board would double-count.
    @Test("A card matching two query lanes appears only in the upper one")
    func firstMatchWins() {
        let first = Swimlane(id: "one", boardID: "b", name: "One", query: "is:open", sortOrder: 1)
        let second = Swimlane(id: "two", boardID: "b", name: "Two", query: "is:open", sortOrder: 2)

        let lanes = SwimlaneGrouping.lanes(
            for: [task("a")],
            mode: .query,
            swimlanes: [first, second],
            queryMatches: ["one": ["a"], "two": ["a"]],
            names: .init()
        )

        #expect(lanes.count == 1)
        #expect(lanes[0].id == "one")
    }

    @Test("Cards matching no lane fall into a catch-all rather than vanishing")
    func nothingIsLost() {
        let lane = Swimlane(id: "one", boardID: "b", name: "One", query: "is:done", sortOrder: 1)

        let lanes = SwimlaneGrouping.lanes(
            for: [task("matched"), task("unmatched")],
            mode: .query,
            swimlanes: [lane],
            queryMatches: ["one": ["matched"]],
            names: .init()
        )

        let everything = lanes.flatMap(\.taskIDs)
        #expect(Set(everything) == ["matched", "unmatched"])
        #expect(lanes.last?.name == "Everything Else")
    }

    @Test("Grouping by epic names the lanes and collects the rest")
    func byEpic() {
        let lanes = SwimlaneGrouping.lanes(
            for: [task("a", epic: "e1"), task("b", epic: "e1"), task("c")],
            mode: .epic,
            swimlanes: [],
            queryMatches: [:],
            names: .init(epics: ["e1": "Checkout rewrite"])
        )

        #expect(lanes.count == 2)
        #expect(lanes[0].name == "Checkout rewrite")
        #expect(lanes[0].taskIDs == ["a", "b"])
        #expect(lanes[1].name == "No Epic")
        #expect(lanes[1].taskIDs == ["c"])
    }

    @Test("Grouping by assignee puts the unassigned last")
    func byAssignee() {
        let lanes = SwimlaneGrouping.lanes(
            for: [task("a", assignee: "p2"), task("b", assignee: "p1"), task("c")],
            mode: .assignee,
            swimlanes: [],
            queryMatches: [:],
            names: .init(people: ["p1": "Ada", "p2": "Grace"])
        )

        #expect(lanes.map(\.name) == ["Ada", "Grace", "Unassigned"])
    }

    /// The one grouping where alphabetical order would be actively misleading.
    @Test("Priority lanes run highest first, not alphabetically")
    func byPriority() {
        let lanes = SwimlaneGrouping.lanes(
            for: [task("a", priority: .low), task("b", priority: .highest), task("c", priority: .normal)],
            mode: .priority,
            swimlanes: [],
            queryMatches: [:],
            names: .init()
        )

        #expect(lanes.map(\.name) == ["Highest", "Normal", "Low"])
    }

    @Test("An empty lane is not drawn")
    func emptyLanesAreDropped() {
        let lanes = SwimlaneGrouping.lanes(
            for: [task("a")],
            mode: .priority, swimlanes: [expedite], queryMatches: ["expedite": []], names: .init()
        )
        #expect(lanes.count == 1)
        #expect(lanes[0].name == "Normal")
    }
}
