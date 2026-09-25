import Foundation
import LocalBoardCore

/// The fields nobody fills in: formulas, rollups, and progress counted off
/// the subtasks or the checklist.
///
/// These are worked out when a card is read and never written down. Storing
/// them would mean every edit anywhere had to find and update every field
/// that might have been reading it — and the first one that was missed would
/// be a figure on screen that is quietly wrong. Reading them costs a few
/// queries per project instead, which is the trade this makes deliberately.
public struct ComputedFieldRepository {

    let database: Database
    private let clock: any ClockProvider
    private let calendar: Calendar

    public init(database: Database, clock: any ClockProvider = SystemClock(), calendar: Calendar = .current) {
        self.database = database
        self.clock = clock
        self.calendar = calendar
    }

    /// Every computed field, for every card in a project.
    ///
    /// One pass over the project rather than one query per card: a board of a
    /// thousand cards with a formula on it would otherwise be a thousand
    /// round trips before the first column is drawn.
    public func values(inProject projectID: String) throws -> [String: [String: FormulaValue]] {
        let fields = try CustomFieldRepository(database: database).fields(inProject: projectID)
        let computed = fields.filter { $0.kind.isComputed || ($0.kind == .progress && $0.progressMode != .manual) }
        guard !computed.isEmpty else { return [:] }

        let source = try loadSource(projectID: projectID, fields: fields)
        var byTask: [String: [String: FormulaValue]] = [:]

        for taskID in source.taskIDs {
            var resolver = FieldResolver(source: source, now: clock.now, calendar: calendar)
            var results: [String: FormulaValue] = [:]
            for field in computed {
                results[field.id] = resolver.value(of: field, for: taskID)
            }
            if !results.isEmpty { byTask[taskID] = results }
        }

        return byTask
    }

    /// The same for one card, when only one is on screen.
    public func values(forTask taskID: String, inProject projectID: String) throws -> [String: FormulaValue] {
        try values(inProject: projectID)[taskID] ?? [:]
    }

    /// Tries a formula against one real card, so the person writing it sees
    /// what it will say before it is saved onto every card in the project.
    public func preview(formula: String, forTask taskID: String, inProject projectID: String) throws -> Result<FormulaValue, FormulaError> {
        let fields = try CustomFieldRepository(database: database).fields(inProject: projectID)
        let source = try loadSource(projectID: projectID, fields: fields)
        var resolver = FieldResolver(source: source, now: clock.now, calendar: calendar)
        do {
            return .success(try resolver.evaluate(formula: formula, for: taskID, visiting: []))
        } catch let error as FormulaError {
            return .failure(error)
        }
    }

    // MARK: - Everything the evaluation needs, read once

    struct Source {
        var taskIDs: [String] = []
        var fieldsByID: [String: CustomField] = [:]
        var fieldsByName: [String: CustomField] = [:]
        var stored: [String: [String: CustomFieldValue]] = [:]
        var builtIn: [String: [String: FormulaValue]] = [:]
        /// parent id → (done, total)
        var subtaskCounts: [String: (done: Int, total: Int)] = [:]
        var subtaskIDs: [String: [String]] = [:]
        var checklistCounts: [String: (done: Int, total: Int)] = [:]
    }

    private func loadSource(projectID: String, fields: [CustomField]) throws -> Source {
        var source = Source()

        for field in fields {
            source.fieldsByID[field.id] = field
            source.fieldsByName[field.name.lowercased()] = field
        }

        // The card's own columns, offered to formulas under the names they are
        // labelled with on screen rather than their column names.
        try database.forEachRow(
            """
            SELECT task.id, task.title, task.priority, task.estimate, task.start_date,
                   task.due_date, task.created_at, task.completed_at,
                   COALESCE((SELECT SUM(minutes) FROM work_log WHERE work_log.task_id = task.id), 0) AS logged
            FROM task WHERE task.project_id = ? AND task.trashed = 0;
            """,
            [projectID]
        ) { row in
            let id = try row.requiredString("id")
            source.taskIDs.append(id)
            var values: [String: FormulaValue] = [:]
            values["title"] = .text(row.string("title") ?? "")
            values["priority"] = .number(Double(row.int("priority") ?? 0))
            if let estimate = row.double("estimate") { values["estimate"] = .number(estimate) }
            if let start = row.date("start_date") { values["start"] = .date(start) }
            if let due = row.date("due_date") { values["due"] = .date(due) }
            if let created = row.date("created_at") { values["created"] = .date(created) }
            if let completed = row.date("completed_at") {
                values["completed"] = .date(completed)
                values["done"] = .boolean(true)
            } else {
                values["done"] = .boolean(false)
            }
            values["logged"] = .number(Double(row.int("logged") ?? 0))
            source.builtIn[id] = values
        }

        source.stored = try CustomFieldRepository(database: database).valuesByTask(inProject: projectID)

        try database.forEachRow(
            """
            SELECT parent_id, id, completed_at FROM task
            WHERE project_id = ? AND parent_id IS NOT NULL AND trashed = 0;
            """,
            [projectID]
        ) { row in
            let parent = try row.requiredString("parent_id")
            var counts = source.subtaskCounts[parent] ?? (0, 0)
            counts.total += 1
            if row.date("completed_at") != nil { counts.done += 1 }
            source.subtaskCounts[parent] = counts
            source.subtaskIDs[parent, default: []].append(try row.requiredString("id"))
        }

        try database.forEachRow(
            """
            SELECT checklist_item.task_id, checklist_item.done FROM checklist_item
            JOIN task ON task.id = checklist_item.task_id
            WHERE task.project_id = ?;
            """,
            [projectID]
        ) { row in
            let taskID = try row.requiredString("task_id")
            var counts = source.checklistCounts[taskID] ?? (0, 0)
            counts.total += 1
            if row.bool("done") == true { counts.done += 1 }
            source.checklistCounts[taskID] = counts
        }

        return source
    }
}

// MARK: - Working one card out

/// Resolves one card's fields, computed ones included.
///
/// It carries the set of fields it is already in the middle of working out, so
/// a formula that ends up reading itself is reported as a circular reference
/// rather than running until the stack gives out.
struct FieldResolver {
    let source: ComputedFieldRepository.Source
    let now: Date
    let calendar: Calendar

    var cache: [String: FormulaValue] = [:]

    init(source: ComputedFieldRepository.Source, now: Date, calendar: Calendar) {
        self.source = source
        self.now = now
        self.calendar = calendar
    }

    /// The value of one field on one card, or `.empty` if it cannot be worked
    /// out. A broken formula reads as blank on the card and says why in the
    /// field's own settings — a card is not the place to shout about it.
    mutating func value(of field: CustomField, for taskID: String) -> FormulaValue {
        (try? resolve(field: field, for: taskID, visiting: [])) ?? .empty
    }

    mutating func evaluate(formula: String, for taskID: String, visiting: Set<String>) throws -> FormulaValue {
        let context = CardFormulaContext(taskID: taskID, visiting: visiting, resolver: self, now: now, calendar: calendar)
        let value = try FormulaEvaluator.evaluate(formula, context: context)
        // The context may have resolved fields of its own; keep what it learnt.
        cache.merge(context.resolver.cache) { _, new in new }
        return value
    }

    mutating func resolve(field: CustomField, for taskID: String, visiting: Set<String>) throws -> FormulaValue {
        let key = "\(taskID)|\(field.id)"
        if let cached = cache[key] { return cached }
        guard !visiting.contains(field.id) else {
            throw FormulaError.circularReference(field.name)
        }

        let value = try compute(field: field, for: taskID, visiting: visiting.union([field.id]))
        cache[key] = value
        return value
    }

    private mutating func compute(field: CustomField, for taskID: String, visiting: Set<String>) throws -> FormulaValue {
        switch field.kind {
        case .formula:
            return try evaluate(formula: field.formula, for: taskID, visiting: visiting)

        case .rollup:
            return try rollup(field: field, for: taskID, visiting: visiting)

        case .progress where field.progressMode != .manual:
            let counts = field.progressMode == .subtasks
                ? source.subtaskCounts[taskID]
                : source.checklistCounts[taskID]
            guard let counts, let percentage = ProgressMode.percentage(done: counts.done, of: counts.total) else {
                return .empty
            }
            return .number(percentage)

        default:
            return stored(field: field, for: taskID)
        }
    }

    private func stored(field: CustomField, for taskID: String) -> FormulaValue {
        guard let value = source.stored[taskID]?[field.id] else { return .empty }
        switch value {
        case .text(let text), .choice(let text):
            return .text(text)
        case .number(let number):
            return .number(number)
        case .date(let date):
            return .date(date)
        case .checkbox(let ticked):
            return .boolean(ticked)
        }
    }

    private mutating func rollup(field: CustomField, for taskID: String, visiting: Set<String>) throws -> FormulaValue {
        let related: [String]
        switch field.rollupSource {
        case .subtasks:
            related = source.subtaskIDs[taskID] ?? []
        case .relationship:
            guard let linkID = field.rollupLinkID, let link = source.fieldsByID[linkID] else { return .empty }
            related = RelationshipValue.ids(from: stored(field: link, for: taskID))
        }

        // No related cards is blank rather than zero — except for a count,
        // where none is a perfectly good answer.
        guard !related.isEmpty || field.rollupFunction == .count else { return .empty }

        if field.rollupFunction == .count {
            return .number(Double(related.count))
        }

        guard let targetID = field.rollupFieldID, let target = source.fieldsByID[targetID] else {
            return .empty
        }

        var gathered: [Double?] = []
        gathered.reserveCapacity(related.count)
        for id in related {
            let value = try resolve(field: target, for: id, visiting: visiting)
            if case .number(let number) = value {
                gathered.append(number)
            } else if case .boolean(let flag) = value {
                // A tickbox rolled up is how many are ticked, which is the
                // only arithmetic a yes/no supports.
                gathered.append(flag ? 1 : 0)
            } else {
                gathered.append(nil)
            }
        }

        guard let reduced = field.rollupFunction.reduce(gathered) else { return .empty }
        return .number(reduced)
    }

    fileprivate mutating func lookUp(name: String, taskID: String, visiting: Set<String>) throws -> FormulaValue {
        let lowered = name.lowercased()

        // A field the project defined wins over a built-in of the same name:
        // if somebody has made a field called Due, that is the one they mean
        // when they type `{Due}`.
        if let field = source.fieldsByName[lowered] {
            return try resolve(field: field, for: taskID, visiting: visiting)
        }

        if let value = source.builtIn[taskID]?[lowered] {
            return value
        }

        // A name that matches neither is a mistake worth naming; returning
        // blank would make a formula look as though it merely had nothing to
        // say.
        throw FormulaError.unknownField(name)
    }
}

/// How a relationship field's value is stored and read back.
///
/// Comma-separated ids in the text column, so a relationship is searchable
/// with the same `LIKE` the query language already uses for text.
public enum RelationshipValue {
    public static func stored(_ ids: [String]) -> CustomFieldValue? {
        let cleaned = ids.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return .text(cleaned.joined(separator: ","))
    }

    public static func ids(from value: CustomFieldValue?) -> [String] {
        guard case .text(let text)? = value else { return [] }
        return ids(from: FormulaValue.text(text))
    }

    static func ids(from value: FormulaValue) -> [String] {
        guard case .text(let text) = value else { return [] }
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// The bridge between a card and a formula.
///
/// It is the only thing the evaluator can reach, and all it can do is answer
/// what one field of one card holds. There is no path from here to a file, a
/// process or the database beyond the rows already read.
///
/// A class rather than a struct so that what it works out on the way through
/// is still there afterwards: a formula reading the same rollup three times
/// should compute it once.
final class CardFormulaContext: FormulaContext {
    let taskID: String
    let visiting: Set<String>
    var resolver: FieldResolver
    let now: Date
    let calendar: Calendar

    init(taskID: String, visiting: Set<String>, resolver: FieldResolver, now: Date, calendar: Calendar) {
        self.taskID = taskID
        self.visiting = visiting
        self.resolver = resolver
        self.now = now
        self.calendar = calendar
    }

    func value(forField name: String) throws -> FormulaValue {
        try resolver.lookUp(name: name, taskID: taskID, visiting: visiting)
    }
}
