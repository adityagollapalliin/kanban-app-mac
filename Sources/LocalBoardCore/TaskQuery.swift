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
    /// A field the project invented: `cf:Size >= 3`.
    ///
    /// The field is named rather than enumerated, because the set of them is
    /// data. The value stays as text until the compiler can look up what kind
    /// of field it is — only then is it known whether `3` means a number, a
    /// choice spelled "3", or a mistake.
    case customField(String, QueryComparison, QueryValue)
    /// Free text, matched against the full-text index.
    case text(String)

    // MARK: Written only by the JQL grammar
    //
    // The simple parser never produces any of these, which is what keeps its
    // saved filters compiling to exactly the SQL they always did.

    /// `priority IN (high, highest)`, or `NOT IN`.
    case membership(QueryTarget, [QueryValue], negated: Bool)
    /// `assignee IS EMPTY`, or `IS NOT EMPTY`.
    case emptiness(QueryTarget, negated: Bool)
    /// `title ~ login` — contains, as JQL spells it.
    case contains(QueryTarget, String)
    /// `status WAS "In Progress"`, `status CHANGED FROM x TO y DURING (a, b)`.
    case history(HistoryClause)
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
    /// The printed tag: `key = WORK-14`, or just `key = 14` within a project.
    case key
    case version, epic, sprint
    /// The estimate, under the name teams actually say out loud.
    case points
    /// How long the card has sat in its current column: `days >= 5`.
    case days
    /// The reason written on a flag: `flag = "waiting on legal"`.
    case flag

    public var isDate: Bool {
        switch self {
        case .due, .start, .created, .updated, .completed: true
        default: false
        }
    }

    /// Fields compared as plain numbers rather than as dates or vocabularies.
    public var isNumeric: Bool {
        switch self {
        case .points, .days: true
        default: false
        }
    }
}

public enum QueryComparison: Sendable, Equatable {
    case lessThan, atMost, greaterThan, atLeast, equals, notEquals
}

public enum QueryValue: Sendable, Equatable {
    case date(RelativeDate)
    /// `currentUser()`, `startOfWeek(-1)`, `openSprints()`. Resolved against
    /// the clock, the settings or the database when the query is compiled.
    case function(QueryFunction)
    case priority(Priority)
    case type(TaskType)
    case text(String)
    case number(Double)
    /// `due = none` — the field is not set.
    case none
}

public enum QueryFlag: String, Sendable, CaseIterable {
    case done, open, overdue, trashed, assigned, unassigned, subtask, labelled
    /// Blocked or impeded. The one thing a board most needs to be able to ask.
    case flagged
    /// Assigned to whoever this copy of the app belongs to. Resolved against
    /// the person chosen in Settings, so a saved view reading `is:mine` means
    /// something different — and correct — on each Mac it is opened on.
    case mine
    case epic, released, backlog
}

/// A date the user can write: an exact day, or one relative to today.
///
/// Kept unresolved so that `due < +7d` saved on Monday still means "within a
/// week" on Friday rather than a frozen instant.
public enum RelativeDate: Sendable, Equatable {
    case absolute(year: Int, month: Int, day: Int)
    case daysFromToday(Int)
    /// `startOfWeek(-1)`, `now()`. Written only by the JQL grammar.
    case function(QueryFunction)

    /// Reads the spellings the query language accepts: `2026-10-01`, `today`,
    /// `tomorrow`, `yesterday`, `+7d`, `-2w`.
    ///
    /// Public because a date can turn up somewhere the parser never saw — a
    /// custom field's value, for instance, whose kind is only known once the
    /// store has looked it up.
    public static func parse(_ text: String) -> RelativeDate? {
        TaskQueryParser.Parser.relativeDate(text)
    }

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
        case .function(let function):
            return Self.resolve(function, now: now, calendar: calendar)
        }
    }

    /// Where a JQL date function lands.
    ///
    /// The *end* of a period is the last instant of it rather than the start
    /// of the next one, so `due <= endOfWeek()` includes work due on Sunday
    /// evening instead of quietly dropping it.
    static func resolve(_ function: QueryFunction, now: Date, calendar: Calendar) -> Date {
        func interval(_ component: Calendar.Component, _ offset: Int) -> DateInterval? {
            guard let moved = calendar.date(byAdding: component, value: offset, to: now) else { return nil }
            return calendar.dateInterval(of: component, for: moved)
        }

        switch function {
        case .now:
            return now
        case .startOfDay(let offset):
            return interval(.day, offset)?.start ?? calendar.startOfDay(for: now)
        case .endOfDay(let offset):
            return (interval(.day, offset)?.end ?? now).addingTimeInterval(-1)
        case .startOfWeek(let offset):
            return interval(.weekOfYear, offset)?.start ?? calendar.startOfDay(for: now)
        case .endOfWeek(let offset):
            return (interval(.weekOfYear, offset)?.end ?? now).addingTimeInterval(-1)
        case .startOfMonth(let offset):
            return interval(.month, offset)?.start ?? calendar.startOfDay(for: now)
        case .endOfMonth(let offset):
            return (interval(.month, offset)?.end ?? now).addingTimeInterval(-1)
        default:
            // Not a date at all — the parser refuses these where a date is
            // expected, so reaching here would be a bug rather than input.
            return now
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

    /// The original language. Unchanged, and deliberately kept as the
    /// signature every existing caller already uses.
    public static func parse(_ source: String) throws -> TaskFilter {
        try parse(source, syntax: .simple).filter
    }

    /// Reads a query in whichever language it was written in.
    ///
    /// One parser with a mode rather than two parsers: the fields, values,
    /// flags and brackets are identical in both languages, and a second copy
    /// of that would drift. Every JQL-only production is gated on the mode, so
    /// a `.simple` parse cannot reach one — which is what the regression
    /// baseline checks, query by query.
    public static func parse(_ source: String, syntax: QuerySyntax) throws -> ParsedQuery {
        var tokens = Tokenizer.tokenize(source, syntax: syntax)
        guard !tokens.isEmpty else { return ParsedQuery(filter: .all) }

        var parser = Parser(tokens: tokens, syntax: syntax)

        // `ORDER BY due` on its own is every card, in that order — there is no
        // filter in front of it to parse.
        let startsWithOrder: Bool
        if syntax == .jql, case .word(let first) = tokens[0], first.lowercased() == "order" {
            startsWithOrder = true
        } else {
            startsWithOrder = false
        }

        let filter = startsWithOrder ? TaskFilter.all : try parser.parseExpression()
        let order = try parser.parseOrderBy()

        guard parser.isAtEnd else {
            throw QueryError("unexpected `\(parser.peekText)` at the end of the query.")
        }
        tokens.removeAll()
        return ParsedQuery(filter: filter, order: order)
    }

    // MARK: Tokens

    enum Token: Equatable {
        case word(String)
        case quoted(String)
        case comparison(QueryComparison)
        /// `~` — contains. Tokenised only in the JQL grammar, because in the
        /// simple one it is an ordinary character in a word somebody is
        /// searching for.
        case tilde
        /// `,` — a separator in JQL's lists and ORDER BY. In the simple
        /// grammar it is an ordinary character inside a word.
        case comma
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
            case .tilde: "~"
            case .comma: ","
            case .colon: ":"
            case .leftParen: "("
            case .rightParen: ")"
            }
        }
    }

    enum Tokenizer {
        static func tokenize(_ source: String, syntax: QuerySyntax = .simple) -> [Token] {
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
                } else if character == "~" && syntax == .jql {
                    tokens.append(.tilde); index += 1
                } else if character == "," && syntax == .jql {
                    tokens.append(.comma); index += 1
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
                        if (next == "~" || next == ",") && syntax == .jql { break }
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
        var syntax: QuerySyntax = .simple
        var position = 0

        var isJQL: Bool { syntax == .jql }

        var isAtEnd: Bool { position >= tokens.count }
        var peekText: String { isAtEnd ? "" : tokens[position].text }

        func peek() -> Token? { isAtEnd ? nil : tokens[position] }

        /// The token `offset` places further on, for the two-word operators
        /// JQL spells — `NOT IN`, and nothing else so far.
        func peek(_ offset: Int) -> Token? {
            let target = position + offset
            return target < tokens.count ? tokens[target] : nil
        }

        mutating func advance() -> Token? {
            guard !isAtEnd else { return nil }
            defer { position += 1 }
            return tokens[position]
        }

        mutating func parseExpression() throws -> TaskFilter {
            try parseOr()
        }

        /// `ORDER BY due DESC, priority` — JQL only.
        ///
        /// In the simple language `ORDER` is a word somebody is searching for,
        /// and this returns nothing without consuming a token.
        mutating func parseOrderBy() throws -> [QueryOrder] {
            guard isJQL, case .word(let word)? = peek(), word.lowercased() == "order" else {
                return []
            }
            _ = advance()

            guard case .word(let by)? = peek(), by.lowercased() == "by" else {
                throw QueryError("`ORDER` has to be followed by `BY`, as in `ORDER BY due`.")
            }
            _ = advance()

            var clauses: [QueryOrder] = []
            repeat {
                guard case .word(let name)? = advance() else {
                    throw QueryError("`ORDER BY` needs a field to order by.")
                }
                guard let field = QueryField(rawValue: name.lowercased()) else {
                    throw QueryError("`\(name)` is not a field this can order by.")
                }

                var ascending = true
                if case .word(let direction)? = peek(),
                   ["asc", "desc", "ascending", "descending"].contains(direction.lowercased()) {
                    _ = advance()
                    ascending = direction.lowercased().hasPrefix("asc")
                }
                clauses.append(QueryOrder(field: field, ascending: ascending))

                if case .comma? = peek() {
                    _ = advance()
                    continue
                }
                break
            } while true

            return clauses
        }

        /// The JQL operators that follow a field or `cf:` name.
        ///
        /// Returns nil when the next tokens are not one of them, so the caller
        /// falls through to the comparison it has always parsed.
        mutating func parseJQLOperator(on target: QueryTarget) throws -> TaskFilter? {
            guard isJQL, case .word(let word)? = peek() else { return nil }

            switch word.lowercased() {
            case "in", "not":
                var negated = false
                if word.lowercased() == "not" {
                    guard case .word(let next)? = peek(1), next.lowercased() == "in" else {
                        return nil   // `not` here belongs to somebody else.
                    }
                    negated = true
                    _ = advance()
                }
                _ = advance()
                return .membership(target, try parseValueList(for: target), negated: negated)

            case "is":
                // `assignee IS EMPTY`. `is:mine` is a different thing entirely
                // and is handled before this is ever reached.
                _ = advance()
                var negated = false
                if case .word(let next)? = peek(), next.lowercased() == "not" {
                    _ = advance()
                    negated = true
                }
                guard case .word(let empty)? = advance(),
                      ["empty", "null"].contains(empty.lowercased()) else {
                    throw QueryError("`\(target.described) IS` has to be followed by `EMPTY`.")
                }
                return .emptiness(target, negated: negated)

            case "was":
                _ = advance()
                return .history(try parseWas(target: target, negated: false))

            case "changed":
                _ = advance()
                return .history(try parseChanged(target: target, negated: false))

            default:
                return nil
            }
        }

        mutating func parseValueList(for target: QueryTarget) throws -> [QueryValue] {
            // `key IN linkedIssues(WORK-12)` — a function standing in for the
            // list, which is how JQL spells the set-valued ones.
            if case .word(let word)? = peek() {
                let probe = position
                _ = advance()
                if let function = try functionIfPresent(word) {
                    return [.function(function)]
                }
                position = probe
            }

            guard case .leftParen? = peek() else {
                throw QueryError("`IN` needs a list in brackets, like `(high, highest)`.")
            }
            _ = advance()

            var values: [QueryValue] = []
            while let token = peek() {
                if case .rightParen = token { break }
                if case .comma = token { _ = advance(); continue }
                guard let next = advance() else { break }
                let raw = next.text
                if raw.isEmpty { continue }
                values.append(try value(raw, for: target))
            }

            guard case .rightParen? = peek() else {
                throw QueryError("the list after `IN` is never closed.")
            }
            _ = advance()

            guard !values.isEmpty else {
                throw QueryError("the list after `IN` is empty.")
            }
            return values
        }

        mutating func parseWas(target: QueryTarget, negated: Bool) throws -> HistoryClause {
            guard case .field(.status) = target else {
                throw QueryError("only `status` has a recorded history to ask `WAS` about.")
            }
            guard let token = advance() else {
                throw QueryError("`WAS` needs something to have been.")
            }
            var clause = HistoryClause(
                target: target, kind: .was,
                value: try value(token.text, for: target), negated: negated
            )
            try parseDuring(into: &clause)
            return clause
        }

        mutating func parseChanged(target: QueryTarget, negated: Bool) throws -> HistoryClause {
            guard case .field(.status) = target else {
                throw QueryError("only `status` has a recorded history to ask `CHANGED` about.")
            }
            var clause = HistoryClause(target: target, kind: .changed, negated: negated)

            while case .word(let word)? = peek() {
                switch word.lowercased() {
                case "from":
                    _ = advance()
                    guard let token = advance() else {
                        throw QueryError("`CHANGED FROM` needs a status.")
                    }
                    clause.from = try value(token.text, for: target)
                case "to":
                    _ = advance()
                    guard let token = advance() else {
                        throw QueryError("`CHANGED TO` needs a status.")
                    }
                    clause.to = try value(token.text, for: target)
                case "during":
                    try parseDuring(into: &clause)
                default:
                    return clause
                }
            }
            return clause
        }

        mutating func parseDuring(into clause: inout HistoryClause) throws {
            guard case .word(let word)? = peek(), word.lowercased() == "during" else { return }
            _ = advance()

            guard case .leftParen? = peek() else {
                throw QueryError("`DURING` needs two dates in brackets, like `(-1w, now())`.")
            }
            _ = advance()

            var dates: [RelativeDate] = []
            while let token = peek() {
                if case .rightParen = token { break }
                if case .comma = token { _ = advance(); continue }
                guard let next = advance() else { break }
                let raw = next.text
                if raw.isEmpty { continue }
                // `now()` and the startOf/endOf family arrive as a word
                // followed by brackets, so they are read as functions first.
                if let function = try functionIfPresent(raw), function.isDate {
                    dates.append(.function(function))
                } else if let parsed = RelativeDate.parse(raw) {
                    dates.append(parsed)
                } else {
                    throw QueryError("`\(raw)` is not a date `DURING` can use.")
                }
            }

            guard case .rightParen? = peek() else {
                throw QueryError("the brackets after `DURING` are never closed.")
            }
            _ = advance()

            guard dates.count == 2 else {
                throw QueryError("`DURING` takes two dates — a start and an end.")
            }
            clause.duringStart = dates[0]
            clause.duringEnd = dates[1]
        }

        /// A function call, when the word is one and brackets follow.
        mutating func functionIfPresent(_ word: String) throws -> QueryFunction? {
            guard isJQL else { return nil }
            let lowered = word.lowercased()
            let known = [
                "currentuser", "now", "startofday", "endofday", "startofweek",
                "endofweek", "startofmonth", "endofmonth", "opensprints",
                "closedsprints", "releasedversions", "unreleasedversions", "linkedissues",
            ]
            guard known.contains(lowered) else { return nil }
            guard case .leftParen? = peek() else {
                throw QueryError("`\(word)` is a function and needs brackets, as in `\(word)()`.")
            }
            _ = advance()

            var argument = ""
            while let token = peek() {
                if case .rightParen = token { break }
                guard let next = advance() else { break }
                argument += next.text
            }
            guard case .rightParen? = peek() else {
                throw QueryError("the brackets after `\(word)` are never closed.")
            }
            _ = advance()

            func offset() throws -> Int {
                let trimmed = argument.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return 0 }
                guard let number = Int(trimmed) else {
                    throw QueryError("`\(word)` takes a whole number of periods, like `\(word)(-1)`.")
                }
                return number
            }

            switch lowered {
            case "currentuser": return .currentUser
            case "now": return .now
            case "startofday": return .startOfDay(try offset())
            case "endofday": return .endOfDay(try offset())
            case "startofweek": return .startOfWeek(try offset())
            case "endofweek": return .endOfWeek(try offset())
            case "startofmonth": return .startOfMonth(try offset())
            case "endofmonth": return .endOfMonth(try offset())
            case "opensprints": return .openSprints
            case "closedsprints": return .closedSprints
            case "releasedversions": return .releasedVersions
            case "unreleasedversions": return .unreleasedVersions
            case "linkedissues":
                let key = argument.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else {
                    throw QueryError("`linkedIssues` needs a card's key, like `linkedIssues(WORK-12)`.")
                }
                return .linkedIssues(key)
            default: return nil
            }
        }

        /// Reads one value, in whatever way the target expects it.
        mutating func value(_ raw: String, for target: QueryTarget) throws -> QueryValue {
            if let function = try functionIfPresent(raw) {
                // A date function where a date is wanted becomes an ordinary
                // relative date, so everything downstream — the compiler, the
                // saved-view round trip — keeps one path for dates.
                if function.isDate, case .field(let field) = target, field.isDate {
                    return .date(.function(function))
                }
                return .function(function)
            }

            let lowered = raw.lowercased()
            if lowered == "none" || lowered == "null" { return .none }

            guard case .field(let field) = target else { return .text(raw) }

            if field.isDate {
                guard let parsed = RelativeDate.parse(raw) else {
                    throw QueryError("`\(field.rawValue)` holds dates, and `\(raw)` is not one.")
                }
                return .date(parsed)
            }
            if field.isNumeric {
                guard let number = Double(raw) else {
                    throw QueryError("`\(field.rawValue)` holds numbers, and `\(raw)` is not one.")
                }
                return .number(number)
            }
            if field == .priority {
                guard let priority = Self.priority(named: lowered) else {
                    throw QueryError("`\(raw)` is not a priority.")
                }
                return .priority(priority)
            }
            if field == .type {
                guard let type = Self.type(named: lowered) else {
                    throw QueryError("`\(raw)` is not a kind of card.")
                }
                return .type(type)
            }
            return .text(raw)
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
                    // `ORDER BY` ends the matching part of a JQL query. In the
                    // simple language it is a word to search for and this does
                    // not fire.
                    if isJQL, lowered == "order" { break }
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

            case .comparison, .colon, .tilde, .comma:
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

            // `cf:Size >= 3`, or `cf:"Team name" = Platform` when it has a
            // space in it.
            if lowered == "cf", case .colon = peek() {
                _ = advance()
                guard let nameToken = advance(), case let name = nameToken.text, !name.isEmpty else {
                    throw QueryError("`cf:` needs a field name, like `cf:Size >= 3`.")
                }

                // IN, IS EMPTY and ~ come before the comparison, because in
                // JQL they take the place of one.
                if let jql = try parseJQLOperator(on: .custom(name)) { return jql }
                if case .tilde? = peek() {
                    _ = advance()
                    guard let token = advance() else {
                        throw QueryError("`cf:\(name) ~` needs something to look for.")
                    }
                    return .contains(.custom(name), token.text)
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
                    throw QueryError("`cf:\(name)` needs something to compare against, like `>= 3`.")
                }

                guard let valueToken = advance() else {
                    throw QueryError("`cf:\(name)` is missing the value to compare against.")
                }
                let raw = valueToken.text
                let value: QueryValue
                if isJQL {
                    value = try self.value(raw, for: .custom(name))
                } else {
                    value = (raw.lowercased() == "none" || raw.lowercased() == "null") ? .none : .text(raw)
                }
                return .customField(name, comparison, value)
            }

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

            if let jql = try parseJQLOperator(on: .field(field)) { return jql }
            if case .tilde? = peek() {
                _ = advance()
                guard let token = advance() else {
                    throw QueryError("`\(field.rawValue) ~` needs something to look for.")
                }
                return .contains(.field(field), token.text)
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

            if isJQL {
                return .comparison(field, comparison, try value(valueToken.text, for: .field(field)))
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

            case .points, .days:
                guard let amount = Double(raw) else {
                    throw QueryError("`\(raw)` is not a number. Try `\(field.rawValue) >= 3`.")
                }
                return .number(amount)

            case .status, .title, .assignee, .label, .key, .version, .epic, .flag, .sprint:
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
