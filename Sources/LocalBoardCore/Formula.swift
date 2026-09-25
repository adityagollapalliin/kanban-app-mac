import Foundation

/// A value a formula can hold.
///
/// `empty` is a value rather than an absence, because a formula over a field
/// nobody filled in should read as blank — not as zero, which is a number
/// somebody might act on.
public enum FormulaValue: Sendable, Equatable {
    case number(Double)
    case text(String)
    case date(Date)
    case boolean(Bool)
    case empty

    public var isEmpty: Bool { self == .empty }

    /// How it reads in a cell.
    public func display(currency: String = "") -> String {
        switch self {
        case .empty:
            return ""
        case .text(let value):
            return value
        case .boolean(let value):
            return value ? "Yes" : "No"
        case .date(let value):
            return value.formatted(date: .abbreviated, time: .omitted)
        case .number(let value):
            let rounded = (value * 100).rounded() / 100
            let text = rounded == rounded.rounded()
                ? String(Int(rounded))
                : String(format: "%.2f", rounded)
            return currency.isEmpty ? text : "\(currency) \(text)"
        }
    }
}

/// Everything that can go wrong, phrased so it can be shown to the person who
/// typed the formula rather than logged and swallowed.
public enum FormulaError: Error, Equatable, Sendable {
    case tooLong(limit: Int)
    case tooComplex
    case unexpectedCharacter(String, at: Int)
    case unterminatedText
    case unterminatedField
    case unexpectedEnd
    case unexpectedToken(String)
    case unknownField(String)
    case unknownFunction(String)
    case wrongArgumentCount(function: String, expected: String, got: Int)
    case typeMismatch(String)
    case divisionByZero
    case circularReference(String)

    public var message: String {
        switch self {
        case .tooLong(let limit):
            "The formula is longer than \(limit) characters."
        case .tooComplex:
            "The formula is too deeply nested to work out."
        case .unexpectedCharacter(let character, let offset):
            "Can't read “\(character)” at character \(offset + 1)."
        case .unterminatedText:
            "A piece of text is missing its closing quote."
        case .unterminatedField:
            "A field name is missing its closing brace."
        case .unexpectedEnd:
            "The formula stops before it finishes."
        case .unexpectedToken(let token):
            "Didn't expect “\(token)” here."
        case .unknownField(let name):
            "There is no field called “\(name)”."
        case .unknownFunction(let name):
            "There is no function called “\(name)”."
        case .wrongArgumentCount(let function, let expected, let got):
            "\(function) takes \(expected), not \(got)."
        case .typeMismatch(let detail):
            detail
        case .divisionByZero:
            "That divides by zero."
        case .circularReference(let name):
            "“\(name)” ends up depending on itself."
        }
    }
}

// MARK: - Tokens

enum FormulaToken: Equatable {
    case number(Double)
    case text(String)
    case field(String)
    case identifier(String)
    case symbol(String)

    var describedForError: String {
        switch self {
        case .number(let value): String(value)
        case .text(let value): "\"\(value)\""
        case .field(let name): "{\(name)}"
        case .identifier(let name): name
        case .symbol(let symbol): symbol
        }
    }
}

/// Turns the typed line into tokens.
///
/// The lexer is the sandbox's first wall: there is no character sequence it
/// accepts that names a file, a host or anything outside the expression, so
/// nothing downstream has to decide whether a name is safe.
struct FormulaLexer {
    static let maximumLength = 2_000
    static let maximumTokens = 600

    static func tokenize(_ source: String) throws -> [FormulaToken] {
        guard source.count <= maximumLength else {
            throw FormulaError.tooLong(limit: maximumLength)
        }

        var tokens: [FormulaToken] = []
        let characters = Array(source)
        var index = 0

        while index < characters.count {
            guard tokens.count < maximumTokens else { throw FormulaError.tooComplex }
            let character = characters[index]

            if character.isWhitespace {
                index += 1
                continue
            }

            if character.isNumber || (character == "." && index + 1 < characters.count && characters[index + 1].isNumber) {
                var digits = ""
                var seenPoint = false
                while index < characters.count {
                    let next = characters[index]
                    if next.isNumber {
                        digits.append(next)
                    } else if next == "." && !seenPoint {
                        seenPoint = true
                        digits.append(next)
                    } else if next == "_" {
                        // A thousands separator for readability; it is not part
                        // of the number.
                    } else {
                        break
                    }
                    index += 1
                }
                guard let value = Double(digits) else {
                    throw FormulaError.unexpectedToken(digits)
                }
                tokens.append(.number(value))
                continue
            }

            if character == "\"" || character == "'" {
                let quote = character
                index += 1
                var body = ""
                var closed = false
                while index < characters.count {
                    let next = characters[index]
                    if next == "\\", index + 1 < characters.count {
                        body.append(characters[index + 1])
                        index += 2
                        continue
                    }
                    if next == quote {
                        closed = true
                        index += 1
                        break
                    }
                    body.append(next)
                    index += 1
                }
                guard closed else { throw FormulaError.unterminatedText }
                tokens.append(.text(body))
                continue
            }

            // Braces around a field name, so names with spaces in them need no
            // escaping and cannot be confused with a function.
            if character == "{" {
                index += 1
                var name = ""
                var closed = false
                while index < characters.count {
                    if characters[index] == "}" {
                        closed = true
                        index += 1
                        break
                    }
                    name.append(characters[index])
                    index += 1
                }
                guard closed else { throw FormulaError.unterminatedField }
                tokens.append(.field(name.trimmingCharacters(in: .whitespaces)))
                continue
            }

            if character.isLetter || character == "_" {
                var name = ""
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    name.append(characters[index])
                    index += 1
                }
                tokens.append(.identifier(name))
                continue
            }

            // Two-character operators first, so `<=` is never read as `<`
            // followed by something the parser then rejects.
            if index + 1 < characters.count {
                let pair = String([character, characters[index + 1]])
                if ["<=", ">=", "!=", "==", "<>"].contains(pair) {
                    tokens.append(.symbol(pair == "<>" ? "!=" : pair))
                    index += 2
                    continue
                }
            }

            if "+-*/%(),<>=".contains(character) {
                tokens.append(.symbol(String(character)))
                index += 1
                continue
            }

            throw FormulaError.unexpectedCharacter(String(character), at: index)
        }

        return tokens
    }
}

// MARK: - Syntax

indirect enum FormulaExpression: Equatable {
    case literal(FormulaValue)
    case field(String)
    case unary(String, FormulaExpression)
    case binary(String, FormulaExpression, FormulaExpression)
    case call(String, [FormulaExpression])
}

/// Recursive descent, with a depth budget.
///
/// The budget is what stops `((((((…))))))` from overflowing the stack: the
/// language has no loops and no recursion of its own, so bounded depth is
/// enough to bound the whole evaluation.
struct FormulaParser {
    static let maximumDepth = 32

    private let tokens: [FormulaToken]
    private var index = 0
    private var depth = 0

    init(tokens: [FormulaToken]) {
        self.tokens = tokens
    }

    static func parse(_ source: String) throws -> FormulaExpression {
        var parser = FormulaParser(tokens: try FormulaLexer.tokenize(source))
        let expression = try parser.parseExpression()
        guard parser.index == parser.tokens.count else {
            throw FormulaError.unexpectedToken(parser.tokens[parser.index].describedForError)
        }
        return expression
    }

    private var current: FormulaToken? {
        index < tokens.count ? tokens[index] : nil
    }

    private mutating func matchSymbol(_ candidates: [String]) -> String? {
        guard case .symbol(let symbol)? = current, candidates.contains(symbol) else { return nil }
        index += 1
        return symbol
    }

    private mutating func matchKeyword(_ candidates: [String]) -> String? {
        guard case .identifier(let name)? = current else { return nil }
        let lowered = name.lowercased()
        guard candidates.contains(lowered) else { return nil }
        index += 1
        return lowered
    }

    private mutating func descend<T>(_ body: (inout FormulaParser) throws -> T) throws -> T {
        depth += 1
        guard depth <= Self.maximumDepth else { throw FormulaError.tooComplex }
        defer { depth -= 1 }
        return try body(&self)
    }

    mutating func parseExpression() throws -> FormulaExpression {
        try descend { parser in try parser.parseOr() }
    }

    private mutating func parseOr() throws -> FormulaExpression {
        var left = try parseAnd()
        while matchKeyword(["or"]) != nil {
            left = .binary("or", left, try parseAnd())
        }
        return left
    }

    private mutating func parseAnd() throws -> FormulaExpression {
        var left = try parseComparison()
        while matchKeyword(["and"]) != nil {
            left = .binary("and", left, try parseComparison())
        }
        return left
    }

    private mutating func parseComparison() throws -> FormulaExpression {
        let left = try parseAdditive()
        guard let symbol = matchSymbol(["=", "==", "!=", "<", "<=", ">", ">="]) else { return left }
        return .binary(symbol == "==" ? "=" : symbol, left, try parseAdditive())
    }

    private mutating func parseAdditive() throws -> FormulaExpression {
        var left = try parseMultiplicative()
        while let symbol = matchSymbol(["+", "-"]) {
            left = .binary(symbol, left, try parseMultiplicative())
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> FormulaExpression {
        var left = try parseUnary()
        while let symbol = matchSymbol(["*", "/", "%"]) {
            left = .binary(symbol, left, try parseUnary())
        }
        return left
    }

    private mutating func parseUnary() throws -> FormulaExpression {
        if let symbol = matchSymbol(["-", "+"]) {
            return try descend { parser in
                .unary(symbol, try parser.parseUnary())
            }
        }
        if matchKeyword(["not"]) != nil {
            return try descend { parser in
                .unary("not", try parser.parseUnary())
            }
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> FormulaExpression {
        guard let token = current else { throw FormulaError.unexpectedEnd }

        switch token {
        case .number(let value):
            index += 1
            return .literal(.number(value))

        case .text(let value):
            index += 1
            return .literal(.text(value))

        case .field(let name):
            index += 1
            guard !name.isEmpty else { throw FormulaError.unknownField("") }
            return .field(name)

        case .identifier(let name):
            index += 1
            switch name.lowercased() {
            case "true": return .literal(.boolean(true))
            case "false": return .literal(.boolean(false))
            case "empty", "blank": return .literal(.empty)
            default: break
            }
            // Anything else followed by a bracket is a call; anything else
            // that is not is a bare word, which the language has no meaning
            // for. Saying so beats guessing it was a field.
            guard matchSymbol(["("]) != nil else {
                throw FormulaError.unknownFunction(name)
            }
            var arguments: [FormulaExpression] = []
            if matchSymbol([")"]) == nil {
                repeat {
                    arguments.append(try descend { parser in try parser.parseOr() })
                } while matchSymbol([","]) != nil
                guard matchSymbol([")"]) != nil else { throw FormulaError.unexpectedEnd }
            }
            return .call(name.lowercased(), arguments)

        case .symbol("("):
            index += 1
            let inner = try descend { parser in try parser.parseOr() }
            guard matchSymbol([")"]) != nil else { throw FormulaError.unexpectedEnd }
            return inner

        case .symbol(let symbol):
            throw FormulaError.unexpectedToken(symbol)
        }
    }
}

// MARK: - Evaluation

/// Where a formula's field values come from.
///
/// A protocol rather than a dictionary so the store can fetch lazily and can
/// refuse a field that would send the evaluation round in a circle.
public protocol FormulaContext {
    func value(forField name: String) throws -> FormulaValue
    var now: Date { get }
    var calendar: Calendar { get }
}

/// A plain dictionary of values — what the tests use, and what a preview of a
/// formula being typed uses before it is attached to a card.
public struct DictionaryFormulaContext: FormulaContext {
    public var values: [String: FormulaValue]
    public var now: Date
    public var calendar: Calendar

    public init(values: [String: FormulaValue], now: Date = Date(), calendar: Calendar = .current) {
        self.values = values
        self.now = now
        self.calendar = calendar
    }

    public func value(forField name: String) throws -> FormulaValue {
        // Case-insensitive, because the person typing a formula is reading the
        // field name off a label, not out of the database.
        if let exact = values[name] { return exact }
        let lowered = name.lowercased()
        for (key, value) in values where key.lowercased() == lowered { return value }
        throw FormulaError.unknownField(name)
    }
}

/// Works out what a formula says, and nothing else.
///
/// The evaluator can read the values its context hands it and can do
/// arithmetic. It has no way to reach a file, a process, the network or the
/// database: the language has no statement that names any of them, there is
/// no escape hatch to Swift, and the only outside thing it can touch is
/// `FormulaContext`. The step budget below bounds how long it can run.
public struct FormulaEvaluator {
    public static let maximumSteps = 10_000

    private let context: any FormulaContext
    private var steps = 0

    public init(context: any FormulaContext) {
        self.context = context
    }

    /// Parse and evaluate in one go.
    public static func evaluate(_ source: String, context: any FormulaContext) throws -> FormulaValue {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let expression = try FormulaParser.parse(trimmed)
        var evaluator = FormulaEvaluator(context: context)
        return try evaluator.evaluate(expression)
    }

    /// Check a formula without needing any values — used while it is being
    /// typed, so a mistake is reported before it is saved onto every card.
    public static func validate(_ source: String) throws {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try FormulaParser.parse(trimmed)
    }

    /// Every field name a formula reads, in the order it first reads them.
    /// The store uses this to spot a formula that depends on itself.
    public static func fieldNames(in source: String) throws -> [String] {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var names: [String] = []
        collect(try FormulaParser.parse(trimmed), into: &names)
        return names
    }

    private static func collect(_ expression: FormulaExpression, into names: inout [String]) {
        switch expression {
        case .literal:
            break
        case .field(let name):
            if !names.contains(where: { $0.lowercased() == name.lowercased() }) { names.append(name) }
        case .unary(_, let operand):
            collect(operand, into: &names)
        case .binary(_, let left, let right):
            collect(left, into: &names)
            collect(right, into: &names)
        case .call(_, let arguments):
            for argument in arguments { collect(argument, into: &names) }
        }
    }

    mutating func evaluate(_ expression: FormulaExpression) throws -> FormulaValue {
        steps += 1
        guard steps <= Self.maximumSteps else { throw FormulaError.tooComplex }

        switch expression {
        case .literal(let value):
            return value

        case .field(let name):
            return try context.value(forField: name)

        case .unary(let symbol, let operand):
            return try applyUnary(symbol, to: try evaluate(operand))

        case .binary(let symbol, let left, let right):
            // `and` and `or` stop early, so `isempty({A}) or {A} > 3` does not
            // have to evaluate the comparison it is guarding against.
            if symbol == "and" || symbol == "or" {
                let leftValue = try evaluate(left)
                let leftTruth = truth(of: leftValue)
                if symbol == "and" && leftTruth == false { return .boolean(false) }
                if symbol == "or" && leftTruth == true { return .boolean(true) }
                return .boolean(truth(of: try evaluate(right)) ?? false)
            }
            return try applyBinary(symbol, try evaluate(left), try evaluate(right))

        case .call(let name, let arguments):
            return try applyFunction(name, arguments)
        }
    }

    // MARK: Operators

    private func applyUnary(_ symbol: String, to value: FormulaValue) throws -> FormulaValue {
        switch symbol {
        case "+":
            return value
        case "-":
            if case .empty = value { return .empty }
            guard case .number(let number) = value else {
                throw FormulaError.typeMismatch("Only a number can be negative.")
            }
            return .number(-number)
        case "not":
            if case .empty = value { return .empty }
            return .boolean(!(truth(of: value) ?? false))
        default:
            throw FormulaError.unexpectedToken(symbol)
        }
    }

    private func applyBinary(_ symbol: String, _ left: FormulaValue, _ right: FormulaValue) throws -> FormulaValue {
        if ["=", "!="].contains(symbol) {
            let same = compareForEquality(left, right)
            return .boolean(symbol == "=" ? same : !same)
        }

        // A missing value spreads rather than standing in for zero: a formula
        // over a field nobody filled in reads as blank, which is the truth,
        // instead of as a number somebody might act on.
        if left.isEmpty || right.isEmpty {
            return [ "<", "<=", ">", ">=" ].contains(symbol) ? .boolean(false) : .empty
        }

        if ["<", "<=", ">", ">="].contains(symbol) {
            return .boolean(try compare(symbol, left, right))
        }

        switch (symbol, left, right) {
        case ("+", .number(let a), .number(let b)):
            return .number(a + b)
        case ("-", .number(let a), .number(let b)):
            return .number(a - b)
        case ("*", .number(let a), .number(let b)):
            return .number(a * b)

        case ("/", .number(let a), .number(let b)):
            guard b != 0 else { throw FormulaError.divisionByZero }
            return .number(a / b)
        case ("%", .number(let a), .number(let b)):
            guard b != 0 else { throw FormulaError.divisionByZero }
            return .number(a.truncatingRemainder(dividingBy: b))

        // Text joins to text and to nothing else. `"Total: " + {Points}` is
        // almost certainly a mistake about which one is a number, so it is
        // refused rather than quietly stringified; `concat` is there for when
        // it is meant.
        case ("+", .text(let a), .text(let b)):
            return .text(a + b)

        // A date minus a date is how far apart they are, in days. A date plus
        // a number moves it that many days.
        case ("-", .date(let a), .date(let b)):
            return .number(a.timeIntervalSince(b) / 86_400)
        case ("+", .date(let date), .number(let days)),
             ("+", .number(let days), .date(let date)):
            return .date(date.addingTimeInterval(days * 86_400))
        case ("-", .date(let date), .number(let days)):
            return .date(date.addingTimeInterval(-days * 86_400))

        default:
            throw FormulaError.typeMismatch("Can't work out \(describe(left)) \(symbol) \(describe(right)).")
        }
    }

    private func compare(_ symbol: String, _ left: FormulaValue, _ right: FormulaValue) throws -> Bool {
        let ordering: Int
        switch (left, right) {
        case (.number(let a), .number(let b)):
            ordering = a < b ? -1 : (a == b ? 0 : 1)
        case (.date(let a), .date(let b)):
            ordering = a < b ? -1 : (a == b ? 0 : 1)
        case (.text(let a), .text(let b)):
            ordering = a < b ? -1 : (a == b ? 0 : 1)
        case (.boolean(let a), .boolean(let b)):
            let x = a ? 1 : 0, y = b ? 1 : 0
            ordering = x < y ? -1 : (x == y ? 0 : 1)
        default:
            throw FormulaError.typeMismatch("Can't compare \(describe(left)) with \(describe(right)).")
        }

        switch symbol {
        case "<": return ordering < 0
        case "<=": return ordering <= 0
        case ">": return ordering > 0
        default: return ordering >= 0
        }
    }

    private func compareForEquality(_ left: FormulaValue, _ right: FormulaValue) -> Bool {
        if case .number(let a) = left, case .number(let b) = right {
            // Two values that arrived by different arithmetic should still
            // count as the same number.
            return abs(a - b) < 1e-9
        }
        return left == right
    }

    private func truth(of value: FormulaValue) -> Bool? {
        switch value {
        case .boolean(let value): value
        case .number(let value): value != 0
        case .text(let value): !value.isEmpty
        case .date: true
        case .empty: nil
        }
    }

    private func describe(_ value: FormulaValue) -> String {
        switch value {
        case .number: "a number"
        case .text: "text"
        case .date: "a date"
        case .boolean: "yes/no"
        case .empty: "nothing"
        }
    }

    // MARK: Functions

    private mutating func applyFunction(_ name: String, _ arguments: [FormulaExpression]) throws -> FormulaValue {
        // `if` decides which branch to evaluate, so the branch not taken can
        // safely contain something that would fail — a division by a field
        // that is zero in exactly the case the condition is guarding.
        if name == "if" {
            guard arguments.count == 3 else {
                throw FormulaError.wrongArgumentCount(function: "if", expected: "3 arguments", got: arguments.count)
            }
            let condition = try evaluate(arguments[0])
            return try evaluate(truth(of: condition) == true ? arguments[1] : arguments[2])
        }

        if name == "coalesce" {
            guard !arguments.isEmpty else {
                throw FormulaError.wrongArgumentCount(function: "coalesce", expected: "at least 1 argument", got: 0)
            }
            for argument in arguments {
                let value = try evaluate(argument)
                if !value.isEmpty { return value }
            }
            return .empty
        }

        var values: [FormulaValue] = []
        values.reserveCapacity(arguments.count)
        for argument in arguments { values.append(try evaluate(argument)) }

        func expect(_ count: Int, _ described: String) throws {
            guard values.count == count else {
                throw FormulaError.wrongArgumentCount(function: name, expected: described, got: values.count)
            }
        }

        func number(_ index: Int) throws -> Double {
            guard case .number(let value) = values[index] else {
                throw FormulaError.typeMismatch("\(name) needs a number.")
            }
            return value
        }

        func date(_ index: Int) throws -> Date {
            guard case .date(let value) = values[index] else {
                throw FormulaError.typeMismatch("\(name) needs a date.")
            }
            return value
        }

        func string(_ index: Int) throws -> String {
            switch values[index] {
            case .text(let value): return value
            case .empty: return ""
            default: throw FormulaError.typeMismatch("\(name) needs text.")
            }
        }

        /// Most functions have nothing to say about a missing value, and
        /// saying nothing is better than inventing a zero.
        func propagatesEmpty() -> FormulaValue? {
            values.contains(where: \.isEmpty) ? .empty : nil
        }

        switch name {
        case "isempty", "isblank":
            try expect(1, "1 argument")
            return .boolean(values[0].isEmpty)

        case "abs":
            try expect(1, "1 argument")
            if let empty = propagatesEmpty() { return empty }
            return .number(abs(try number(0)))

        case "round":
            guard values.count == 1 || values.count == 2 else {
                throw FormulaError.wrongArgumentCount(function: "round", expected: "1 or 2 arguments", got: values.count)
            }
            if let empty = propagatesEmpty() { return empty }
            let value = try number(0)
            let places = values.count == 2 ? try number(1) : 0
            let factor = pow(10, min(max(places.rounded(), 0), 9))
            return .number((value * factor).rounded() / factor)

        case "floor":
            try expect(1, "1 argument")
            if let empty = propagatesEmpty() { return empty }
            return .number(try number(0).rounded(.down))

        case "ceiling", "ceil":
            try expect(1, "1 argument")
            if let empty = propagatesEmpty() { return empty }
            return .number(try number(0).rounded(.up))

        case "sqrt":
            try expect(1, "1 argument")
            if let empty = propagatesEmpty() { return empty }
            let value = try number(0)
            guard value >= 0 else { throw FormulaError.typeMismatch("sqrt needs a number that isn't negative.") }
            return .number(value.squareRoot())

        case "power", "pow":
            try expect(2, "2 arguments")
            if let empty = propagatesEmpty() { return empty }
            // Bounded, because an unbounded exponent is the one piece of
            // arithmetic here that can cost real time.
            let exponent = try number(1)
            guard abs(exponent) <= 64 else {
                throw FormulaError.typeMismatch("The exponent has to be between -64 and 64.")
            }
            return .number(pow(try number(0), exponent))

        case "min", "max", "sum", "average", "avg":
            let numbers = try values.compactMap { value -> Double? in
                switch value {
                case .number(let number): return number
                case .empty: return nil
                default: throw FormulaError.typeMismatch("\(name) needs numbers.")
                }
            }
            guard !numbers.isEmpty else { return .empty }
            switch name {
            case "min": return .number(numbers.min() ?? 0)
            case "max": return .number(numbers.max() ?? 0)
            case "sum": return .number(numbers.reduce(0, +))
            default: return .number(numbers.reduce(0, +) / Double(numbers.count))
            }

        case "count":
            return .number(Double(values.filter { !$0.isEmpty }.count))

        case "now":
            try expect(0, "no arguments")
            return .date(context.now)

        case "today":
            try expect(0, "no arguments")
            return .date(context.calendar.startOfDay(for: context.now))

        case "days":
            try expect(2, "2 arguments")
            if let empty = propagatesEmpty() { return empty }
            // Whole days between two dates, counted on the calendar rather
            // than by dividing seconds: across a daylight-saving change the
            // second answer is off by a fraction and rounds the wrong way.
            let start = context.calendar.startOfDay(for: try date(1))
            let end = context.calendar.startOfDay(for: try date(0))
            let components = context.calendar.dateComponents([.day], from: start, to: end)
            return .number(Double(components.day ?? 0))

        case "dateadd":
            try expect(2, "2 arguments")
            if let empty = propagatesEmpty() { return empty }
            guard let moved = context.calendar.date(byAdding: .day, value: Int(try number(1).rounded()), to: try date(0)) else {
                throw FormulaError.typeMismatch("That date can't be moved that far.")
            }
            return .date(moved)

        case "year", "month", "day", "weekday":
            try expect(1, "1 argument")
            if let empty = propagatesEmpty() { return empty }
            let components = context.calendar.dateComponents([.year, .month, .day, .weekday], from: try date(0))
            switch name {
            case "year": return .number(Double(components.year ?? 0))
            case "month": return .number(Double(components.month ?? 0))
            case "day": return .number(Double(components.day ?? 0))
            default: return .number(Double(components.weekday ?? 0))
            }

        case "concat":
            var joined = ""
            for value in values { joined += value.display() }
            return .text(joined)

        case "text":
            try expect(1, "1 argument")
            return .text(values[0].display())

        case "number":
            try expect(1, "1 argument")
            switch values[0] {
            case .number(let value): return .number(value)
            case .boolean(let value): return .number(value ? 1 : 0)
            case .text(let value):
                guard let parsed = Double(value.trimmingCharacters(in: .whitespaces)) else { return .empty }
                return .number(parsed)
            default: return .empty
            }

        case "length", "len":
            try expect(1, "1 argument")
            if let empty = propagatesEmpty() { return empty }
            return .number(Double(try string(0).count))

        case "upper":
            try expect(1, "1 argument")
            if let empty = propagatesEmpty() { return empty }
            return .text(try string(0).uppercased())

        case "lower":
            try expect(1, "1 argument")
            if let empty = propagatesEmpty() { return empty }
            return .text(try string(0).lowercased())

        case "contains":
            try expect(2, "2 arguments")
            if let empty = propagatesEmpty() { return .boolean(false) }
            return .boolean(try string(0).lowercased().contains(try string(1).lowercased()))

        default:
            throw FormulaError.unknownFunction(name)
        }
    }
}
