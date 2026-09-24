import Foundation
import LocalBoardCore
import LocalBoardStore

/// Runs a command, turning anything thrown into a readable message and a
/// non-zero exit rather than a stack trace.
func runCatching(_ body: () throws -> Int32) -> Int32 {
    do {
        return try body()
    } catch let error as LocalBoardError {
        Output.error(error.errorDescription ?? "Something went wrong.")
        if let reason = error.failureReason { Output.error(reason) }
        // The recovery suggestions are written for the app's error surface —
        // "correct the highlighted field" means nothing in a terminal, where
        // the detail above has already said what to fix.
        if case .invalidInput = error {} else if let suggestion = error.recoverySuggestion {
            Output.error(suggestion)
        }
        return ExitStatus.failure
    } catch {
        Output.error(error.localizedDescription)
        return ExitStatus.failure
    }
}

// MARK: - add

/// `localboard add "Write the thing" --status "In Progress" --due 2026-10-01`
func addCommand(_ arguments: Arguments, database: Database) -> Int32 {
    runCatching {
        let title = arguments.remainder.joined(separator: " ")
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Output.error("what should the card say? `localboard add \"Write the thing\"`")
            return ExitStatus.usage
        }

        let selection = Selection(database: database)
        let project = try selection.project(key: arguments.option("project"))
        let status = try selection.status(named: arguments.option("status"), in: project)

        var assigneeID: String?
        if let name = arguments.option("assignee") {
            guard let person = try PersonRepository(database: database).people().first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw CLIError("nobody here is called `\(name)`. Add them with `localboard people add \"\(name)\"`.")
            }
            assigneeID = person.id
        }

        let task = try TaskRepository(database: database).create(
            inProject: project.id,
            statusID: status.id,
            title: title,
            type: try arguments.option("type").map(Parse.type) ?? .task,
            priority: try arguments.option("priority").map(Parse.priority) ?? .normal,
            descriptionMarkdown: arguments.option("notes") ?? "",
            assigneeID: assigneeID,
            dueDate: try arguments.option("due").map(Parse.date)
        )

        Output.line("\(task.tag(in: project))  \(task.title)  →  \(status.name)")
        return ExitStatus.success
    }
}

// MARK: - list

/// `localboard list [--status NAME] [--all]`
func listCommand(_ arguments: Arguments, database: Database) -> Int32 {
    runCatching {
        let selection = Selection(database: database)
        let project = try selection.project(key: arguments.option("project"))
        let tasks = TaskRepository(database: database)

        let statuses = try selection.statuses(in: project)
        let columnName = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0.name) })
        let includeTrashed = arguments.flag("all")

        func row(_ task: BoardTask) -> [String] {
            [
                task.tag(in: project),
                columnName[task.statusID] ?? "",
                task.type.shortLabel,
                task.priority.shortLabel,
                task.dueDate.map(Parse.day) ?? "",
                task.trashed ? "\(task.title)  (trashed)" : task.title,
            ]
        }

        var rows: [[String]] = []

        var query = arguments.option("query")
        if let viewName = arguments.option("view") {
            guard let view = try SavedViewRepository(database: database)
                .views(inProject: project.id)
                .first(where: { $0.name.caseInsensitiveCompare(viewName) == .orderedSame })
            else {
                throw CLIError("no view called `\(viewName)`. See them with `localboard views`.")
            }
            query = view.query
        }

        if let query {
            // The same language the app's search field speaks.
            rows = try tasks.tasks(matching: query, inProject: project.id).map(row)
        } else {
            let wanted: [Status]
            if let name = arguments.option("status") {
                wanted = [try selection.status(named: name, in: project)]
            } else {
                wanted = statuses
            }

            for status in wanted {
                let column = try tasks.tasks(
                    inProject: project.id,
                    statusID: status.id,
                    includeTrashed: includeTrashed
                )
                rows.append(contentsOf: column.map(row))
            }
        }

        guard !rows.isEmpty else {
            if query != nil {
                Output.line("Nothing matches that query.")
            } else {
                Output.line("No cards yet. Add one with `localboard add \"Write the thing\"`.")
            }
            return ExitStatus.success
        }

        Output.table(headers: ["ID", "STATUS", "TYPE", "PRIORITY", "DUE", "TITLE"], rows: rows)
        Output.line()
        Output.line(rows.count == 1 ? "1 card in \(project.name)." : "\(rows.count) cards in \(project.name).")
        return ExitStatus.success
    }
}

// MARK: - seed

/// `localboard seed` — sample cards, for trying the board out and for the
/// manual testing the UI layer still needs.
func seedCommand(_ arguments: Arguments, database: Database) -> Int32 {
    runCatching {
        let selection = Selection(database: database)
        let project = try selection.project(key: arguments.option("project"))
        let statuses = try selection.statuses(in: project)
        let tasks = TaskRepository(database: database)

        guard let first = statuses.first else {
            throw CLIError("\(project.key) has no columns yet.")
        }
        let middle = statuses.count > 1 ? statuses[1] : first
        let last = statuses.last ?? first

        let samples: [(String, Status, TaskType, Priority, Int?)] = [
            ("Sketch the onboarding flow", first, .story, .normal, nil),
            ("Column headers wrap at narrow widths", first, .bug, .high, 3),
            ("Decide on the export format", first, .task, .normal, 10),
            ("Rebalance runs on every drag", middle, .bug, .highest, -1),
            ("Milestone 2: saved views", middle, .epic, .high, nil),
            ("Set up the signing certificate", last, .task, .low, nil),
        ]

        for (title, status, type, priority, dueInDays) in samples {
            try tasks.create(
                inProject: project.id,
                statusID: status.id,
                title: title,
                type: type,
                priority: priority,
                dueDate: dueInDays.map { Date().addingTimeInterval(Double($0) * 86_400) }
            )
        }

        Output.line("Added \(samples.count) sample cards to \(project.name).")
        Output.line("Remove them again with `localboard list` and the app's trash.")
        return ExitStatus.success
    }
}

// MARK: - export

/// `localboard export` — the whole project as JSON on stdout, so it can be
/// piped, diffed or kept. Everything stays on this Mac; where the pipe goes
/// next is the user's business, not the app's.
func exportCommand(_ arguments: Arguments, database: Database) -> Int32 {
    runCatching {
        let selection = Selection(database: database)
        let project = try selection.project(key: arguments.option("project"))
        let statuses = try selection.statuses(in: project)
        let repository = TaskRepository(database: database)

        let tasks = try statuses.flatMap {
            try repository.tasks(inProject: project.id, statusID: $0.id, includeTrashed: arguments.flag("all"))
        }

        let document = ExportDocument(
            schemaVersion: Migration.latestVersion,
            exportedAt: Date(),
            project: project,
            statuses: statuses,
            tasks: tasks
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(document)
        Output.line(String(decoding: data, as: UTF8.self))
        return ExitStatus.success
    }
}

/// The shape `localboard export` writes. Declared here rather than in the
/// store: it is a file format, and file formats are promises to whoever reads
/// them next.
struct ExportDocument: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let project: Project
    let statuses: [Status]
    let tasks: [BoardTask]
}

// MARK: - people

/// `localboard people` / `people add "Ada"` / `people remove "Ada"`
func peopleCommand(_ arguments: Arguments, database: Database) -> Int32 {
    runCatching {
        let repository = PersonRepository(database: database)
        let rest = arguments.remainder

        switch rest.first?.lowercased() {
        case nil, "list":
            let people = try repository.people()
            guard !people.isEmpty else {
                Output.line("Nobody yet. Add someone with `localboard people add \"Ada\"`.")
                return ExitStatus.success
            }
            Output.table(headers: ["NAME"], rows: people.map { [$0.name] })
            return ExitStatus.success

        case "add":
            let name = rest.dropFirst().joined(separator: " ")
            let person = try repository.create(name: name)
            Output.line("Added \(person.name).")
            return ExitStatus.success

        case "remove", "delete":
            let name = rest.dropFirst().joined(separator: " ")
            guard let person = try repository.people().first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw CLIError("nobody here is called `\(name)`.")
            }
            try repository.delete(person.id)
            Output.line("Removed \(person.name). Their cards are still there, unassigned.")
            return ExitStatus.success

        case .some(let unknown):
            throw CLIError("`people \(unknown)` is not a thing. Try list, add or remove.")
        }
    }
}

// MARK: - views

/// `localboard views` / `views save "This week" "due < +7d"` / `views remove "This week"`
func viewsCommand(_ arguments: Arguments, database: Database) -> Int32 {
    runCatching {
        let selection = Selection(database: database)
        let project = try selection.project(key: arguments.option("project"))
        let repository = SavedViewRepository(database: database)
        let rest = arguments.remainder

        switch rest.first?.lowercased() {
        case nil, "list":
            let views = try repository.views(inProject: project.id)
            guard !views.isEmpty else {
                Output.line("No views yet. Save one with `localboard views save \"This week\" \"due < +7d\"`.")
                return ExitStatus.success
            }
            Output.table(headers: ["NAME", "QUERY"], rows: views.map { [$0.name, $0.query] })
            return ExitStatus.success

        case "save", "add":
            let operands = Array(rest.dropFirst())
            guard operands.count >= 2 else {
                throw CLIError("saving a view needs a name and a query: `localboard views save \"This week\" \"due < +7d\"`.")
            }
            // The query is checked before it is stored, so a broken view is
            // never something to discover weeks later.
            let view = try repository.create(
                inProject: project.id,
                name: operands[0],
                query: operands.dropFirst().joined(separator: " ")
            )
            Output.line("Saved \(view.name): \(view.query)")
            return ExitStatus.success

        case "remove", "delete":
            let name = rest.dropFirst().joined(separator: " ")
            guard let view = try repository.views(inProject: project.id).first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw CLIError("no view called `\(name)`.")
            }
            try repository.delete(view.id)
            Output.line("Removed \(view.name).")
            return ExitStatus.success

        case .some(let unknown):
            throw CLIError("`views \(unknown)` is not a thing. Try list, save or remove.")
        }
    }
}
