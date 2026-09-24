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

        // `--count 1000` is the board to measure against: a thousand cards is
        // the size the performance budget is written for, and typing them in
        // by hand is not a test anybody runs twice.
        let bulk = max(0, (try arguments.option("count").map(Parse.count)) ?? 0)
        if bulk > 0 {
            let verbs = ["Review", "Fix", "Write", "Refactor", "Investigate", "Document", "Remove"]
            let nouns = ["the parser", "the export", "the drag handler", "the migration",
                         "the sidebar", "the query compiler", "the icon", "the backlog"]

            try database.transaction {
                for index in 0..<bulk {
                    try tasks.create(
                        inProject: project.id,
                        statusID: statuses[index % statuses.count].id,
                        title: "\(verbs[index % verbs.count]) \(nouns[(index / verbs.count) % nouns.count]) #\(index + 1)",
                        type: TaskType.allCases[index % TaskType.allCases.count],
                        priority: Priority.allCases[index % Priority.allCases.count],
                        dueDate: index % 3 == 0
                            ? Date().addingTimeInterval(Double(index % 30 - 10) * 86_400)
                            : nil
                    )
                }
            }
            Output.line("Added \(samples.count + bulk) cards to \(project.name).")
        } else {
            Output.line("Added \(samples.count) sample cards to \(project.name).")
        }

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

        let archive = try ProjectArchive.export(
            projectID: project.id,
            from: database,
            includeTrashed: arguments.flag("all")
        )
        Output.line(String(decoding: try archive.encoded(), as: UTF8.self))
        return ExitStatus.success
    }
}

// MARK: - import

/// `localboard import <file>` — the other half of the round trip.
///
/// Always creates a new project rather than merging into an existing one, so
/// the worst an import can do is leave a project to delete. See
/// `ProjectArchive.restore` for why merging is not offered.
func importCommand(_ arguments: Arguments, database: Database) -> Int32 {
    runCatching {
        guard let path = arguments.remainder.first else {
            Output.error("usage: localboard import <file.json> [--name \"Name\"] [--key KEY]")
            return ExitStatus.usage
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw LocalBoardError.invalidInput(field: "file", detail: "No file at \(url.path).")
        }

        let archive = try ProjectArchive.decoded(from: data)
        let restored = try archive.restore(
            into: database,
            name: arguments.option("name"),
            key: arguments.option("key")
        )

        Output.line("""
            Imported \(restored.project.name) (\(restored.project.key)) \
            with \(restored.taskCount) card\(restored.taskCount == 1 ? "" : "s").
            """)
        if restored.reusedPeople > 0 {
            let count = restored.reusedPeople
            Output.line("\(count) assignee\(count == 1 ? "" : "s") matched people already here, by name.")
        }
        if restored.project.key != archive.project.key {
            Output.line("The key \(archive.project.key) was taken, so this project is \(restored.project.key).")
        }
        return ExitStatus.success
    }
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

// MARK: - trash and restore

/// `localboard trash TASK-3` — hides a card without deleting it.
func trashCommand(_ arguments: Arguments, database: Database, trashed: Bool) -> Int32 {
    runCatching {
        let tag = arguments.remainder.first
        guard let tag else {
            Output.error(trashed
                ? "which card? `localboard trash TASK-3`"
                : "which card? `localboard restore TASK-3`")
            return ExitStatus.usage
        }

        let selection = Selection(database: database)
        let project = try selection.project(key: arguments.option("project"))
        let task = try selection.task(tag: tag, in: project)

        guard task.trashed != trashed else {
            Output.line(trashed
                ? "\(task.tag(in: project)) is already in the trash."
                : "\(task.tag(in: project)) is not in the trash.")
            return ExitStatus.success
        }

        try TaskRepository(database: database).setTrashed(trashed, for: task.id)

        Output.line(trashed
            ? "\(task.tag(in: project)) is in the trash. Put it back with `localboard restore \(task.tag(in: project))`."
            : "\(task.tag(in: project)) is back on the board.")
        return ExitStatus.success
    }
}

// MARK: - labels

/// `localboard labels` / `labels add "needs design" --color purple` /
/// `labels remove "needs design"` / `labels on TASK-3 "needs design"`
func labelsCommand(_ arguments: Arguments, database: Database) -> Int32 {
    runCatching {
        let selection = Selection(database: database)
        let project = try selection.project(key: arguments.option("project"))
        let repository = LabelRepository(database: database)
        let rest = arguments.remainder

        func label(named name: String) throws -> CardLabel {
            guard let match = try repository.labels(inProject: project.id).first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw CLIError("no label called `\(name)` in \(project.key).")
            }
            return match
        }

        switch rest.first?.lowercased() {
        case nil, "list":
            let labels = try repository.labels(inProject: project.id)
            guard !labels.isEmpty else {
                Output.line("No labels yet. Add one with `localboard labels add \"needs design\"`.")
                return ExitStatus.success
            }
            Output.table(headers: ["NAME", "COLOUR"], rows: labels.map { [$0.name, $0.color] })
            return ExitStatus.success

        case "add":
            let created = try repository.create(
                inProject: project.id,
                name: rest.dropFirst().joined(separator: " "),
                color: arguments.option("color") ?? "slate"
            )
            Output.line("Added \(created.name).")
            return ExitStatus.success

        case "remove", "delete":
            let existing = try label(named: rest.dropFirst().joined(separator: " "))
            try repository.delete(existing.id)
            Output.line("Removed \(existing.name). The cards that carried it are untouched.")
            return ExitStatus.success

        case "on":
            let operands = Array(rest.dropFirst())
            guard operands.count >= 2 else {
                throw CLIError("putting a label on a card needs both: `localboard labels on TASK-3 \"needs design\"`.")
            }
            let task = try selection.task(tag: operands[0], in: project)
            let existing = try label(named: operands.dropFirst().joined(separator: " "))
            let attaching = !arguments.flag("off")

            try repository.setLabel(existing.id, on: task.id, attached: attaching)
            Output.line(attaching
                ? "\(task.tag(in: project)) now carries \(existing.name)."
                : "\(task.tag(in: project)) no longer carries \(existing.name).")
            return ExitStatus.success

        case .some(let unknown):
            throw CLIError("`labels \(unknown)` is not a thing. Try list, add, remove or on.")
        }
    }
}

// MARK: - columns

/// `localboard columns` / `columns add "Review" --counts-as progress` /
/// `columns remove "Review" --move-to "To Do"`
func columnsCommand(_ arguments: Arguments, database: Database) -> Int32 {
    runCatching {
        let selection = Selection(database: database)
        let project = try selection.project(key: arguments.option("project"))
        let repository = BoardRepository(database: database)

        guard let board = try repository.boards(inProject: project.id).first else {
            throw CLIError("\(project.key) has no board yet.")
        }
        let snapshot = try repository.snapshot(boardID: board.id)
        let rest = arguments.remainder

        func column(named name: String) throws -> LoadedColumn {
            guard let match = snapshot.columns.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw CLIError("no column called `\(name)` on \(board.name).")
            }
            return match
        }

        switch rest.first?.lowercased() {
        case nil, "list":
            Output.table(
                headers: ["NAME", "COUNTS AS", "LIMIT", "CARDS"],
                rows: snapshot.columns.map { column in
                    [
                        column.name,
                        categoryLabel(column.status.category),
                        column.column.wipLimit.map(String.init) ?? "none",
                        "\(column.tasks.count)",
                    ]
                }
            )
            return ExitStatus.success

        case "add":
            let name = rest.dropFirst().joined(separator: " ")
            let category = try arguments.option("counts-as").map(parseCategory) ?? .toDo
            try repository.addColumn(toBoard: board.id, name: name, category: category)
            Output.line("Added \(name).")
            return ExitStatus.success

        case "remove", "delete":
            let existing = try column(named: rest.dropFirst().joined(separator: " "))
            let destination = try arguments.option("move-to").map { try column(named: $0).status.id }
            try repository.deleteColumn(existing.id, movingTasksTo: destination)
            Output.line(existing.tasks.isEmpty
                ? "Removed \(existing.name)."
                : "Removed \(existing.name); its \(existing.tasks.count) card\(existing.tasks.count == 1 ? "" : "s") moved.")
            return ExitStatus.success

        case .some(let unknown):
            throw CLIError("`columns \(unknown)` is not a thing. Try list, add or remove.")
        }
    }
}

private func parseCategory(_ raw: String) throws -> StatusCategory {
    switch raw.lowercased() {
    case "todo", "to-do", "to do": .toDo
    case "progress", "in-progress", "in progress", "doing": .inProgress
    case "done", "complete": .done
    default:
        throw CLIError("`--counts-as` is one of todo, progress or done. `\(raw)` is not one.")
    }
}

private func categoryLabel(_ category: StatusCategory) -> String {
    switch category {
    case .toDo: "to do"
    case .inProgress: "in progress"
    case .done: "done"
    }
}

// MARK: - Flags

/// `localboard flag TASK-3 "waiting on legal"`, and `--off` to clear it.
///
/// Flagging from the terminal is the case this earns its keep on: the moment
/// you find out a thing is blocked is usually the moment you are in a shell
/// looking at why.
func flagCommand(_ arguments: Arguments, database: Database) -> Int32 {
    runCatching {
        let selection = Selection(database: database)
        let project = try selection.project(key: arguments.option("project"))
        let repository = TaskRepository(database: database)
        let rest = arguments.remainder

        // No arguments: list what is blocked, which is the other half of the
        // question and the reason to look at flags at all.
        guard let tag = rest.first else {
            let flagged = try repository.tasks(matching: "is:flagged", inProject: project.id)
            guard !flagged.isEmpty else {
                Output.line("Nothing is flagged in \(project.key).")
                return ExitStatus.success
            }
            Output.table(
                headers: ["ID", "TITLE", "WHY"],
                rows: flagged.map { [$0.tag(in: project), $0.title, $0.flagReason] }
            )
            return ExitStatus.success
        }

        let task = try selection.task(tag: tag, in: project)

        if arguments.flag("off") {
            try repository.setFlag(false, for: task.id)
            Output.line("\(task.tag(in: project)) is no longer flagged.")
            return ExitStatus.success
        }

        let reason = rest.dropFirst().joined(separator: " ")
        try repository.setFlag(true, reason: reason, for: task.id)
        Output.line(reason.isEmpty
            ? "\(task.tag(in: project)) is flagged."
            : "\(task.tag(in: project)) is flagged: \(reason)")
        return ExitStatus.success
    }
}

// MARK: - Releases

func versionsCommand(_ arguments: Arguments, database: Database) -> Int32 {
    runCatching {
        let selection = Selection(database: database)
        let project = try selection.project(key: arguments.option("project"))
        let repository = VersionRepository(database: database)
        let rest = arguments.remainder

        func version(named name: String) throws -> Version {
            guard let match = try repository.versions(inProject: project.id).first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw CLIError("no release called `\(name)` in \(project.key).")
            }
            return match
        }

        switch rest.first?.lowercased() {
        case nil, "list":
            let versions = try repository.versions(inProject: project.id)
            guard !versions.isEmpty else {
                Output.line("No releases yet. Add one with `localboard versions add 1.0`.")
                return ExitStatus.success
            }
            // Cards and points both, because they disagree and which one a
            // team believes is not this program's decision.
            Output.table(
                headers: ["NAME", "DONE", "POINTS", "SHIPPED"],
                rows: try versions.map { version in
                    let progress = try repository.progress(ofVersion: version.id)
                    return [
                        version.name,
                        "\(progress.done)/\(progress.total)",
                        progress.points == 0
                            ? "—"
                            : "\(Parse.number(progress.donePoints))/\(Parse.number(progress.points))",
                        version.released ? "yes" : "no",
                    ]
                }
            )
            return ExitStatus.success

        case "add":
            let created = try repository.create(
                inProject: project.id,
                name: rest.dropFirst().joined(separator: " "),
                releaseDate: try arguments.option("due").map(Parse.date)
            )
            Output.line("Added \(created.name).")
            return ExitStatus.success

        case "remove", "delete":
            let existing = try version(named: rest.dropFirst().joined(separator: " "))
            try repository.delete(existing.id)
            Output.line("Removed \(existing.name). The cards that were in it are untouched.")
            return ExitStatus.success

        case "release":
            let existing = try version(named: rest.dropFirst().joined(separator: " "))
            try repository.setReleased(true, for: existing.id)
            let progress = try repository.progress(ofVersion: existing.id)
            Output.line(progress.remaining > 0
                ? "\(existing.name) is released, with \(progress.remaining) card\(progress.remaining == 1 ? "" : "s") still open."
                : "\(existing.name) is released.")
            return ExitStatus.success

        case "on":
            let operands = Array(rest.dropFirst())
            guard operands.count >= 2 else {
                throw CLIError("putting a card in a release needs both: `localboard versions on TASK-3 1.0`.")
            }
            let task = try selection.task(tag: operands[0], in: project)
            let existing = try version(named: operands.dropFirst().joined(separator: " "))

            try TaskRepository(database: database).setVersion(existing.id, for: task.id)
            Output.line("\(task.tag(in: project)) is going out in \(existing.name).")
            return ExitStatus.success

        case .some(let unknown):
            throw CLIError("`versions \(unknown)` is not a thing. Try list, add, remove, release or on.")
        }
    }
}

// MARK: - Estimates

/// `localboard points TASK-3 5`, or with no number to clear it.
func pointsCommand(_ arguments: Arguments, database: Database) -> Int32 {
    runCatching {
        let selection = Selection(database: database)
        let project = try selection.project(key: arguments.option("project"))
        let rest = arguments.remainder

        guard let tag = rest.first else {
            throw CLIError("which card? `localboard points TASK-3 5`.")
        }
        let task = try selection.task(tag: tag, in: project)

        guard let raw = rest.dropFirst().first else {
            try TaskRepository(database: database).setEstimate(nil, for: task.id)
            Output.line("\(task.tag(in: project)) is unestimated.")
            return ExitStatus.success
        }
        guard let value = Double(raw) else {
            throw CLIError("`\(raw)` is not a number of points.")
        }

        try TaskRepository(database: database).setEstimate(value, for: task.id)
        Output.line("\(task.tag(in: project)) is \(Parse.number(value)) point\(value == 1 ? "" : "s").")
        return ExitStatus.success
    }
}
