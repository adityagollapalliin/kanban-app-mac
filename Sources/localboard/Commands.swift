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
        if let suggestion = error.recoverySuggestion { Output.error(suggestion) }
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

        let task = try TaskRepository(database: database).create(
            inProject: project.id,
            statusID: status.id,
            title: title,
            type: try arguments.option("type").map(Parse.type) ?? .task,
            priority: try arguments.option("priority").map(Parse.priority) ?? .normal,
            descriptionMarkdown: arguments.option("notes") ?? "",
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
        let wanted: [Status]
        if let name = arguments.option("status") {
            wanted = [try selection.status(named: name, in: project)]
        } else {
            wanted = statuses
        }

        let includeTrashed = arguments.flag("all")
        var rows: [[String]] = []

        for status in wanted {
            let column = try tasks.tasks(
                inProject: project.id,
                statusID: status.id,
                includeTrashed: includeTrashed
            )
            for task in column {
                rows.append([
                    task.tag(in: project),
                    status.name,
                    task.type.shortLabel,
                    task.priority.shortLabel,
                    task.dueDate.map(Parse.day) ?? "",
                    task.trashed ? "\(task.title)  (trashed)" : task.title,
                ])
            }
        }

        guard !rows.isEmpty else {
            Output.line("No cards yet. Add one with `localboard add \"Write the thing\"`.")
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
