import Foundation

/// The filter language: `due < +7d priority >= high not is:done`.
///
/// Parsing is separated from compiling on purpose. This file turns text into a
/// tree and knows nothing about SQL; `TaskQueryCompiler` in the store turns the
/// tree into a parameterised statement. Values never become SQL text at any
/// point — they are bound — so the language cannot be used to reach the
/// database, whatever is typed into the search field.
///
/// Relative dates stay relative here (`+7d` is "seven days", not an instant)
/// and resolve against a clock at compile time, so a saved query means the same
/// thing tomorrow as it does today.

public indirect enum TaskFilter: Sendable, Equatable {
    case all
    case and([TaskFilter])
    case or([TaskFilter])
    case not(TaskFilter)
    case comparison(QueryField, QueryComparison, QueryValue)
    case flag(QueryFlag)
    /// Free text, matched against the full-text index.
    case text(String)
}

extension TaskFilter {
    /// Whether the query speaks about the trash at all.
    ///
    /// Everything that reads cards hides trashed ones by default. A query that
    /// mentions the trash has asked for them, and gets exactly what it asked
    /// for — which is the whole mechanism by which the trash is reachable.
    public var mentionsTrash: Bool {
        switch self {
        case .flag(.trashed): true
        case .and(let branches), .or(let branches): branches.contains(where: \.mentionsTrash)
        case .not(let inner): inner.mentionsTrash
        default: false
        }
    }
}

public enum QueryField: String, Sendable, CaseIterable {
    case due, start, created, updated, completed
    case priority, type, status, title, assignee, label

    var isDate: Bool {
        switch self {
        case .due, .start, .created, .updated, .completed: true
        default: false
        }
    }
}

public enum QueryComparison: Sendable, Equatable {
    case lessThan, atMost, greaterThan, atLeast, equals, notEquals
}

public enum QueryValue: Sendable, Equatable {
    case date(RelativeDate)
    case priority(Priority)
    case type(TaskType)
    case text(String)
    /// `due = none` — the field is not set.
    case none
}

public enum QueryFlag: String, Sendable, CaseIterable {
    case done, open, overdue, trashed, assigned, unassigned, subtask, labelled
}

/// A date the user can write: an exact day, or one relative to today.
///
/// Kept unresolved so that `due < +7d` saved on Monday still means "within a
/// week" on Friday rather than a frozen instant.
public enum RelativeDate: Sendable, Equatable {
    case absolute(year: Int, month: Int, day: Int)
    case daysFromToday(Int)

    /// The start of the day in question, in the user's calendar.
    public func resolve(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .absolute(let year, let month, let day):
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            return calendar.date(from: components) ?? now
        case .daysFromToday(let offset):
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: offset, to: today) ?? today
        }
    }
}

public struct QueryError: Error, Equatable, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Parsing

public enum TaskQueryParser {

    public static func parse(_ source: String) throws -> TaskFilter {
        var tokens = Tokenizer.tokenize(source)
        guard !tokens.isEmpty else { return .all }

        var parser = Parser(tokens: tokens)
        let filter = try parser.parseExpression()
        guard parser.isAtEnd else {
            throw QueryError("unexpected `\(parser.peekText)` at the end of the query.")
        }
        tokens.removeAll()
        return filter
    }

    // MARK: Tokens

    enum Token: Equatable {
        case word(String)
        case quoted(String)
        case comparison(QueryComparison)
        case colon
        case leftParen
        case rightParen

        var text: String {
            switch self {
            case .word(let value), .quoted(let value): value
            case .comparison(let comparison):
                switch comparison {
                case .lessThan: "<"
                case .atMost: "<="
                case .greaterThan: ">"
                case .atLeast: ">="
                case .equals: "="
                case .notEquals: "!="
                }
            case .colon: ":"
            case .leftParen: "("
            case .rightParen: ")"
            }
        }
    }

    enum Tokenizer {
        static func tokenize(_ source: String) -> [Token] {
            var tokens: [Token] = []
            var characters = Array(source)
            var index = 0

            func peek(_ offset: Int = 0) -> Character? {
                let target = index + offset
                return target < characters.count ? characters[target] : nil
            }

            while index < characters.count {
                let character = characters[index]

                if character.isWhitespace {
                    index += 1
                } else if character == "(" {
                    tokens.append(.leftParen); index += 1
                } else if character == ")" {
                    tokens.append(.rightParen); index += 1
                } else if character == ":" {
                    tokens.append(.colon); index += 1
                } else if character == "<" {
                    if peek(1) == "=" { tokens.append(.comparison(.atMost)); index += 2 }
                    else { tokens.append(.comparison(.lessThan)); index += 1 }
                } else if character == ">" {
                    if peek(1) == "=" { tokens.append(.comparison(.atLeast)); index += 2 }
                    else { tokens.append(.comparison(.greaterThan)); index += 1 }
                } else if character == "=" {
                    tokens.append(.comparison(.equals)); index += 1
                } else if character == "!" && peek(1) == "=" {
                    tokens.append(.comparison(.notEquals)); index += 2
                } else if character == "\"" {
                    // A quoted phrase runs to the next quote, or to the end if
                    // the user has not typed the closing one yet — search
                    // fields are read while they are still being written.
                    index += 1
                    var value = ""
                    while index < characters.count, characters[index] != "\"" {
                        value.append(characters[index])
                        index += 1
                    }
                    if index < characters.count { index += 1 }
                    tokens.append(.quoted(value))
                } else {
                    var value = ""
                    while index < characters.count {
                        let next = characters[index]
                        if next.isWhitespace || "()<>=!:\"".contains(next) { break }
                        value.append(next)
                        index += 1
                    }
                    tokens.append(.word(value))
                }
            }

            characters.removeAll()
            return tokens
        }
    }

    // MARK: Recursive descent

    struct Parser {
        let tokens: [Token]
        var position = 0

        var isAtEnd: Bool { position >= tokens.count }
        var peekText: String { isAtEnd ? "" : tokens[position].text }

        func peek() -> Token? { isAtEnd ? nil : tokens[position] }

        mutating func advance() -> Token? {
            guard !isAtEnd else { return nil }
            defer { position += 1 }
            return tokens[position]
        }

        mutating func parseExpression() throws -> TaskFilter {
            try parseOr()
        }

        mutating func parseOr() throws -> TaskFilter {
            var branches = [try parseAnd()]
            while case .word(let word) = peek(), word.lowercased() == "or" {
                _ = advance()
                branches.append(try parseAnd())
            }
            return branches.count == 1 ? branches[0] : .or(branches)
        }

        /// Terms sit next to each other with no operator: `due < +7d is:open`
        /// means both. Spelling `and` is allowed and means the same.
        mutating func parseAnd() throws -> TaskFilter {
            var terms = [try parseUnary()]

            while let token = peek() {
                if case .rightParen = token { break }
                if case .word(let word) = token {
                    let lowered = word.lowercased()
                    if lowered == "or" { break }
                    if lowered == "and" { _ = advance() }
                }
                if isAtEnd { break }
                if case .rightParen = peek() { break }
                terms.append(try parseUnary())
            }

            return terms.count == 1 ? terms[0] : .and(terms)
        }

        mutating func parseUnary() throws -> TaskFilter {
            if case .word(let word) = peek(), ["not", "-"].contains(word.lowercased()) {
                _ = advance()
                return .not(try parseUnary())
            }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> TaskFilter {
            guard let token = advance() else {
                throw QueryError("the query ends where a term was expected.")
            }

            switch token {
            case .leftParen:
                let inner = try parseExpression()
                guard case .rightParen = peek() else {
                    throw QueryError("a `(` here is never closed.")
                }
                _ = advance()
                return inner

            case .rightParen:
                throw QueryError("a `)` here has no matching `(`.")

            case .comparison, .colon:
                throw QueryError("`\(token.text)` needs a field in front of it, like `due < +7d`.")

            case .quoted(let value):
                return .text(value)

            case .word(let word):
                return try parseWord(word)
            }
        }

        /// A bare word is either the start of `field op value`, an `is:` flag,
        /// or free text to search for.
        mutating func parseWord(_ word: String) throws -> TaskFilter {
            let lowered = word.lowercased()

            if lowered == "is", case .colon = peek() {
                _ = advance()
                guard case .word(let name)? = advance() else {
                    throw QueryError("`is:` needs one of \(QueryFlag.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                guard let flag = QueryFlag(rawValue: name.lowercased()) else {
                    throw QueryError("`is:\(name)` is not one of \(QueryFlag.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                return .flag(flag)
            }

            guard let field = QueryField(rawValue: lowered) else {
                return .text(word)
            }

            let comparison: QueryComparison
            switch peek() {
            case .comparison(let parsed):
                _ = advance()
                comparison = parsed
            case .colon:
                _ = advance()
                comparison = .equals
            default:
                // `status` on its own is not a filter, it is a word someone is
                // searching for.
                return .text(word)
            }

            guard let valueToken = advance() else {
                throw QueryError("`\(word)` is missing the value to compare against.")
            }

            return .comparison(field, comparison, try parseValue(valueToken.text, for: field, word: word))
        }

        func parseValue(_ raw: String, for field: QueryField, word: String) throws -> QueryValue {
            if raw.lowercased() == "none" || raw.lowercased() == "null" {
                return .none
            }

            switch field {
            case .priority:
                guard let priority = Self.priority(named: raw) else {
                    throw QueryError("`\(raw)` is not a priority. Try lowest, low, normal, high or highest.")
                }
                return .priority(priority)

            case .type:
                guard let type = Self.type(named: raw) else {
                    throw QueryError("`\(raw)` is not a type. Try epic, story, task or bug.")
                }
                return .type(type)

            case .status, .title, .assignee, .label:
                return .text(raw)

            default:
                guard let date = Self.relativeDate(raw) else {
                    throw QueryError("`\(raw)` is not a date. Try 2026-10-01, today, +7d or -2w.")
                }
                return .date(date)
            }
        }

        static func priority(named raw: String) -> Priority? {
            switch raw.lowercased() {
            case "lowest": .lowest
            case "low": .low
            case "normal", "medium": .normal
            case "high": .high
            case "highest", "urgent": .highest
            default: nil
            }
        }

        static func type(named raw: String) -> TaskType? {
            switch raw.lowercased() {
            case "epic": .epic
            case "story": .story
            case "task": .task
            case "bug": .bug
            default: nil
            }
        }

        /// `2026-10-01`, `today`, `tomorrow`, `yesterday`, `+7d`, `-2w`, `+1m`.
        static func relativeDate(_ raw: String) -> RelativeDate? {
            let lowered = raw.lowercased()

            switch lowered {
            case "today", "now": return .daysFromToday(0)
            case "tomorrow": return .daysFromToday(1)
            case "yesterday": return .daysFromToday(-1)
            default: break
            }

            if lowered.first == "+" || lowered.first == "-" {
                let sign = lowered.first == "-" ? -1 : 1
                var body = lowered.dropFirst()
                guard let unit = body.popLast(), let amount = Int(body) else { return nil }
                switch unit {
                case "d": return .daysFromToday(sign * amount)
                case "w": return .daysFromToday(sign * amount * 7)
                case "m": return .daysFromToday(sign * amount * 30)
                case "y": return .daysFromToday(sign * amount * 365)
                default: return nil
                }
            }

            let parts = lowered.split(separator: "-")
            guard parts.count == 3,
                  let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                  (1...12).contains(month), (1...31).contains(day)
            else { return nil }

            return .absolute(year: year, month: month, day: day)
        }
    }
}
