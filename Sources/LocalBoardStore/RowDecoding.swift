import Foundation
import LocalBoardCore

/// Maps result rows onto the domain types.
///
/// The column names here are the schema's, and this is the only place that
/// knows both, so a column rename is a compile-and-fix in one file rather than
/// a hunt through string literals.

extension Row {
    /// A required column. A row that reaches here without it means the query
    /// and the schema have diverged, which is a bug rather than a user error —
    /// but it still surfaces as a readable message instead of a crash.
    func require<T>(_ column: String, _ read: (String) -> T?) throws -> T {
        guard let value = read(column) else {
            throw LocalBoardError.databaseQueryFailed(
                detail: "The result is missing the `\(column)` column, or it is NULL."
            )
        }
        return value
    }

    func requiredString(_ column: String) throws -> String {
        try require(column) { string($0) }
    }

    func requiredInt(_ column: String) throws -> Int {
        Int(try require(column) { int($0) })
    }

    func requiredDouble(_ column: String) throws -> Double {
        try require(column) { double($0) }
    }

    func requiredBool(_ column: String) throws -> Bool {
        try require(column) { bool($0) }
    }

    func requiredDate(_ column: String) throws -> Date {
        try require(column) { date($0) }
    }

    /// An enumeration stored as INTEGER. An unknown value means the file was
    /// written by a newer build; the migration guard catches that first, so
    /// reaching here is a genuine inconsistency.
    func requiredEnum<E: RawRepresentable>(_ column: String, _ type: E.Type) throws -> E
    where E.RawValue == Int {
        let raw = try requiredInt(column)
        guard let value = E(rawValue: raw) else {
            throw LocalBoardError.databaseQueryFailed(
                detail: "`\(column)` holds \(raw), which this version does not recognise."
            )
        }
        return value
    }
}

extension Workspace {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            name: try row.requiredString("name"),
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension Project {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            workspaceID: try row.requiredString("workspace_id"),
            name: try row.requiredString("name"),
            key: try row.requiredString("key"),
            descriptionMarkdown: row.string("description_md") ?? "",
            nextTaskNumber: try row.requiredInt("next_task_number"),
            archived: try row.requiredBool("archived"),
            enforcesWorkflow: row.bool("enforce_workflow") ?? false,
            color: row.string("color") ?? "",
            icon: row.string("icon") ?? "",
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension Status {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: try row.requiredString("project_id"),
            name: try row.requiredString("name"),
            category: try row.requiredEnum("category", StatusCategory.self),
            sortOrder: try row.requiredDouble("sort_order")
        )
    }
}

extension Board {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: try row.requiredString("project_id"),
            name: try row.requiredString("name"),
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at"),
            // The presentation settings tolerate a missing column so that a
            // board can still be read out of a query that did not select them.
            swimlaneMode: row.int("swimlane_mode")
                .flatMap { SwimlaneMode(rawValue: Int($0)) } ?? .none,
            cardFields: CardField.list(from: row.string("card_fields") ?? "due,labels"),
            customCardFieldIDs: CardField.customIDs(from: row.string("card_fields") ?? ""),
            colorRule: row.int("color_rule")
                .flatMap { CardColorRule(rawValue: Int($0)) } ?? .none,
            colorViewID: row.string("color_view_id"),
            staleDays: row.int("stale_days").map(Int.init) ?? 3,
            backlogEnabled: row.bool("backlog_enabled") ?? false,
            filterQuery: row.string("filter_query") ?? ""
        )
    }
}

extension BoardColumn {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            boardID: try row.requiredString("board_id"),
            statusID: try row.requiredString("status_id"),
            name: try row.requiredString("name"),
            wipLimit: row.int("wip_limit").map(Int.init),
            wipMinimum: row.int("wip_minimum").map(Int.init),
            wipMeasure: row.int("wip_measure")
                .flatMap { WIPMeasure(rawValue: Int($0)) } ?? .cardCount,
            isBacklog: row.bool("is_backlog") ?? false,
            sortOrder: try row.requiredDouble("sort_order")
        )
    }
}

extension Person {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            name: try row.requiredString("name"),
            color: row.string("color") ?? "graphite",
            capacityAmount: row.double("capacity_amount") ?? 0,
            capacityUnit: CapacityUnit(rawValue: row.int("capacity_unit").map(Int.init) ?? 0) ?? .hours,
            capacityPeriod: CapacityPeriod(rawValue: row.int("capacity_period").map(Int.init) ?? 1) ?? .week,
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension CardLabel {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: try row.requiredString("project_id"),
            name: try row.requiredString("name"),
            color: row.string("color") ?? "slate"
        )
    }
}

extension ChecklistItem {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            taskID: try row.requiredString("task_id"),
            text: try row.requiredString("text"),
            done: try row.requiredBool("done"),
            sortOrder: try row.requiredDouble("sort_order")
        )
    }
}

extension BoardTask {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: try row.requiredString("project_id"),
            statusID: try row.requiredString("status_id"),
            number: try row.requiredInt("number"),
            type: try row.requiredEnum("type", TaskType.self),
            title: try row.requiredString("title"),
            descriptionMarkdown: row.string("description_md") ?? "",
            assigneeID: row.string("assignee_id"),
            priority: try row.requiredEnum("priority", Priority.self),
            parentID: row.string("parent_id"),
            epicID: row.string("epic_id"),
            startDate: row.date("start_date"),
            dueDate: row.date("due_date"),
            estimate: row.double("estimate"),
            sortOrder: try row.requiredDouble("sort_order"),
            trashed: try row.requiredBool("trashed"),
            flagged: row.bool("flagged") ?? false,
            flagReason: row.string("flag_reason") ?? "",
            statusChangedAt: row.date("status_changed_at"),
            versionID: row.string("version_id"),
            sprintID: row.string("sprint_id"),
            listID: row.string("list_id"),
            isMilestone: row.bool("is_milestone") ?? false,
            trashedAt: row.date("trashed_at"),
            snoozedUntil: row.date("snoozed_until"),
            plannedFor: row.date("planned_for"),
            createdAt: try row.requiredDate("created_at"),
            updatedAt: try row.requiredDate("updated_at"),
            completedAt: row.date("completed_at")
        )
    }
}

extension SavedView {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: try row.requiredString("project_id"),
            name: try row.requiredString("name"),
            query: try row.requiredString("query"),
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension Version {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: try row.requiredString("project_id"),
            name: try row.requiredString("name"),
            descriptionMarkdown: row.string("description_md") ?? "",
            releaseDate: row.date("release_date"),
            released: try row.requiredBool("released"),
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension Swimlane {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            boardID: try row.requiredString("board_id"),
            name: try row.requiredString("name"),
            query: try row.requiredString("query"),
            pinned: try row.requiredBool("pinned"),
            sortOrder: try row.requiredDouble("sort_order")
        )
    }
}

extension QuickFilter {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            boardID: try row.requiredString("board_id"),
            name: try row.requiredString("name"),
            query: try row.requiredString("query"),
            sortOrder: try row.requiredDouble("sort_order")
        )
    }
}

extension StatusChange {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            taskID: try row.requiredString("task_id"),
            fromStatusID: row.string("from_status_id"),
            toStatusID: try row.requiredString("to_status_id"),
            at: try row.requiredDate("at")
        )
    }
}

extension RepositoryLink {
    init(row: Row) throws {
        self.init(
            projectID: try row.requiredString("project_id"),
            path: try row.requiredString("path"),
            bookmark: row.data("bookmark"),
            linkedAt: try row.requiredDate("linked_at")
        )
    }
}

extension Comment {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            taskID: try row.requiredString("task_id"),
            authorID: row.string("author_id"),
            bodyMarkdown: try row.requiredString("body_md"),
            createdAt: try row.requiredDate("created_at"),
            editedAt: row.date("edited_at"),
            isActionItem: row.bool("action_item") ?? false,
            actionAssigneeID: row.string("action_assignee_id"),
            actionDone: row.bool("action_done") ?? false,
            actionDoneAt: row.date("action_done_at")
        )
    }
}

extension Attachment {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            taskID: try row.requiredString("task_id"),
            filename: try row.requiredString("filename"),
            relativePath: try row.requiredString("relative_path"),
            byteSize: try row.requiredInt("byte_size"),
            addedAt: try row.requiredDate("added_at")
        )
    }
}

extension TaskLink {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            taskID: try row.requiredString("task_id"),
            otherTaskID: try row.requiredString("other_task_id"),
            kind: try row.requiredEnum("kind", LinkKind.self),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension WorkLogEntry {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            taskID: try row.requiredString("task_id"),
            personID: row.string("person_id"),
            minutes: try row.requiredInt("minutes"),
            note: row.string("note") ?? "",
            workedOn: try row.requiredDate("worked_on"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension CustomField {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: try row.requiredString("project_id"),
            name: try row.requiredString("name"),
            kind: try row.requiredEnum("kind", CustomFieldKind.self),
            options: CustomField.options(from: row.string("options") ?? ""),
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension Sprint {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: try row.requiredString("project_id"),
            name: try row.requiredString("name"),
            goal: row.string("goal") ?? "",
            state: try row.requiredEnum("state", SprintState.self),
            startsAt: row.date("starts_at"),
            endsAt: row.date("ends_at"),
            completedAt: row.date("completed_at"),
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension WorkflowTransition {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: try row.requiredString("project_id"),
            fromStatusID: try row.requiredString("from_status_id"),
            toStatusID: try row.requiredString("to_status_id")
        )
    }
}

extension Automation {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: try row.requiredString("project_id"),
            name: try row.requiredString("name"),
            trigger: try row.requiredEnum("trigger", AutomationTrigger.self),
            triggerStatusID: row.string("trigger_status_id"),
            action: try row.requiredEnum("action", AutomationAction.self),
            actionValue: row.string("action_value") ?? "",
            enabled: try row.requiredBool("enabled"),
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension Template {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: row.string("project_id"),
            kind: try row.requiredEnum("kind", TemplateKind.self),
            name: try row.requiredString("name"),
            payload: try row.requiredString("payload"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension RunningTimer {
    init(row: Row) throws {
        self.init(
            taskID: try row.requiredString("task_id"),
            personID: row.string("person_id"),
            startedAt: try row.requiredDate("started_at")
        )
    }
}

// MARK: - Schema 6

extension Folder {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: try row.requiredString("project_id"),
            name: try row.requiredString("name"),
            color: row.string("color") ?? "",
            icon: row.string("icon") ?? "",
            archived: row.bool("archived") ?? false,
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension TaskList {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: try row.requiredString("project_id"),
            folderID: row.string("folder_id"),
            name: try row.requiredString("name"),
            color: row.string("color") ?? "",
            icon: row.string("icon") ?? "",
            archived: row.bool("archived") ?? false,
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension TaskAssignee {
    init(row: Row) throws {
        self.init(
            taskID: try row.requiredString("task_id"),
            personID: try row.requiredString("person_id"),
            estimate: row.double("estimate"),
            sortOrder: try row.requiredDouble("sort_order")
        )
    }
}

extension Recurrence {
    init(row: Row) throws {
        let rule = RecurrenceRule(
            frequency: try row.requiredEnum("frequency", RecurrenceFrequency.self),
            interval: try row.requiredInt("interval"),
            weekdays: RecurrenceRule.weekdays(from: row.string("weekdays") ?? ""),
            weekOfMonth: row.int("week_of_month").map(Int.init),
            monthDay: row.int("month_day").map(Int.init),
            mode: try row.requiredEnum("mode", RecurrenceMode.self),
            resetChecklist: row.bool("reset_checklist") ?? true,
            resetSubtasks: row.bool("reset_subtasks") ?? true,
            resetStatus: row.bool("reset_status") ?? true,
            endsAt: row.date("ends_at")
        )
        self.init(
            id: try row.requiredString("id"),
            taskID: try row.requiredString("task_id"),
            rule: rule,
            lastSpawnedAt: row.date("last_spawned_at"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension ViewConfig {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            scopeKind: try row.requiredEnum("scope_kind", ViewScopeKind.self),
            scopeID: row.string("scope_id") ?? "",
            viewKind: try row.requiredEnum("view_kind", ViewKind.self),
            groupBy: row.string("group_by") ?? "",
            sortField: row.string("sort_field") ?? "",
            sortAscending: row.bool("sort_ascending") ?? true,
            filterQuery: row.string("filter_query") ?? "",
            columns: ViewConfig.columns(from: row.string("columns") ?? ""),
            updatedAt: try row.requiredDate("updated_at")
        )
    }
}

extension Shortcut {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            kind: try row.requiredEnum("kind", ShortcutKind.self),
            target: try row.requiredEnum("target", ShortcutTarget.self),
            targetID: try row.requiredString("target_id"),
            label: row.string("label") ?? "",
            sortOrder: try row.requiredDouble("sort_order"),
            at: try row.requiredDate("at")
        )
    }
}

// MARK: - Schema 7

extension Reminder {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            title: try row.requiredString("title"),
            notes: row.string("notes") ?? "",
            dueAt: row.date("due_at"),
            snoozedUntil: row.date("snoozed_until"),
            completedAt: row.date("completed_at"),
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}

extension Doc {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: row.string("project_id"),
            parentID: row.string("parent_id"),
            title: try row.requiredString("title"),
            icon: row.string("icon") ?? "",
            bodyMarkdown: row.string("body_md") ?? "",
            archived: row.bool("archived") ?? false,
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at"),
            updatedAt: try row.requiredDate("updated_at")
        )
    }
}

extension Whiteboard {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            projectID: row.string("project_id"),
            name: try row.requiredString("name"),
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at"),
            updatedAt: try row.requiredDate("updated_at")
        )
    }
}

extension WhiteboardItem {
    init(row: Row) throws {
        self.init(
            id: try row.requiredString("id"),
            boardID: try row.requiredString("board_id"),
            kind: try row.requiredEnum("kind", WhiteboardItemKind.self),
            x: row.double("x") ?? 0,
            y: row.double("y") ?? 0,
            width: row.double("width") ?? 140,
            height: row.double("height") ?? 100,
            text: row.string("text") ?? "",
            color: row.string("color") ?? "yellow",
            shape: (try? row.requiredEnum("shape", WhiteboardShape.self)) ?? .rectangle,
            strokeValues: WhiteboardItem.strokeValues(from: row.string("points") ?? ""),
            fromItem: row.string("from_item"),
            toItem: row.string("to_item"),
            taskID: row.string("task_id"),
            sortOrder: try row.requiredDouble("sort_order"),
            createdAt: try row.requiredDate("created_at")
        )
    }
}
