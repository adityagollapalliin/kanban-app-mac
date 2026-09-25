import Foundation

/// Minutes, the way a timesheet shows them.
public enum DurationFormat {
    /// `90` reads as `1:30`, which is what a timesheet column is full of.
    public static func clock(_ minutes: Int) -> String {
        let sign = minutes < 0 ? "-" : ""
        let total = abs(minutes)
        return String(format: "%@%d:%02d", sign, total / 60, total % 60)
    }

    /// `90` reads as `1h 30m`, for a sentence rather than a column.
    public static func short(_ minutes: Int) -> String {
        let sign = minutes < 0 ? "-" : ""
        let total = abs(minutes)
        let hours = total / 60
        let remainder = total % 60
        if hours == 0 { return "\(sign)\(remainder)m" }
        return remainder == 0 ? "\(sign)\(hours)h" : "\(sign)\(hours)h \(remainder)m"
    }

    /// Reads what somebody typed into a timesheet cell.
    ///
    /// A timesheet is typed in a hurry, so all of `1:30`, `1.5`, `90m`, `1h30`
    /// and `1h 30m` mean ninety minutes. A bare number is hours when it has a
    /// decimal point and minutes when it does not — `0.5` is half an hour,
    /// `30` is thirty minutes — because that is how each is habitually typed.
    public static func minutes(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let hours = Int(parts[0].isEmpty ? "0" : String(parts[0])),
                  let minutes = Int(parts[1].isEmpty ? "0" : String(parts[1])) else { return nil }
            return hours * 60 + minutes
        }

        if trimmed.contains("h") {
            let parts = trimmed.split(separator: "h", maxSplits: 1, omittingEmptySubsequences: false)
            guard let hours = Double(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            var total = Int((hours * 60).rounded())
            if parts.count == 2 {
                let rest = parts[1].replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty {
                    guard let minutes = Int(rest) else { return nil }
                    total += minutes
                }
            }
            return total
        }

        if trimmed.hasSuffix("m") {
            return Int(trimmed.dropLast().trimmingCharacters(in: .whitespaces))
        }

        guard let value = Double(trimmed) else { return nil }
        return trimmed.contains(".") ? Int((value * 60).rounded()) : Int(value.rounded())
    }
}

/// The seven days a timesheet covers.
public struct TimesheetWeek: Sendable, Equatable {
    public let days: [Date]
    public let calendar: Calendar

    /// The week containing `date`, starting on whichever day the user's own
    /// calendar starts on — a Monday here, a Sunday there.
    public init(containing date: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
        days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    public var start: Date { days.first ?? Date() }

    /// The instant after the last day, so a half-open range covers the week.
    public var end: Date {
        guard let last = days.last else { return start }
        return calendar.date(byAdding: .day, value: 1, to: last) ?? last
    }

    public func shifted(by weeks: Int) -> TimesheetWeek {
        let moved = calendar.date(byAdding: .weekOfYear, value: weeks, to: start) ?? start
        return TimesheetWeek(containing: moved, calendar: calendar)
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// Which column a date falls in, or nil if it is not this week.
    public func index(of date: Date) -> Int? {
        let day = calendar.startOfDay(for: date)
        return days.firstIndex { calendar.isDate($0, inSameDayAs: day) }
    }

    public var title: String {
        guard let first = days.first, let last = days.last else { return "" }
        let from = first.formatted(.dateTime.day().month(.abbreviated))
        let to = last.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(from) – \(to)"
    }
}

/// One line of the timesheet: a card, and what was logged against it each day.
public struct TimesheetRow: Sendable, Equatable, Identifiable {
    public let taskID: String
    public let personID: String?
    public var title: String
    public var cardKey: String
    /// Seven entries, one per day, in the week's own order.
    public var minutes: [Int]
    public var billableMinutes: [Int]
    /// The entry ids behind each day, so editing a cell knows what to change.
    public var entryIDs: [[String]]

    public var id: String { "\(taskID)|\(personID ?? "")" }

    public init(
        taskID: String,
        personID: String?,
        title: String,
        cardKey: String,
        minutes: [Int],
        billableMinutes: [Int],
        entryIDs: [[String]]
    ) {
        self.taskID = taskID
        self.personID = personID
        self.title = title
        self.cardKey = cardKey
        self.minutes = minutes
        self.billableMinutes = billableMinutes
        self.entryIDs = entryIDs
    }

    public var total: Int { minutes.reduce(0, +) }
    public var billableTotal: Int { billableMinutes.reduce(0, +) }
}

/// A whole week's worth of rows, with the totals a timesheet is read for.
public struct Timesheet: Sendable, Equatable {
    public let week: TimesheetWeek
    public var rows: [TimesheetRow]

    public init(week: TimesheetWeek, rows: [TimesheetRow]) {
        self.week = week
        self.rows = rows
    }

    public var dailyTotals: [Int] {
        (0..<7).map { day in rows.reduce(0) { $0 + ($1.minutes.indices.contains(day) ? $1.minutes[day] : 0) } }
    }

    public var dailyBillableTotals: [Int] {
        (0..<7).map { day in rows.reduce(0) { $0 + ($1.billableMinutes.indices.contains(day) ? $1.billableMinutes[day] : 0) } }
    }

    public var total: Int { rows.reduce(0) { $0 + $1.total } }
    public var billableTotal: Int { rows.reduce(0) { $0 + $1.billableTotal } }

    /// Builds the grid from the raw entries.
    ///
    /// Entries outside the week are ignored rather than folded into the
    /// nearest day: a timesheet that quietly moved somebody's hours would be
    /// worse than one that shows a day short.
    public static func build(
        week: TimesheetWeek,
        entries: [WorkLogEntry],
        titles: [String: String],
        keys: [String: String]
    ) -> Timesheet {
        var byRow: [String: TimesheetRow] = [:]
        var order: [String] = []

        for entry in entries {
            guard let day = week.index(of: entry.workedOn) else { continue }
            let key = "\(entry.taskID)|\(entry.personID ?? "")"
            if byRow[key] == nil {
                order.append(key)
                byRow[key] = TimesheetRow(
                    taskID: entry.taskID,
                    personID: entry.personID,
                    title: titles[entry.taskID] ?? "Untitled",
                    cardKey: keys[entry.taskID] ?? "",
                    minutes: Array(repeating: 0, count: 7),
                    billableMinutes: Array(repeating: 0, count: 7),
                    entryIDs: Array(repeating: [], count: 7)
                )
            }
            byRow[key]?.minutes[day] += entry.minutes
            if entry.billable { byRow[key]?.billableMinutes[day] += entry.minutes }
            byRow[key]?.entryIDs[day].append(entry.id)
        }

        return Timesheet(week: week, rows: order.compactMap { byRow[$0] })
    }
}

// MARK: - Time in status

/// One move of a card from one column to another.
public struct StatusChangeRecord: Sendable, Equatable {
    public let taskID: String
    public let fromStatusID: String?
    public let toStatusID: String
    public let at: Date

    public init(taskID: String, fromStatusID: String?, toStatusID: String, at: Date) {
        self.taskID = taskID
        self.fromStatusID = fromStatusID
        self.toStatusID = toStatusID
        self.at = at
    }
}

/// How long one card spent in one column.
public struct TimeInStatus: Sendable, Equatable, Identifiable {
    public let statusID: String
    public var seconds: TimeInterval
    /// How many separate times it was in this column. A card that goes back
    /// for rework visits `In progress` twice, and the count is what says so —
    /// the total alone would read as one long stretch.
    public var visits: Int

    public var id: String { statusID }

    public init(statusID: String, seconds: TimeInterval, visits: Int) {
        self.statusID = statusID
        self.seconds = seconds
        self.visits = visits
    }

    public var days: Double { seconds / 86_400 }

    public var description: String {
        let hours = seconds / 3_600
        if hours < 1 { return "\(Int((seconds / 60).rounded()))m" }
        if hours < 48 { return String(format: "%.1fh", hours) }
        return String(format: "%.1f days", days)
    }
}

/// Works out where a card's time actually went.
public enum TimeInStatusReport {
    /// For one card, from its history.
    ///
    /// The stretch a card is in *now* is counted up to `now`, which is why the
    /// report changes between two readings without anything having moved —
    /// that is the honest answer, and freezing it at the last change would
    /// report a card that has been stuck for a month as having been there for
    /// no time at all.
    ///
    /// Changes are sorted before they are read, so history written out of
    /// order — an import, a clock that went backwards — cannot produce a
    /// negative stretch.
    public static func forTask(_ changes: [StatusChangeRecord], now: Date) -> [TimeInStatus] {
        let ordered = changes.sorted { $0.at < $1.at }
        guard !ordered.isEmpty else { return [] }

        var seconds: [String: TimeInterval] = [:]
        var visits: [String: Int] = [:]
        var order: [String] = []

        func note(_ statusID: String) {
            if visits[statusID] == nil { order.append(statusID) }
            visits[statusID, default: 0] += 1
        }

        for (index, change) in ordered.enumerated() {
            note(change.toStatusID)
            let until = index + 1 < ordered.count ? ordered[index + 1].at : max(now, change.at)
            seconds[change.toStatusID, default: 0] += until.timeIntervalSince(change.at)
        }

        return order.map {
            TimeInStatus(statusID: $0, seconds: seconds[$0] ?? 0, visits: visits[$0] ?? 0)
        }
    }

    /// Across many cards, added up per column.
    ///
    /// The averages a board is read for — "how long does review take" — need
    /// the per-card totals summed and divided by the number of cards that were
    /// ever in that column, not by the number of cards altogether.
    public static func across(_ changes: [StatusChangeRecord], now: Date) -> [String: TimeInStatusSummary] {
        var byTask: [String: [StatusChangeRecord]] = [:]
        for change in changes { byTask[change.taskID, default: []].append(change) }

        var summaries: [String: TimeInStatusSummary] = [:]
        for (_, records) in byTask {
            for entry in forTask(records, now: now) {
                var summary = summaries[entry.statusID] ?? TimeInStatusSummary(statusID: entry.statusID)
                summary.totalSeconds += entry.seconds
                summary.taskCount += 1
                summary.visits += entry.visits
                summary.longestSeconds = max(summary.longestSeconds, entry.seconds)
                summaries[entry.statusID] = summary
            }
        }
        return summaries
    }
}

/// One column, across every card that passed through it.
public struct TimeInStatusSummary: Sendable, Equatable, Identifiable {
    public let statusID: String
    public var totalSeconds: TimeInterval = 0
    public var taskCount: Int = 0
    public var visits: Int = 0
    public var longestSeconds: TimeInterval = 0

    public var id: String { statusID }

    public init(statusID: String) {
        self.statusID = statusID
    }

    public var averageSeconds: TimeInterval {
        taskCount == 0 ? 0 : totalSeconds / Double(taskCount)
    }

    public var averageDescription: String {
        TimeInStatus(statusID: statusID, seconds: averageSeconds, visits: visits).description
    }

    public var longestDescription: String {
        TimeInStatus(statusID: statusID, seconds: longestSeconds, visits: visits).description
    }
}
