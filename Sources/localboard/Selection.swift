import Foundation
import LocalBoardCore
import LocalBoardStore

/// A problem with what was typed at the terminal.
///
/// LocalBoardError's cases are written for the app's error surface — the
/// `notFound` wording is "That … no longer exists", which is right for a card
/// that vanished from under a click and wrong for a project key that was never
/// spelled correctly. These read as one plain line instead.
struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Turning what the user typed into the rows a command needs.
///
/// Every lookup is by the name or key the user can actually see — `--project
/// WORK`, `--status "In Progress"` — never by a UUID, which is not something
/// anyone is going to type.
struct Selection {

    let database: Database
    private let boards: BoardRepository

    init(database: Database) {
        self.database = database
        self.boards = BoardRepository(database: database)
    }

    /// Every project across every workspace, in sidebar order.
    func allProjects() throws -> [Project] {
        try boards.workspaces().flatMap { try boards.projects(inWorkspace: $0.id) }
    }

    /// The project a command acts on: the one named by `--project`, or the
    /// only one there is.
    func project(key: String?) throws -> Project {
        let projects = try allProjects()

        guard !projects.isEmpty else {
            throw CLIError("there are no projects yet. Open the app once and it will make one.")
        }

        guard let key else {
            guard projects.count == 1 else {
                let keys = projects.map(\.key).joined(separator: ", ")
                throw CLIError("there is more than one project. Pick one with --project: \(keys).")
            }
            return projects[0]
        }

        guard let match = projects.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else {
            let keys = projects.map(\.key).joined(separator: ", ")
            throw CLIError("no project with the key `\(key)`. Known projects: \(keys).")
        }
        return match
    }

    /// A status by name, or the first column of the project when unspecified —
    /// which is where a new card belongs.
    func status(named name: String?, in project: Project) throws -> Status {
        let statuses = try boards.statuses(inProject: project.id)

        guard !statuses.isEmpty else {
            throw CLIError("\(project.key) has no columns yet.")
        }

        guard let name else { return statuses[0] }

        guard let match = statuses.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            let names = statuses.map { "\"\($0.name)\"" }.joined(separator: ", ")
            throw CLIError("no column called `\(name)`. This project has: \(names).")
        }
        return match
    }

    /// Finds a card by the tag printed on it — `TASK-3`, or just `3` when the
    /// project is unambiguous.
    func task(tag: String, in project: Project) throws -> BoardTask {
        let digits = tag.split(separator: "-").last.map(String.init) ?? tag
        guard let number = Int(digits) else {
            throw CLIError("`\(tag)` is not a card. They look like \(project.key)-3.")
        }

        do {
            return try TaskRepository(database: database).task(number: number, inProject: project.id)
        } catch {
            throw CLIError("\(project.key) has no card numbered \(number).")
        }
    }

    func statuses(in project: Project) throws -> [Status] {
        try boards.statuses(inProject: project.id)
    }
}

// MARK: - Parsing what was typed

enum Parse {

    /// One formatter for reading and writing `yyyy-MM-dd`, so a date typed in
    /// and a date printed back cannot disagree.
    ///
    /// The time zone has to be the local one at both ends. A due date is a day
    /// on the user's calendar, not an instant: parsing `2026-10-15` gives
    /// midnight local, and rendering that same value in UTC would print the
    /// 14th for anyone east of Greenwich.
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// Points, without the trailing `.0` on a whole number — teams write 3,
    /// not 3.0, and a table full of `.0` is harder to scan.
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    /// `--due 2026-10-01`.
    static func date(_ text: String) throws -> Date {
        let formatter = dayFormatter

        guard let date = formatter.date(from: text) else {
            throw CLIError("dates look like 2026-10-01. `\(text)` does not.")
        }
        return date
    }

    static func type(_ text: String) throws -> TaskType {
        switch text.lowercased() {
        case "epic": .epic
        case "story": .story
        case "task": .task
        case "bug": .bug
        default:
            throw CLIError("--type is one of epic, story, task or bug. `\(text)` is not one.")
        }
    }

    static func priority(_ text: String) throws -> Priority {
        switch text.lowercased() {
        case "lowest": .lowest
        case "low": .low
        case "normal": .normal
        case "high": .high
        case "highest": .highest
        default:
            throw CLIError("--priority is one of lowest, low, normal, high or highest. `\(text)` is not one.")
        }
    }
}

// MARK: - Rendering

extension Priority {
    var shortLabel: String {
        switch self {
        case .lowest: "lowest"
        case .low: "low"
        case .normal: "normal"
        case .high: "HIGH"
        case .highest: "HIGHEST"
        }
    }
}

extension TaskType {
    var shortLabel: String {
        switch self {
        case .epic: "epic"
        case .story: "story"
        case .task: "task"
        case .bug: "bug"
        }
    }
}

extension BoardTask {
    func tag(in project: Project) -> String { "\(project.key)-\(number)" }
}
