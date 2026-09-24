import Foundation
import LocalBoardCore

/// Rules a project applies to its own cards.
///
/// Deliberately small: one trigger, one action, no conditions and no chains
/// anybody has to reason about. A rule engine that can express anything is a
/// second programming language inside the app, and this is a Kanban board.
///
/// Rules run *after* the change that triggered them, inside the same
/// transaction, so a card never briefly exists in the state the rule was meant
/// to prevent. They are capped at one level of cascade: a rule may fire
/// because of a user's action, but a rule set off by another rule does not
/// fire a third. Without that cap two rules pointing at each other would spin
/// forever, and the cap is cheaper to understand than cycle detection.
public struct AutomationRepository {

    /// How deep a cascade may go. One means "rules see the user's change, and
    /// each other's, but not their own grandchildren".
    static let maximumDepth = 1

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - Managing rules

    public func automations(inProject projectID: String) throws -> [Automation] {
        try database.query(
            "SELECT * FROM automation WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ).map(Automation.init(row:))
    }

    @discardableResult
    public func create(
        inProject projectID: String,
        name: String,
        trigger: AutomationTrigger,
        triggerStatusID: String? = nil,
        action: AutomationAction,
        actionValue: String = ""
    ) throws -> Automation {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A rule needs a name.")
        }
        if trigger == .statusChanged, triggerStatusID == nil {
            throw LocalBoardError.invalidInput(
                field: "trigger", detail: "Say which column sets this rule off."
            )
        }
        if action.needsValue, actionValue.isEmpty {
            throw LocalBoardError.invalidInput(
                field: "action", detail: "Say what the rule should do."
            )
        }
        // A rule that moves a card into the column that sets it off would fire
        // on its own result forever, if the depth cap did not stop it — which
        // makes it a mistake worth naming rather than silently absorbing.
        if trigger == .statusChanged, action == .moveToStatus, triggerStatusID == actionValue {
            throw LocalBoardError.invalidInput(
                field: "action",
                detail: "That rule would move cards into the column that sets it off."
            )
        }

        let id = UUID().uuidString
        let last = try database.queryOne(
            "SELECT MAX(sort_order) AS last FROM automation WHERE project_id = ?;", [projectID]
        )?.double("last")

        try database.execute(
            """
            INSERT INTO automation (id, project_id, name, trigger, trigger_status_id,
                                    action, action_value, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [id, projectID, trimmed, trigger.rawValue, triggerStatusID.sqlValue,
             action.rawValue, actionValue, SortOrder.between(last, nil), clock.now]
        )

        guard let row = try database.queryOne("SELECT * FROM automation WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The rule was not written.")
        }
        return try Automation(row: row)
    }

    public func setEnabled(_ enabled: Bool, for automationID: String) throws {
        let changed = try database.execute(
            "UPDATE automation SET enabled = ? WHERE id = ?;", [enabled, automationID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "rule \(automationID)") }
    }

    public func delete(_ automationID: String) throws {
        let changed = try database.execute("DELETE FROM automation WHERE id = ?;", [automationID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "rule \(automationID)") }
    }

    // MARK: - Running rules

    /// Runs whatever the given event sets off. Caller holds the transaction.
    ///
    /// Failures inside a rule are swallowed rather than thrown: a rule that
    /// names a person who has since been deleted should stop working, not stop
    /// the user from moving their card.
    func run(
        trigger: AutomationTrigger,
        task: BoardTask,
        statusID: String?,
        depth: Int
    ) throws {
        guard depth <= Self.maximumDepth else { return }

        let rules = try automations(inProject: task.projectID).filter { rule in
            guard rule.enabled, rule.trigger == trigger else { return false }
            guard trigger == .statusChanged else { return true }
            return rule.triggerStatusID == statusID
        }

        for rule in rules {
            try? apply(rule, to: task, depth: depth)
        }
    }

    private func apply(_ rule: Automation, to task: BoardTask, depth: Int) throws {
        let tasks = TaskRepository(database: database, clock: clock)

        switch rule.action {
        case .moveToStatus:
            // Already there: doing nothing is not a failure, and re-moving
            // would write a history entry saying it moved to where it was.
            guard task.statusID != rule.actionValue else { return }
            try tasks.move(task.id, toStatus: rule.actionValue, automationDepth: depth + 1)

        case .setAssignee:
            try tasks.setAssignee(rule.actionValue, for: task.id)

        case .setPriority:
            guard let raw = Int(rule.actionValue), let priority = Priority(rawValue: raw) else { return }
            try tasks.setPriority(priority, for: task.id)

        case .addLabel:
            try LabelRepository(database: database)
                .setLabel(rule.actionValue, on: task.id, attached: true)

        case .setFlag:
            try tasks.setFlag(true, reason: rule.actionValue, for: task.id)

        case .clearFlag:
            try tasks.setFlag(false, for: task.id)
        }
    }

    /// Whether every one of a card's subtasks is finished — the condition
    /// behind "when all subtasks are done".
    func allSubtasksDone(of taskID: String) throws -> Bool {
        let total = try database.count(
            "SELECT COUNT(*) FROM task WHERE parent_id = ? AND trashed = 0;", [taskID]
        )
        guard total > 0 else { return false }

        let done = try database.count(
            "SELECT COUNT(*) FROM task WHERE parent_id = ? AND trashed = 0 AND completed_at IS NOT NULL;",
            [taskID]
        )
        return done == total
    }
}
