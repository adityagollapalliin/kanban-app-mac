import Foundation

/// One horizontal band of the board, and the cards that belong in it.
public struct BoardLane: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// An SF Symbol for the lane's heading, where the grouping has one.
    public let symbol: String?
    public let taskIDs: Set<String>
    /// Pinned lanes sit above the grouping, whatever the grouping is.
    public let isPinned: Bool

    public init(id: String, name: String, symbol: String? = nil, taskIDs: Set<String>, isPinned: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.taskIDs = taskIDs
        self.isPinned = isPinned
    }
}

/// Works out which lane each card goes in.
///
/// Pure, and deliberately so: this is the part of swimlanes that is easy to
/// get subtly wrong — a card in two lanes, or in none — and it is far cheaper
/// to prove right in a test than to notice on a board.
///
/// Two rules hold whatever the grouping:
///  * **First match wins.** A card matching two query lanes appears in the
///    upper one only. Without that, work would be double-counted by every lane
///    total on the board.
///  * **Nothing is lost.** Cards matching no lane fall into a final catch-all
///    rather than vanishing, because a board that silently hides work is worse
///    than one with an untidy last row.
public enum SwimlaneGrouping {

    /// What the non-query groupings need to turn an id into a heading.
    public struct Names: Sendable {
        public var epics: [String: String]
        public var people: [String: String]
        public var parents: [String: String]

        public init(
            epics: [String: String] = [:],
            people: [String: String] = [:],
            parents: [String: String] = [:]
        ) {
            self.epics = epics
            self.people = people
            self.parents = parents
        }
    }

    /// `queryMatches` maps a swimlane's id to the cards its query selected;
    /// evaluating the query is the store's job, and assembling the lanes is
    /// this one's.
    public static func lanes(
        for tasks: [BoardTask],
        mode: SwimlaneMode,
        swimlanes: [Swimlane],
        queryMatches: [String: Set<String>],
        names: Names
    ) -> [BoardLane] {
        var remaining = tasks
        var lanes: [BoardLane] = []

        // Pinned lanes are matched before anything else, which is what keeps
        // Expedite at the top under every grouping rather than only under one.
        for lane in swimlanes where lane.pinned {
            let matched = remaining.filter { queryMatches[lane.id]?.contains($0.id) == true }
            guard !matched.isEmpty else { continue }
            lanes.append(BoardLane(
                id: lane.id,
                name: lane.name,
                symbol: "bolt.fill",
                taskIDs: Set(matched.map(\.id)),
                isPinned: true
            ))
            remaining.removeAll { matched.contains($0) }
        }

        switch mode {
        case .none:
            // No grouping at all still leaves the pinned lanes meaningful: the
            // board is Expedite on top and everything else beneath it.
            if !remaining.isEmpty {
                lanes.append(BoardLane(
                    id: "all",
                    name: lanes.isEmpty ? "" : "Everything Else",
                    taskIDs: Set(remaining.map(\.id))
                ))
            }

        case .query:
            for lane in swimlanes where !lane.pinned {
                let matched = remaining.filter { queryMatches[lane.id]?.contains($0.id) == true }
                guard !matched.isEmpty else { continue }
                lanes.append(BoardLane(
                    id: lane.id,
                    name: lane.name,
                    symbol: "line.3.horizontal.decrease.circle",
                    taskIDs: Set(matched.map(\.id))
                ))
                remaining.removeAll { matched.contains($0) }
            }
            if !remaining.isEmpty {
                lanes.append(BoardLane(id: "other", name: "Everything Else", taskIDs: Set(remaining.map(\.id))))
            }

        case .epic:
            lanes += grouped(remaining, symbol: "flag.fill", unassignedName: "No Epic") { task in
                task.epicID.map { ($0, names.epics[$0] ?? "Unknown Epic") }
            }

        case .assignee:
            lanes += grouped(remaining, symbol: "person.fill", unassignedName: "Unassigned") { task in
                task.assigneeID.map { ($0, names.people[$0] ?? "Unknown") }
            }

        case .parent:
            lanes += grouped(remaining, symbol: "list.bullet.indent", unassignedName: "Top Level") { task in
                task.parentID.map { ($0, names.parents[$0] ?? "Unknown Parent") }
            }

        case .priority:
            // Ordered by the domain, highest first — the one grouping where
            // alphabetical order would be actively misleading.
            for priority in Priority.allCases.sorted(by: >) {
                let matched = remaining.filter { $0.priority == priority }
                guard !matched.isEmpty else { continue }
                lanes.append(BoardLane(
                    id: "priority-\(priority.rawValue)",
                    name: label(for: priority),
                    symbol: "chevron.up.chevron.down",
                    taskIDs: Set(matched.map(\.id))
                ))
            }
        }

        return lanes
    }

    /// Groups by a key each card either has or does not, putting the cards
    /// without one in a final lane rather than dropping them.
    private static func grouped(
        _ tasks: [BoardTask],
        symbol: String,
        unassignedName: String,
        key: (BoardTask) -> (id: String, name: String)?
    ) -> [BoardLane] {
        var order: [String] = []
        var names: [String: String] = [:]
        var members: [String: Set<String>] = [:]
        var unassigned: Set<String> = []

        for task in tasks {
            guard let key = key(task) else {
                unassigned.insert(task.id)
                continue
            }
            if members[key.id] == nil {
                order.append(key.id)
                names[key.id] = key.name
            }
            members[key.id, default: []].insert(task.id)
        }

        var lanes = order.map { id in
            BoardLane(id: id, name: names[id] ?? "", symbol: symbol, taskIDs: members[id] ?? [])
        }
        // Sorted by name so the lanes do not reshuffle when a card moves.
        lanes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if !unassigned.isEmpty {
            lanes.append(BoardLane(id: "none", name: unassignedName, taskIDs: unassigned))
        }
        return lanes
    }

    private static func label(for priority: Priority) -> String {
        switch priority {
        case .lowest: "Lowest"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .highest: "Highest"
        }
    }
}
