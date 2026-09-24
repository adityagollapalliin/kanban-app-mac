import Foundation
import LocalBoardCore

/// Saved shapes for new cards and new projects.
///
/// The payload is JSON rather than a table per kind. A project template
/// carries columns, labels and starter cards; modelling each as its own table
/// would be modelling most of the schema a second time, and a template is not
/// live data — nothing joins to it, nothing queries inside it, and it is read
/// exactly once, at the moment it is used.
public struct TemplateRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - Reading

    public func cardTemplates(inProject projectID: String) throws -> [Template] {
        try database.query(
            "SELECT * FROM template WHERE kind = ? AND project_id = ? ORDER BY name;",
            [TemplateKind.card.rawValue, projectID]
        ).map(Template.init(row:))
    }

    public func projectTemplates() throws -> [Template] {
        try database.query(
            "SELECT * FROM template WHERE kind = ? ORDER BY name;", [TemplateKind.project.rawValue]
        ).map(Template.init(row:))
    }

    public func delete(_ templateID: String) throws {
        let changed = try database.execute("DELETE FROM template WHERE id = ?;", [templateID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "template \(templateID)") }
    }

    // MARK: - Card templates

    @discardableResult
    public func saveCardTemplate(
        inProject projectID: String,
        name: String,
        payload: CardTemplatePayload
    ) throws -> Template {
        try save(projectID: projectID, kind: .card, name: name, payload: payload)
    }

    public func cardPayload(of template: Template) throws -> CardTemplatePayload {
        try decode(template.payload)
    }

    /// Builds a card template out of a card that already exists.
    ///
    /// This is how templates actually get made: somebody writes the bug report
    /// they always write, and then wants it again. Making them retype it into
    /// a template form is how the feature goes unused.
    public func cardTemplate(from task: BoardTask, includingChecklist: Bool = true) throws -> CardTemplatePayload {
        let labels = try LabelRepository(database: database).labels(forTask: task.id).map(\.name)
        let checklist = includingChecklist
            ? try ChecklistRepository(database: database, clock: clock).items(forTask: task.id).map(\.text)
            : []

        // The title is a *prefix*, not the title: a template called after one
        // card should not name every card after it.
        return CardTemplatePayload(
            titlePrefix: nil,
            type: task.type,
            priority: task.priority,
            descriptionMarkdown: task.descriptionMarkdown.isEmpty ? nil : task.descriptionMarkdown,
            labelNames: labels,
            checklist: checklist,
            estimate: task.estimate,
            dueInDays: nil
        )
    }

    /// Creates a card from a template.
    ///
    /// Labels named by the template are created if the project does not have
    /// them yet, because a template that silently drops half its labels on a
    /// new project is worse than one that adds two.
    @discardableResult
    public func createCard(
        from template: Template,
        titled title: String,
        inProject projectID: String,
        statusID: String
    ) throws -> BoardTask {
        let payload = try cardPayload(of: template)
        let tasks = TaskRepository(database: database, clock: clock)
        let labels = LabelRepository(database: database)
        let checklists = ChecklistRepository(database: database, clock: clock)

        return try database.transaction {
            let fullTitle = [payload.titlePrefix, title]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            let due = payload.dueInDays.flatMap {
                Calendar.current.date(byAdding: .day, value: $0, to: clock.now)
            }

            let created = try tasks.create(
                inProject: projectID,
                statusID: statusID,
                title: fullTitle.isEmpty ? title : fullTitle,
                type: payload.type ?? .task,
                priority: payload.priority ?? .normal,
                descriptionMarkdown: payload.descriptionMarkdown ?? "",
                dueDate: due
            )

            if let estimate = payload.estimate {
                try tasks.setEstimate(estimate, for: created.id)
            }

            let existing = try labels.labels(inProject: projectID)
            for name in payload.labelNames {
                let label = try existing.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    ?? labels.create(inProject: projectID, name: name)
                try labels.setLabel(label.id, on: created.id, attached: true)
            }

            for item in payload.checklist {
                try checklists.add(toTask: created.id, text: item)
            }

            return try tasks.task(id: created.id)
        }
    }

    // MARK: - Project templates

    @discardableResult
    public func saveProjectTemplate(name: String, payload: ProjectTemplatePayload) throws -> Template {
        try save(projectID: nil, kind: .project, name: name, payload: payload)
    }

    public func projectPayload(of template: Template) throws -> ProjectTemplatePayload {
        try decode(template.payload)
    }

    /// Captures a project's shape — its columns, limits and labels — without
    /// its work.
    public func projectTemplate(from projectID: String) throws -> ProjectTemplatePayload {
        let boards = BoardRepository(database: database, clock: clock)
        let statuses = try boards.statuses(inProject: projectID)

        var limits: [String: Int] = [:]
        try database.forEachRow(
            """
            SELECT board_column.status_id AS status_id, board_column.wip_limit AS wip_limit
            FROM board_column
            JOIN status ON status.id = board_column.status_id
            WHERE status.project_id = ? AND board_column.wip_limit IS NOT NULL;
            """,
            [projectID]
        ) { row in
            limits[try row.requiredString("status_id")] = row.int("wip_limit").map(Int.init)
        }

        return ProjectTemplatePayload(
            columns: statuses.map {
                ProjectTemplatePayload.Column(name: $0.name, category: $0.category, wipLimit: limits[$0.id])
            },
            labels: try LabelRepository(database: database).labels(inProject: projectID).map {
                ProjectTemplatePayload.Label(name: $0.name, color: $0.color)
            },
            starterCards: []
        )
    }

    /// Creates a project laid out the way the template says.
    @discardableResult
    public func createProject(
        from template: Template,
        named name: String,
        key: String,
        inWorkspace workspaceID: String
    ) throws -> Project {
        let payload = try projectPayload(of: template)
        let boards = BoardRepository(database: database, clock: clock)
        let labels = LabelRepository(database: database)
        let tasks = TaskRepository(database: database, clock: clock)

        return try database.transaction {
            // The project arrives with the three standard columns; the
            // template's own replace them, so a template of one column gets a
            // board of one column rather than four.
            let project = try boards.createProject(inWorkspace: workspaceID, name: name, key: key)

            guard let board = try boards.boards(inProject: project.id).first else {
                throw LocalBoardError.databaseQueryFailed(detail: "The project has no board.")
            }

            let starters = try boards.snapshot(boardID: board.id).columns
            for column in payload.columns {
                let added = try boards.addColumn(
                    toBoard: board.id, name: column.name, category: column.category
                )
                if let limit = column.wipLimit {
                    try boards.setWIPLimit(limit, for: added.id)
                }
            }
            // Removed last, so the board is never momentarily empty and the
            // template's own columns are already there to move nothing into.
            for starter in starters {
                try boards.deleteColumn(starter.id, movingTasksTo: nil)
            }

            for label in payload.labels {
                try labels.create(inProject: project.id, name: label.name, color: label.color)
            }

            if !payload.starterCards.isEmpty,
               let first = try boards.snapshot(boardID: board.id).columns.first {
                for title in payload.starterCards {
                    try tasks.create(inProject: project.id, statusID: first.status.id, title: title)
                }
            }

            return project
        }
    }

    // MARK: - Encoding

    private func save<Payload: Encodable>(
        projectID: String?,
        kind: TemplateKind,
        name: String,
        payload: Payload
    ) throws -> Template {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "name", detail: "A template needs a name.")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let json = String(data: try encoder.encode(payload), encoding: .utf8) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The template could not be encoded.")
        }

        let id = UUID().uuidString
        try database.execute(
            """
            INSERT INTO template (id, project_id, kind, name, payload, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [id, projectID.sqlValue, kind.rawValue, trimmed, json, clock.now]
        )

        guard let row = try database.queryOne("SELECT * FROM template WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The template was not written.")
        }
        return try Template(row: row)
    }

    private func decode<Payload: Decodable>(_ json: String) throws -> Payload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        guard let data = json.data(using: .utf8) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The template could not be read.")
        }
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch {
            // A template written by a newer build, or edited by hand. Saying
            // so beats a crash or a silently empty result.
            throw LocalBoardError.invalidInput(
                field: "template",
                detail: "This template was written by a different version and cannot be read."
            )
        }
    }
}
