import Foundation

/// What a line of quick-add text turned out to mean.
public struct QuickAddResult: Sendable, Equatable {
    /// The title with every token that was understood removed. Never empty
    /// unless the input was; a line made entirely of tokens keeps its text.
    public var title: String
    public var dueDate: Date?
    /// Whether a time of day was actually said. A card due "tomorrow" is due
    /// on a day; one due "tomorrow 3pm" is due at a moment, and a reminder
    /// needs to know which.
    public var hasTime: Bool
    public var priority: Priority?
    /// `#tags`, in the order written. Matched to labels by name, and the ones
    /// that match nothing are offered as labels to create.
    public var labels: [String]
    /// `@names`, in the order written.
    public var assignees: [String]

    public init(
        title: String,
        dueDate: Date? = nil,
        hasTime: Bool = false,
        priority: Priority? = nil,
        labels: [String] = [],
        assignees: [String] = []
    ) {
        self.title = title
        self.dueDate = dueDate
        self.hasTime = hasTime
        self.priority = priority
        self.labels = labels
        self.assignees = assignees
    }

    public var isBare: Bool {
        dueDate == nil && priority == nil && labels.isEmpty && assignees.isEmpty
    }
}

/// Turns "Fix login bug tomorrow 3pm !high #backend @Aditya" into a card.
///
/// Three rules decide everything here, and they are all about not surprising
/// somebody who is typing quickly:
///
///   * **Only unambiguous tokens are taken.** `!high`, `#tag` and `@name` are
///     punctuation nobody writes by accident. Dates are the exception, and
///     they are matched only in the forms people actually type — "tomorrow",
///     "next tuesday", "3pm", "24/12" — never by guessing at loose numbers.
///   * **What is understood is removed; what is not is left alone.** The title
///     is what remains, so a word the parser did not recognise stays in the
///     title rather than vanishing into a field nobody looks at.
///   * **A line that parses to nothing is still a card.** Quick-add must never
///     refuse. The worst case is a card titled exactly what was typed.
///
/// Entirely local: a table of words and a `Calendar`, no service and nothing
/// to reach for.
public enum QuickAddParser {

    public static func parse(
        _ input: String, now: Date = .now, calendar: Calendar = .current
    ) -> QuickAddResult {
        var result = QuickAddResult(title: "")
        var words = input.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var kept: [String] = []
        var index = 0

        while index < words.count {
            let word = words[index]

            if let priority = priority(from: word) {
                result.priority = priority
                index += 1
                continue
            }

            if word.hasPrefix("#"), word.count > 1 {
                result.labels.append(String(word.dropFirst()))
                index += 1
                continue
            }

            if word.hasPrefix("@"), word.count > 1 {
                result.assignees.append(String(word.dropFirst()))
                index += 1
                continue
            }

            // Dates can be two words ("next tuesday", "in 3 days"), so the
            // longer match is tried first — otherwise "next" would be kept as
            // a title word and "tuesday" read as this week's.
            if let match = date(words: words, from: index, now: now, calendar: calendar) {
                result.dueDate = combine(
                    day: match.date, existing: result.dueDate, hasTime: result.hasTime, calendar: calendar
                )
                index += match.length
                continue
            }

            if let time = time(from: word, calendar: calendar) {
                result.hasTime = true
                result.dueDate = apply(time: time, to: result.dueDate ?? now, calendar: calendar)
                index += 1
                continue
            }

            kept.append(word)
            index += 1
        }

        result.title = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        // A line made entirely of tokens still has to become something, and
        // the only honest title left is what was typed.
        if result.title.isEmpty {
            result.title = input.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    // MARK: - Priority

    private static func priority(from word: String) -> Priority? {
        guard word.hasPrefix("!") else { return nil }
        switch word.dropFirst().lowercased() {
        case "lowest", "1": return .lowest
        case "low", "2": return .low
        case "normal", "medium", "3": return .normal
        case "high", "4": return .high
        case "highest", "urgent", "5": return .highest
        default: return nil
        }
    }

    // MARK: - Dates

    private struct DateMatch {
        let date: Date
        /// How many words it consumed.
        let length: Int
    }

    private static func date(
        words: [String], from index: Int, now: Date, calendar: Calendar
    ) -> DateMatch? {
        let word = words[index].lowercased()
        let next = index + 1 < words.count ? words[index + 1].lowercased() : ""

        // Two words first.
        if word == "next", let weekday = weekday(next) {
            return DateMatch(date: nextWeekday(weekday, after: now, calendar: calendar, skippingAWeek: true), length: 2)
        }
        if word == "this", let weekday = weekday(next) {
            return DateMatch(date: nextWeekday(weekday, after: now, calendar: calendar, skippingAWeek: false), length: 2)
        }
        if word == "next", next == "week",
           let date = calendar.date(byAdding: .day, value: 7, to: now) {
            return DateMatch(date: date, length: 2)
        }
        if word == "next", next == "month",
           let date = calendar.date(byAdding: .month, value: 1, to: now) {
            return DateMatch(date: date, length: 2)
        }
        if word == "in", let amount = Int(next), index + 2 < words.count {
            let unit = words[index + 2].lowercased()
            if let date = add(amount, unit: unit, to: now, calendar: calendar) {
                return DateMatch(date: date, length: 3)
            }
        }

        // One word.
        switch word {
        case "today", "tod":
            return DateMatch(date: now, length: 1)
        case "tomorrow", "tmr", "tom":
            return calendar.date(byAdding: .day, value: 1, to: now).map { DateMatch(date: $0, length: 1) }
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: now).map { DateMatch(date: $0, length: 1) }
        default:
            break
        }

        if let weekday = weekday(word) {
            return DateMatch(
                date: nextWeekday(weekday, after: now, calendar: calendar, skippingAWeek: false), length: 1
            )
        }

        if let date = numericDate(word, now: now, calendar: calendar) {
            return DateMatch(date: date, length: 1)
        }
        return nil
    }

    private static func add(_ amount: Int, unit: String, to date: Date, calendar: Calendar) -> Date? {
        switch unit {
        case "day", "days": calendar.date(byAdding: .day, value: amount, to: date)
        case "week", "weeks": calendar.date(byAdding: .day, value: amount * 7, to: date)
        case "month", "months": calendar.date(byAdding: .month, value: amount, to: date)
        case "year", "years": calendar.date(byAdding: .year, value: amount, to: date)
        default: nil
        }
    }

    private static let weekdayNames: [String: Int] = [
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7,
    ]

    private static func weekday(_ word: String) -> Int? {
        weekdayNames[word.lowercased()]
    }

    /// "Friday" on a Wednesday means this Friday; on a Friday it means next
    /// Friday, because somebody typing a weekday means a day that has not
    /// happened yet. "Next Friday" always skips a week.
    private static func nextWeekday(
        _ weekday: Int, after date: Date, calendar: Calendar, skippingAWeek: Bool
    ) -> Date {
        let today = calendar.component(.weekday, from: date)
        var delta = weekday - today
        if delta <= 0 { delta += 7 }
        if skippingAWeek { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: date) ?? date
    }

    /// `24/12`, `24/12/2026` or `2026-12-24`. Read in the order the user's own
    /// calendar puts them: a Mac set to British dates means the 24th of
    /// December by `24/12`, and one set to American dates would not have
    /// written that in the first place.
    private static func numericDate(_ word: String, now: Date, calendar: Calendar) -> Date? {
        if word.contains("-") {
            let parts = word.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, parts[0] > 31 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }

        guard word.contains("/") else { return nil }
        let parts = word.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let dayFirst = isDayFirst(calendar: calendar)
        let day = dayFirst ? parts[0] : parts[1]
        let month = dayFirst ? parts[1] : parts[0]
        guard (1...31).contains(day), (1...12).contains(month) else { return nil }

        let year = parts.count == 3 ? fourDigit(parts[2], now: now, calendar: calendar)
                                    : calendar.component(.year, from: now)
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func isDayFirst(calendar: Calendar) -> Bool {
        let format = DateFormatter.dateFormat(
            fromTemplate: "yMd", options: 0,
            locale: calendar.locale ?? Locale.current
        ) ?? "dMy"
        guard let day = format.firstIndex(of: "d"), let month = format.firstIndex(of: "M") else { return true }
        return day < month
    }

    private static func fourDigit(_ year: Int, now: Date, calendar: Calendar) -> Int {
        guard year < 100 else { return year }
        let century = (calendar.component(.year, from: now) / 100) * 100
        return century + year
    }

    // MARK: - Times

    private struct TimeOfDay {
        let hour: Int
        let minute: Int
    }

    /// `3pm`, `3:30pm`, `15:30`, `9am`. Bare numbers are *not* times: "fix
    /// issue 3" would otherwise become a card due at three in the morning.
    private static func time(from word: String, calendar: Calendar) -> TimeOfDay? {
        let lower = word.lowercased()

        if lower.hasSuffix("am") || lower.hasSuffix("pm") {
            let isAfternoon = lower.hasSuffix("pm")
            let body = String(lower.dropLast(2))
            let parts = body.split(separator: ":").compactMap { Int($0) }
            guard let hour = parts.first, (1...12).contains(hour) else { return nil }
            let minute = parts.count > 1 ? parts[1] : 0
            guard (0...59).contains(minute) else { return nil }

            let adjusted = isAfternoon ? (hour == 12 ? 12 : hour + 12) : (hour == 12 ? 0 : hour)
            return TimeOfDay(hour: adjusted, minute: minute)
        }

        guard lower.contains(":") else { return nil }
        let parts = lower.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return TimeOfDay(hour: parts[0], minute: parts[1])
    }

    private static func apply(time: TimeOfDay, to date: Date, calendar: Calendar) -> Date {
        calendar.date(
            bySettingHour: time.hour, minute: time.minute, second: 0, of: date
        ) ?? date
    }

    /// A day given after a time keeps the time: "3pm tomorrow" and "tomorrow
    /// 3pm" are the same sentence, and only one order working would be a
    /// parser that makes people think about parsing.
    private static func combine(
        day: Date, existing: Date?, hasTime: Bool, calendar: Calendar
    ) -> Date {
        guard hasTime, let existing else { return calendar.startOfDay(for: day) }
        let time = calendar.dateComponents([.hour, .minute], from: existing)
        return calendar.date(
            bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day
        ) ?? day
    }
}
