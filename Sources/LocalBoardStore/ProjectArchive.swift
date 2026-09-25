import Foundation
import LocalBoardCore

/// A project as a file: what `localboard export` writes and `localboard
/// import` reads back.
///
/// A file format is a promise to whoever reads it next, so two rules hold here
/// and are worth stating:
///
///   * **Fields are added, never renamed or removed.** Everything after
///     `tasks` is optional on the way in, so a file written by an older build
///     — which had only the project, its statuses and its cards — still
///     imports today.
///   * **What it cannot resolve, it drops rather than guesses.** An archive
///     names people and labels; it does not name sprints, versions or
///     attachments, so an imported card comes back without them instead of
///     pointing at whatever happened to share an id.
///
/// The round trip this guarantees is *the work*: every card, where it sits,
/// who it belongs to, what it is labelled and what its checklist says.
public struct ProjectArchive: Codable, Sendable, Equatable {

    /// The schema the archive was written from. Kept for the reader's sake: a
    /// file from a future version may describe things this build has no column
    /// for, and it should be able to say so rather than half-import it.
    public let schemaVersion: Int
    public let exportedAt: Date
    public let project: Project
    public let statuses: [Status]
    public let tasks: [BoardTask]

    /// People an imported card can be assigned back to. Matched by name on the
    /// way in, because people belong to the whole file rather than to one
    /// project: importing a project twice should not invent a second Ada.
    public var people: [Person] = []
    public var labels: [CardLabel] = []
    /// Which labels sit on which card, by the ids used elsewhere in the file.
    public var taskLabels: [TaskLabelPair] = []
    public var checklists: [ChecklistItem] = []
    /// The project's saved filters, each carrying the language it is written
    /// in. An archive written before schema 10 has none, and one written
    /// before the syntax column has filters without it — both read as
    /// `simple`, which is what they were.
    public var savedViews: [SavedView] = []

    public struct TaskLabelPair: Codable, Sendable, Equatable {
        public let taskID: String
        public let labelID: String

        public init(taskID: String, labelID: String) {
            self.taskID = taskID
            self.labelID = labelID
        }
    }

    public init(
        schemaVersion: Int,
        exportedAt: Date,
        project: Project,
        statuses: [Status],
        tasks: [BoardTask],
        people: [Person] = [],
        labels: [CardLabel] = [],
        taskLabels: [TaskLabelPair] = [],
        checklists: [ChecklistItem] = [],
        savedViews: [SavedView] = []
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.project = project
        self.statuses = statuses
        self.tasks = tasks
        self.people = people
        self.labels = labels
        self.taskLabels = taskLabels
        self.checklists = checklists
        self.savedViews = savedViews
    }

    /// Written by hand rather than synthesised, because the synthesised one
    /// requires every key — defaults and all — and the promise above is that a
    /// file from an older build, which has none of these, still reads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        project = try container.decode(Project.self, forKey: .project)
        statuses = try container.decode([Status].self, forKey: .statuses)
        tasks = try container.decode([BoardTask].self, forKey: .tasks)
        people = try container.decodeIfPresent([Person].self, forKey: .people) ?? []
        labels = try container.decodeIfPresent([CardLabel].self, forKey: .labels) ?? []
        taskLabels = try container.decodeIfPresent([TaskLabelPair].self, forKey: .taskLabels) ?? []
        checklists = try container.decodeIfPresent([ChecklistItem].self, forKey: .checklists) ?? []
        savedViews = try container.decodeIfPresent([SavedView].self, forKey: .savedViews) ?? []
    }

    /// The encoder and decoder the format is defined by, so a file written by
    /// the CLI and one written by a test are the same file.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> ProjectArchive {
        do {
            return try decoder.decode(ProjectArchive.self, from: data)
        } catch {
            throw LocalBoardError.invalidInput(
                field: "file",
                detail: "This is not a LocalBoard export: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Reading a project out

extension ProjectArchive {

    /// Gathers everything the format promises, in one pass per table.
    public static func export(
        projectID: String,
        from database: Database,
        includeTrashed: Bool = false,
        now: Date = .now
    ) throws -> ProjectArchive {
        guard let projectRow = try database.queryOne("SELECT * FROM project WHERE id = ?;", [projectID]) else {
            throw LocalBoardError.notFound(entity: "project \(projectID)")
        }
        let project = try Project(row: projectRow)

        let statuses = try database
            .query("SELECT * FROM status WHERE project_id = ? ORDER BY sort_order;", [projectID])
            .map(Status.init(row:))

        let taskSQL = includeTrashed
            ? "SELECT * FROM task WHERE project_id = ? ORDER BY sort_order;"
            : "SELECT * FROM task WHERE project_id = ? AND trashed = 0 ORDER BY sort_order;"
        let tasks = try database.query(taskSQL, [projectID]).map(BoardTask.init(row:))

        let labels = try database
            .query("SELECT * FROM label WHERE project_id = ? ORDER BY name;", [projectID])
            .map(CardLabel.init(row:))

        let taskIDs = Set(tasks.map(\.id))

        // Only the people this project's cards actually name. Exporting every
        // person on the Mac would put names in a file that has nothing to do
        // with them.
        let assigneeIDs = Set(tasks.compactMap(\.assigneeID))
        let people = try database
            .query("SELECT * FROM person ORDER BY sort_order;")
            .map(Person.init(row:))
            .filter { assigneeIDs.contains($0.id) }

        let pairs = try database.query(
            """
            SELECT task_label.task_id AS task_id, task_label.label_id AS label_id
            FROM task_label
            JOIN task ON task.id = task_label.task_id
            WHERE task.project_id = ?;
            """,
            [projectID]
        ).map { TaskLabelPair(taskID: try $0.requiredString("task_id"), labelID: try $0.requiredString("label_id")) }

        let checklists = try database.query(
            """
            SELECT checklist_item.* FROM checklist_item
            JOIN task ON task.id = checklist_item.task_id
            WHERE task.project_id = ? ORDER BY checklist_item.sort_order;
            """,
            [projectID]
        ).map(ChecklistItem.init(row:))

        // Saved filters, each with the language it is written in. Without the
        // syntax the import would have to guess, and guessing `jql` on a
        // filter that means something else as text is exactly the silent
        // change of meaning the column exists to prevent.
        let savedViews = try database.query(
            "SELECT * FROM saved_view WHERE project_id = ? ORDER BY sort_order;", [projectID]
        ).map(SavedView.init(row:))

        return ProjectArchive(
            schemaVersion: Migration.latestVersion,
            exportedAt: now,
            project: project,
            statuses: statuses,
            tasks: tasks,
            people: people,
            labels: labels,
            taskLabels: pairs.filter { taskIDs.contains($0.taskID) },
            checklists: checklists.filter { taskIDs.contains($0.taskID) },
            savedViews: savedViews
        )
    }
}

// MARK: - Writing a project back in

extension ProjectArchive {

    /// What an import produced, so the caller can say so rather than guess.
    public struct Restored: Sendable, Equatable {
        public let project: Project
        public let boardID: String
        public let taskCount: Int
        /// People the archive named who were already here, matched by name.
        public let reusedPeople: Int
    }

    /// Writes the archive into a database as a new project.
    ///
    /// Always a *new* project, never a merge into an existing one. Merging
    /// would have to decide what happens to a card that exists in both, and
    /// there is no answer to that which is right often enough to apply without
    /// asking. An import you can then delete is recoverable; a merge is not.
    ///
    /// Ids are regenerated throughout, because the archive may well have come
    /// from this same file — importing a backup of a project alongside the
    /// original has to work. Card *numbers* are kept, so WORK-14 is still 14.
    @discardableResult
    public func restore(
        into database: Database,
        workspaceID: String? = nil,
        name: String? = nil,
        key: String? = nil,
        now: Date = .now
    ) throws -> Restored {
        guard schemaVersion <= Migration.latestVersion else {
            throw LocalBoardError.invalidInput(
                field: "file",
                detail: """
                    This archive was written by a newer version of LocalBoard \
                    (schema \(schemaVersion); this build reads \(Migration.latestVersion)). \
                    Update the app, or export again from the older one.
                    """
            )
        }
        guard !statuses.isEmpty else {
            throw LocalBoardError.invalidInput(
                field: "statuses",
                detail: "The archive has no columns, so there is nowhere to put its cards."
            )
        }

        return try database.transaction {
            let workspace = try workspaceID ?? defaultWorkspaceID(in: database)
            let projectName = (name ?? project.name).trimmingCharacters(in: .whitespacesAndNewlines)
            let projectKey = try uniqueKey(
                (key ?? project.key).uppercased(), in: workspace, database: database
            )

            let projectID = UUID().uuidString
            let lastProject = try database.queryOne(
                "SELECT MAX(sort_order) AS last FROM project WHERE workspace_id = ?;", [workspace]
            )?.double("last")

            try database.execute(
                """
                INSERT INTO project (id, workspace_id, name, key, description_md,
                                     next_task_number, archived, sort_order, created_at)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?);
                """,
                [
                    projectID, workspace, projectName.isEmpty ? "Imported project" : projectName,
                    projectKey, project.descriptionMarkdown,
                    (tasks.map(\.number).max() ?? 0) + 1,
                    SortOrder.between(lastProject, nil), now,
                ]
            )

            let boardID = UUID().uuidString
            try database.execute(
                "INSERT INTO board (id, project_id, name, sort_order, created_at) VALUES (?, ?, ?, ?, ?);",
                [boardID, projectID, "Board", SortOrder.step, now]
            )
            try BoardPresentationRepository(database: database).seedDefaults(forBoard: boardID)

            // The archive predates lists, and a card with no list has no home.
            let listID = UUID().uuidString
            try database.execute(
                """
                INSERT INTO list (id, project_id, folder_id, name, sort_order, created_at)
                VALUES (?, ?, NULL, ?, ?, ?);
                """,
                [listID, projectID, projectName.isEmpty ? "Imported project" : projectName, SortOrder.step, now]
            )

            let statusIDs = try restoreStatuses(projectID: projectID, boardID: boardID, database: database)
            let (personIDs, reused) = try restorePeople(in: database, now: now)
            let labelIDs = try restoreLabels(projectID: projectID, database: database)
            let taskIDs = try restoreTasks(
                projectID: projectID, statusIDs: statusIDs, personIDs: personIDs,
                listID: listID, database: database, now: now
            )
            try restoreAttachments(taskIDs: taskIDs, labelIDs: labelIDs, database: database)
            try restoreSavedViews(projectID: projectID, database: database, now: now)

            guard let row = try database.queryOne("SELECT * FROM project WHERE id = ?;", [projectID]) else {
                throw LocalBoardError.databaseQueryFailed(detail: "The imported project was not written.")
            }
            return Restored(
                project: try Project(row: row),
                boardID: boardID,
                taskCount: taskIDs.count,
                reusedPeople: reused
            )
        }
    }

    private func defaultWorkspaceID(in database: Database) throws -> String {
        guard let row = try database.queryOne("SELECT id FROM workspace ORDER BY sort_order LIMIT 1;") else {
            throw LocalBoardError.notFound(entity: "workspace")
        }
        return try row.requiredString("id")
    }

    /// A key already in use gets a digit rather than a refusal: an import that
    /// stops because two projects agree on three letters is an import that
    /// wasted the user's time over something the app can settle itself.
    private func uniqueKey(_ wanted: String, in workspaceID: String, database: Database) throws -> String {
        let base = wanted.filter { $0.isLetter || $0.isNumber }
        let stem = base.isEmpty ? "IMPORT" : String(base.prefix(10))

        for suffix in 0...99 {
            let candidate = suffix == 0 ? stem : "\(stem)\(suffix)"
            let taken = try database.count(
                "SELECT COUNT(*) FROM project WHERE workspace_id = ? AND key = ? COLLATE NOCASE;",
                [workspaceID, candidate]
            )
            if taken == 0 { return candidate }
        }
        throw LocalBoardError.invalidInput(
            field: "key",
            detail: "There are already a hundred projects keyed \(stem). Pass --key to choose another."
        )
    }

    /// Each status becomes a status row and a column on the new board, in the
    /// order the archive lists them.
    private func restoreStatuses(
        projectID: String, boardID: String, database: Database
    ) throws -> [String: String] {
        var mapping: [String: String] = [:]

        for (index, status) in statuses.enumerated() {
            let statusID = UUID().uuidString
            let position = Double(index + 1) * SortOrder.step
            mapping[status.id] = statusID

            try database.execute(
                "INSERT INTO status (id, project_id, name, category, sort_order) VALUES (?, ?, ?, ?, ?);",
                [statusID, projectID, status.name, status.category.rawValue, position]
            )
            let columnID = UUID().uuidString
            try database.execute(
                """
                INSERT INTO board_column (id, board_id, status_id, name, wip_limit, sort_order)
                VALUES (?, ?, ?, ?, NULL, ?);
                """,
                [columnID, boardID, statusID, status.name, position]
            )
            try database.execute(
                "INSERT INTO column_status (column_id, status_id, sort_order) VALUES (?, ?, ?);",
                [columnID, statusID, SortOrder.step]
            )
        }
        return mapping
    }

    /// Matched by name, case-insensitively, because that is what a person is
    /// to the rest of the app — the id is an implementation detail of one file.
    private func restorePeople(in database: Database, now: Date) throws -> ([String: String], Int) {
        var mapping: [String: String] = [:]
        var reused = 0

        for person in people {
            if let row = try database.queryOne(
                "SELECT id FROM person WHERE name = ? COLLATE NOCASE LIMIT 1;", [person.name]
            ) {
                mapping[person.id] = try row.requiredString("id")
                reused += 1
                continue
            }

            let personID = UUID().uuidString
            let last = try database.queryOne("SELECT MAX(sort_order) AS last FROM person;")?.double("last")
            try database.execute(
                "INSERT INTO person (id, name, color, sort_order, created_at) VALUES (?, ?, ?, ?, ?);",
                [personID, person.name, person.color, SortOrder.between(last, nil), now]
            )
            mapping[person.id] = personID
        }
        return (mapping, reused)
    }

    private func restoreLabels(projectID: String, database: Database) throws -> [String: String] {
        var mapping: [String: String] = [:]
        for label in labels {
            let labelID = UUID().uuidString
            try database.execute(
                "INSERT INTO label (id, project_id, name, color) VALUES (?, ?, ?, ?);",
                [labelID, projectID, label.name, label.color]
            )
            mapping[label.id] = labelID
        }
        return mapping
    }

    /// Cards first without their links to each other, then the links — a
    /// parent can appear after its child in the file, and a card cannot point
    /// at a row that is not written yet.
    private func restoreTasks(
        projectID: String,
        statusIDs: [String: String],
        personIDs: [String: String],
        listID: String,
        database: Database,
        now: Date
    ) throws -> [String: String] {
        var mapping: [String: String] = [:]
        for task in tasks { mapping[task.id] = UUID().uuidString }

        let fallbackStatus = statusIDs[statuses[0].id]

        for task in tasks {
            guard let taskID = mapping[task.id] else { continue }
            // A card whose column is missing from the archive lands in the
            // first one rather than being dropped: a card in the wrong column
            // can be moved, a card that never arrived cannot.
            guard let statusID = statusIDs[task.statusID] ?? fallbackStatus else { continue }

            try database.execute(
                """
                INSERT INTO task (id, project_id, status_id, number, type, title, description_md,
                                  assignee_id, priority, start_date, due_date, estimate, sort_order,
                                  trashed, flagged, flag_reason, status_changed_at, list_id,
                                  created_at, updated_at, completed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    taskID, projectID, statusID, task.number, task.type.rawValue, task.title,
                    task.descriptionMarkdown,
                    task.assigneeID.flatMap { personIDs[$0] }.sqlValue,
                    task.priority.rawValue, task.startDate.sqlValue, task.dueDate.sqlValue,
                    task.estimate.sqlValue, task.sortOrder, task.trashed, task.flagged, task.flagReason,
                    (task.statusChangedAt ?? task.createdAt).sqlValue, listID,
                    task.createdAt, task.updatedAt, task.completedAt.sqlValue,
                ]
            )

            // The opening entry every card has, so the imported project has a
            // history the analytics can read rather than starting blank.
            try database.execute(
                """
                INSERT INTO status_change (id, task_id, from_status_id, to_status_id, at)
                VALUES (?, ?, NULL, ?, ?);
                """,
                [UUID().uuidString, taskID, statusID, (task.statusChangedAt ?? task.createdAt)]
            )
        }

        for task in tasks {
            guard let taskID = mapping[task.id] else { continue }
            let parent = task.parentID.flatMap { mapping[$0] }
            let epic = task.epicID.flatMap { mapping[$0] }
            guard parent != nil || epic != nil else { continue }
            try database.execute(
                "UPDATE task SET parent_id = ?, epic_id = ? WHERE id = ?;",
                [parent.sqlValue, epic.sqlValue, taskID]
            )
        }
        return mapping
    }

    /// Saved filters come back in the language they were written in.
    ///
    /// An archive from before that was recorded has no syntax on its filters,
    /// and `SavedView`'s decoder reads that as `simple` — which is what they
    /// were, so an old backup restored today behaves exactly as it did on the
    /// day it was taken.
    private func restoreSavedViews(projectID: String, database: Database, now: Date) throws {
        for (index, view) in savedViews.enumerated() {
            try database.execute(
                """
                INSERT INTO saved_view (id, project_id, name, query, syntax, starred, columns,
                                        sort_order, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [UUID().uuidString, projectID, view.name, view.query, view.syntax.rawValue,
                 view.starred ? 1 : 0, SavedView.storedColumns(view.columns),
                 Double(index + 1) * SortOrder.step, now]
            )
        }
    }

    private func restoreAttachments(
        taskIDs: [String: String], labelIDs: [String: String], database: Database
    ) throws {
        for pair in taskLabels {
            guard let taskID = taskIDs[pair.taskID], let labelID = labelIDs[pair.labelID] else { continue }
            try database.execute(
                "INSERT OR IGNORE INTO task_label (task_id, label_id) VALUES (?, ?);", [taskID, labelID]
            )
        }

        for item in checklists {
            guard let taskID = taskIDs[item.taskID] else { continue }
            try database.execute(
                "INSERT INTO checklist_item (id, task_id, text, done, sort_order) VALUES (?, ?, ?, ?, ?);",
                [UUID().uuidString, taskID, item.text, item.done, item.sortOrder]
            )
        }
    }
}
