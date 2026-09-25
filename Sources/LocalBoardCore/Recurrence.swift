import Foundation

/// How often a card comes back.
public enum RecurrenceFrequency: Int, Sendable, CaseIterable, Codable {
    case daily = 0
    case weekly = 1
    case monthly = 2
    case yearly = 3

    public var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }

    /// The calendar unit one interval steps by.
    var component: Calendar.Component {
        switch self {
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        case .yearly: .year
        }
    }
}

/// When the clock starts.
///
/// The distinction is the whole reason both exist. A cleaner comes on Tuesday
/// whether or not last Tuesday's went well — that is `schedule`. A filter gets
/// changed three months after it was *actually* changed, not three months after
/// somebody meant to — that is `completion`. Using one where the other belongs
/// produces either a backlog of overdue ghosts or a job that silently drifts.
public enum RecurrenceMode: Int, Sendable, CaseIterable, Codable {
    case schedule = 0
    case completion = 1

    public var label: String {
        switch self {
        case .schedule: "On schedule"
        case .completion: "After it is completed"
        }
    }

    public var explanation: String {
        switch self {
        case .schedule:
            "The next one is due on the date the rule says, whether or not this one was done."
        case .completion:
            "The clock starts when this one is finished, so a late one moves everything after it."
        }
    }
}

/// A rule for when a card comes back.
///
/// Pure arithmetic over a `Calendar`: no database, no clock of its own, no
/// side effects. Everything about recurrence that can be got wrong — the last
/// Friday of a month, the 31st in February, every second Tuesday — is decided
/// here where it can be tested, rather than inside the code that writes rows.
public struct RecurrenceRule: Sendable, Equatable, Codable {

    public var frequency: RecurrenceFrequency
    /// Every *n* days, weeks, months or years. Below 1 is read as 1: a rule
    /// that repeats every zero weeks describes nothing.
    public var interval: Int
    /// Weekdays for a weekly rule, 1 = Sunday through 7 = Saturday, as
    /// `Calendar` numbers them. Empty means "the same weekday as the date it
    /// starts from".
    public var weekdays: Set<Int>
    /// For a monthly rule: the *n*th weekday of the month, 1 through 5, or
    /// `-1` for the last. Used with a single entry in `weekdays` — this is
    /// what "every 2nd Tuesday" is made of.
    public var weekOfMonth: Int?
    /// For a monthly rule: a day of the month. A month too short for it gets
    /// its last day rather than spilling into the next one.
    public var monthDay: Int?
    public var mode: RecurrenceMode
    public var resetChecklist: Bool
    public var resetSubtasks: Bool
    public var resetStatus: Bool
    /// The rule stops after this date. `nil` means it does not stop.
    public var endsAt: Date?

    public init(
        frequency: RecurrenceFrequency = .weekly,
        interval: Int = 1,
        weekdays: Set<Int> = [],
        weekOfMonth: Int? = nil,
        monthDay: Int? = nil,
        mode: RecurrenceMode = .schedule,
        resetChecklist: Bool = true,
        resetSubtasks: Bool = true,
        resetStatus: Bool = true,
        endsAt: Date? = nil
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.weekOfMonth = weekOfMonth
        self.monthDay = monthDay
        self.mode = mode
        self.resetChecklist = resetChecklist
        self.resetSubtasks = resetSubtasks
        self.resetStatus = resetStatus
        self.endsAt = endsAt
    }

    // MARK: - The one question this type answers

    /// The next occurrence strictly after `date`, or `nil` once the rule has
    /// ended.
    ///
    /// Strictly after, always: a rule asked for the next date must never
    /// answer with the one it was given, or a card would recur onto its own
    /// due date forever.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        let from = calendar.startOfDay(for: date)
        guard let candidate = step(from: from, calendar: calendar) else { return nil }
        if let endsAt, candidate > calendar.startOfDay(for: endsAt) { return nil }
        return candidate
    }

    private func step(from date: Date, calendar: Calendar) -> Date? {
        switch frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: interval, to: date)

        case .weekly:
            return nextWeekly(from: date, calendar: calendar)

        case .monthly:
            return nextMonthly(from: date, calendar: calendar)

        case .yearly:
            return calendar.date(byAdding: .year, value: interval, to: date)
        }
    }

    /// Weekly with chosen days walks forward a day at a time within the week,
    /// then jumps `interval` weeks — so "every Monday and Thursday" gives both
    /// days, and "every other Monday" skips the week between.
    private func nextWeekly(from date: Date, calendar: Calendar) -> Date? {
        guard !weekdays.isEmpty else {
            return calendar.date(byAdding: .weekOfYear, value: interval, to: date)
        }

        // Within the same week, the next chosen day is simply the next one up.
        let weekday = calendar.component(.weekday, from: date)
        if interval == 1, let later = weekdays.filter({ $0 > weekday }).min() {
            return calendar.date(byAdding: .day, value: later - weekday, to: date)
        }

        // Otherwise jump to the first chosen day of the week `interval` weeks
        // on, which is what "every other Monday and Thursday" means: the pair
        // of days, in that week, not the next of them in this one.
        guard let earliest = weekdays.min(),
              let jumped = calendar.date(byAdding: .weekOfYear, value: interval, to: date)
        else { return nil }

        let jumpedWeekday = calendar.component(.weekday, from: jumped)
        return calendar.date(byAdding: .day, value: earliest - jumpedWeekday, to: jumped)
    }

    /// Monthly comes in two shapes: a day number, or an *n*th weekday. They
    /// are different questions — "the 15th" and "the second Tuesday" fall on
    /// the same date about once a year — so they are computed separately
    /// rather than approximated into each other.
    private func nextMonthly(from date: Date, calendar: Calendar) -> Date? {
        guard let base = calendar.date(byAdding: .month, value: interval, to: date) else { return nil }

        if let weekday = weekdays.first, let weekOfMonth {
            return nthWeekday(weekday, week: weekOfMonth, inMonthOf: base, calendar: calendar)
        }

        guard let monthDay else { return base }

        // A month too short for the day gets its last: the 31st in February is
        // the 28th (or the 29th), not the 3rd of March.
        let components = calendar.dateComponents([.year, .month], from: base)
        guard let monthStart = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: monthStart) else { return base }

        return calendar.date(byAdding: .day, value: min(monthDay, range.count) - 1, to: monthStart)
    }

    /// The *n*th given weekday of a month, or its last when `week` is -1.
    ///
    /// Months with only four of a weekday are why "last" is its own case
    /// rather than "the fifth": asking for the fifth Tuesday of a month that
    /// has four would otherwise land in the month after.
    func nthWeekday(_ weekday: Int, week: Int, inMonthOf date: Date, calendar: Calendar) -> Date? {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let monthStart = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: monthStart) else { return nil }

        let days = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: monthStart) }
        let matching = days.filter { calendar.component(.weekday, from: $0) == weekday }

        guard !matching.isEmpty else { return nil }
        if week < 0 { return matching.last }
        return week <= matching.count ? matching[week - 1] : matching.last
    }

    // MARK: - Saying it in words

    /// What the rule says, in the words somebody would use — shown beside the
    /// controls so a rule built out of four pickers can be read back as one
    /// sentence and checked.
    public var summary: String {
        let every = interval == 1 ? "Every" : "Every \(ordinal(interval))"

        switch frequency {
        case .daily:
            return interval == 1 ? "Every day" : "Every \(interval) days"

        case .weekly:
            guard !weekdays.isEmpty else {
                return interval == 1 ? "Every week" : "Every \(interval) weeks"
            }
            let names = weekdays.sorted().map { Self.weekdayName($0) }.joined(separator: ", ")
            return "\(every) \(names)"

        case .monthly:
            if let weekday = weekdays.first, let weekOfMonth {
                let which = weekOfMonth < 0 ? "last" : ordinal(weekOfMonth)
                let month = interval == 1 ? "month" : "\(interval) months"
                return "The \(which) \(Self.weekdayName(weekday)) of every \(month)"
            }
            if let monthDay {
                let month = interval == 1 ? "month" : "\(interval) months"
                return "Day \(monthDay) of every \(month)"
            }
            return interval == 1 ? "Every month" : "Every \(interval) months"

        case .yearly:
            return interval == 1 ? "Every year" : "Every \(interval) years"
        }
    }

    private func ordinal(_ value: Int) -> String {
        switch value {
        case 1: "1st"
        case 2: "2nd"
        case 3: "3rd"
        default: "\(value)th"
        }
    }

    public static func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "?"
    }

    /// Weekdays are stored as a comma-separated list rather than a bitmask:
    /// a column somebody can read in `sqlite3` is worth more than two bytes.
    public var weekdayList: String {
        weekdays.sorted().map(String.init).joined(separator: ",")
    }

    public static func weekdays(from list: String) -> Set<Int> {
        Set(list.split(separator: ",").compactMap { Int($0) }.filter { (1...7).contains($0) })
    }
}
