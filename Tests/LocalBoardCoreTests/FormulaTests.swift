import Foundation
import Testing
@testable import LocalBoardCore

/// A fixed calendar, so a formula that does date arithmetic is tested against
/// a rule rather than against the machine it happens to run on.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ text: String) -> Date {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
}

private func context(
    _ values: [String: FormulaValue] = [:],
    now: Date = day("2026-06-15")
) -> DictionaryFormulaContext {
    DictionaryFormulaContext(values: values, now: now, calendar: utc)
}

private func evaluate(_ source: String, _ values: [String: FormulaValue] = [:]) throws -> FormulaValue {
    try FormulaEvaluator.evaluate(source, context: context(values))
}

private func number(_ source: String, _ values: [String: FormulaValue] = [:]) throws -> Double? {
    guard case .number(let value) = try evaluate(source, values) else { return nil }
    return value
}

@Suite("Arithmetic")
struct FormulaArithmeticTests {

    @Test("The four operations, and what they do to a decimal")
    func basics() throws {
        #expect(try number("2 + 3") == 5)
        #expect(try number("10 - 4") == 6)
        #expect(try number("6 * 7") == 42)
        #expect(try number("9 / 2") == 4.5)
        #expect(try number("7 % 3") == 1)
        #expect(try number("1.5 + 1.25") == 2.75)
    }

    @Test("Multiplication binds tighter than addition, and brackets beat both")
    func precedence() throws {
        #expect(try number("2 + 3 * 4") == 14)
        #expect(try number("(2 + 3) * 4") == 20)
        #expect(try number("-2 + 3") == 1)
        #expect(try number("10 - 3 - 2") == 5)
        #expect(try number("100 / 5 / 2") == 10)
    }

    @Test("Dividing by zero is refused rather than returning infinity")
    func divisionByZero() {
        // Infinity would propagate silently into every figure downstream and
        // draw as something nobody can act on.
        #expect(throws: FormulaError.divisionByZero) { try evaluate("5 / 0") }
        #expect(throws: FormulaError.divisionByZero) { try evaluate("5 % 0") }
    }

    @Test("A field stands in for its value")
    func fields() throws {
        let values: [String: FormulaValue] = ["Points": .number(8), "Done": .number(3)]
        #expect(try number("{Points} - {Done}", values) == 5)
        #expect(try number("{Done} / {Points} * 100", values) == 37.5)
    }

    @Test("Field names are matched however they are capitalised")
    func caseInsensitiveFields() throws {
        #expect(try number("{points} + {POINTS}", ["Points": .number(2)]) == 4)
    }

    @Test("A name that matches nothing is named, not ignored")
    func unknownField() {
        #expect(throws: FormulaError.unknownField("Nope")) { try evaluate("{Nope} + 1") }
    }
}

@Suite("What a blank field does to a formula")
struct FormulaEmptyTests {

    @Test("Arithmetic over a blank field is blank, not zero")
    func emptySpreads() throws {
        // Zero is a number somebody might act on. Blank is the truth.
        #expect(try evaluate("{A} + 1", ["A": .empty]) == .empty)
        #expect(try evaluate("{A} * 100", ["A": .empty]) == .empty)
        #expect(try evaluate("-{A}", ["A": .empty]) == .empty)
    }

    @Test("A comparison against a blank field is false rather than blank")
    func emptyComparison() throws {
        #expect(try evaluate("{A} > 3", ["A": .empty]) == .boolean(false))
        #expect(try evaluate("{A} < 3", ["A": .empty]) == .boolean(false))
    }

    @Test("isempty and coalesce are how you say what blank should mean")
    func handlingEmpty() throws {
        #expect(try evaluate("isempty({A})", ["A": .empty]) == .boolean(true))
        #expect(try evaluate("isempty({A})", ["A": .number(0)]) == .boolean(false))
        #expect(try number("coalesce({A}, {B}, 99)", ["A": .empty, "B": .empty]) == 99)
        #expect(try number("coalesce({A}, 99)", ["A": .number(7)]) == 7)
        #expect(try number("if(isempty({A}), 0, {A}) + 5", ["A": .empty]) == 5)
    }

    @Test("An average ignores the blanks rather than counting them as zero")
    func averageSkipsEmpty() throws {
        #expect(try number("average(4, {A}, 8)", ["A": .empty]) == 6)
        #expect(try evaluate("average({A})", ["A": .empty]) == .empty)
    }
}

@Suite("Dates in a formula")
struct FormulaDateTests {

    @Test("One date minus another is how many days apart they are")
    func difference() throws {
        let values: [String: FormulaValue] = [
            "Start": .date(day("2026-06-01")),
            "Due": .date(day("2026-06-15")),
        ]
        #expect(try number("{Due} - {Start}", values) == 14)
        #expect(try number("{Start} - {Due}", values) == -14)
    }

    @Test("A date plus a number moves it that many days, either way round")
    func shifting() throws {
        let values: [String: FormulaValue] = ["Start": .date(day("2026-06-01"))]
        #expect(try evaluate("{Start} + 10", values) == .date(day("2026-06-11")))
        #expect(try evaluate("10 + {Start}", values) == .date(day("2026-06-11")))
        #expect(try evaluate("{Start} - 1", values) == .date(day("2026-05-31")))
    }

    @Test("days() counts whole calendar days, and today() is midnight")
    func calendarDays() throws {
        let values: [String: FormulaValue] = [
            "Due": .date(day("2026-06-20")),
        ]
        #expect(try number("days({Due}, today())", values) == 5)
        #expect(try evaluate("today()") == .date(day("2026-06-15")))
    }

    @Test("A date can be taken apart")
    func components() throws {
        let values: [String: FormulaValue] = ["D": .date(day("2026-03-09"))]
        #expect(try number("year({D})", values) == 2026)
        #expect(try number("month({D})", values) == 3)
        #expect(try number("day({D})", values) == 9)
    }

    @Test("Overdue by how many days, written the way somebody would write it")
    func realisticFormula() throws {
        let values: [String: FormulaValue] = ["Due": .date(day("2026-06-10"))]
        // The formula a person actually types: days late, or nothing if not.
        let source = "if({Due} < today(), days(today(), {Due}), 0)"
        #expect(try number(source, values) == 5)
        #expect(try number(source, ["Due": .date(day("2026-06-20"))]) == 0)
    }
}

@Suite("Text, comparison and choosing")
struct FormulaTextTests {

    @Test("Text joins to text, and refuses to join to a number")
    func joining() throws {
        #expect(try evaluate("\"a\" + \"b\"") == .text("ab"))
        // Almost always a mistake about which of the two is a number, so it is
        // refused rather than quietly stringified.
        #expect(throws: (any Error).self) { try evaluate("\"Total: \" + 5") }
        #expect(try evaluate("concat(\"Total: \", 5)") == .text("Total: 5"))
    }

    @Test("The text functions")
    func functions() throws {
        #expect(try evaluate("upper(\"abc\")") == .text("ABC"))
        #expect(try evaluate("lower(\"ABC\")") == .text("abc"))
        #expect(try number("len(\"hello\")") == 5)
        #expect(try evaluate("contains(\"Hello World\", \"world\")") == .boolean(true))
        #expect(try evaluate("contains(\"Hello\", \"z\")") == .boolean(false))
    }

    @Test("Comparisons, and the ways of writing equals")
    func comparison() throws {
        #expect(try evaluate("3 > 2") == .boolean(true))
        #expect(try evaluate("3 >= 3") == .boolean(true))
        #expect(try evaluate("2 = 2") == .boolean(true))
        #expect(try evaluate("2 == 2") == .boolean(true))
        #expect(try evaluate("2 != 3") == .boolean(true))
        #expect(try evaluate("2 <> 3") == .boolean(true))
    }

    @Test("Two numbers that arrived by different arithmetic still compare equal")
    func floatingPointEquality() throws {
        // 0.1 + 0.2 is not 0.3 in binary, and a formula that said so would be
        // right about the hardware and wrong about the question.
        #expect(try evaluate("0.1 + 0.2 = 0.3") == .boolean(true))
    }

    @Test("if picks a branch, and only evaluates the one it picked")
    func branching() throws {
        #expect(try number("if(true, 1, 2)") == 1)
        #expect(try number("if(false, 1, 2)") == 2)
        // The branch not taken may contain something that would fail — which
        // is exactly what guarding against a zero looks like.
        #expect(try number("if({N} = 0, 0, 100 / {N})", ["N": .number(0)]) == 0)
    }

    @Test("and and or stop as soon as the answer is known")
    func shortCircuit() throws {
        #expect(try evaluate("false and (1 / 0) > 1") == .boolean(false))
        #expect(try evaluate("true or (1 / 0) > 1") == .boolean(true))
    }

    @Test("Rounding, and rounding to places")
    func rounding() throws {
        #expect(try number("round(2.4)") == 2)
        #expect(try number("round(2.5)") == 3)
        #expect(try number("round(3.14159, 2)") == 3.14)
        #expect(try number("floor(2.9)") == 2)
        #expect(try number("ceiling(2.1)") == 3)
        #expect(try number("abs(0 - 7)") == 7)
    }
}

@Suite("What the formula language refuses")
struct FormulaSafetyTests {

    @Test("A bare word is not a field, and says so")
    func bareWord() {
        // Guessing that `total` meant `{Total}` would make a typo in a field
        // name read as a working formula over the wrong thing.
        #expect(throws: FormulaError.unknownFunction("total")) { try evaluate("total + 1") }
    }

    @Test("A function nobody has heard of is named")
    func unknownFunction() {
        #expect(throws: FormulaError.unknownFunction("system")) { try evaluate("system(\"ls\")") }
        #expect(throws: FormulaError.unknownFunction("import")) { try evaluate("import(\"x\")") }
    }

    @Test("A function called with the wrong number of arguments is refused")
    func argumentCount() {
        #expect(throws: (any Error).self) { try evaluate("if(true, 1)") }
        #expect(throws: (any Error).self) { try evaluate("today(5)") }
        #expect(throws: (any Error).self) { try evaluate("len(\"a\", \"b\")") }
    }

    @Test("Unfinished text and unfinished field names are caught")
    func unterminated() {
        #expect(throws: FormulaError.unterminatedText) { try evaluate("\"abc") }
        #expect(throws: FormulaError.unterminatedField) { try evaluate("{Points + 1") }
    }

    @Test("A formula longer than the limit is refused before it is parsed")
    func lengthLimit() {
        let long = String(repeating: "1 + ", count: 600) + "1"
        #expect(throws: (any Error).self) { try evaluate(long) }
    }

    @Test("Deep nesting stops rather than running out of stack")
    func depthLimit() {
        // The language has no loops, so bounding depth bounds the whole
        // evaluation. Without this, a line of brackets is a crash.
        let nested = String(repeating: "(", count: 200) + "1" + String(repeating: ")", count: 200)
        #expect(throws: FormulaError.tooComplex) { try evaluate(nested) }
    }

    @Test("An exponent is bounded")
    func exponentBound() throws {
        #expect(try number("power(2, 10)") == 1024)
        #expect(throws: (any Error).self) { try evaluate("power(9, 10000)") }
    }

    @Test("Characters the language has no meaning for are rejected")
    func strayCharacters() {
        for source in ["1 $ 2", "1 & 2", "a[0]", "1; 2", "`ls`"] {
            #expect(throws: (any Error).self, "\(source) should not parse") {
                try evaluate(source)
            }
        }
    }

    @Test("Trailing rubbish after a complete expression is refused")
    func trailing() {
        #expect(throws: (any Error).self) { try evaluate("1 + 1 2") }
        #expect(throws: (any Error).self) { try evaluate("1 + 1)") }
    }

    @Test("An empty formula is blank rather than an error")
    func blank() throws {
        #expect(try evaluate("") == .empty)
        #expect(try evaluate("   ") == .empty)
    }

    @Test("Validating says whether it parses without needing any values")
    func validation() throws {
        try FormulaEvaluator.validate("{Anything} * 2")
        #expect(throws: (any Error).self) { try FormulaEvaluator.validate("{Anything} *") }
    }

    @Test("The field names a formula reads can be listed, for spotting cycles")
    func fieldNames() throws {
        let names = try FormulaEvaluator.fieldNames(in: "{Points} + {Spent} - {Points}")
        #expect(names == ["Points", "Spent"])
        #expect(try FormulaEvaluator.fieldNames(in: "1 + 1").isEmpty)
    }

    @Test("Every error carries a sentence a person can act on")
    func messages() {
        #expect(FormulaError.divisionByZero.message.contains("zero"))
        #expect(FormulaError.unknownField("Size").message.contains("Size"))
        #expect(FormulaError.circularReference("Total").message.contains("itself"))
    }
}
