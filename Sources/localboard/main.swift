import AppKit
import Foundation
import LocalBoardCore
import LocalBoardStore

// The `localboard` shim.
//
// Two things it deliberately does not do:
//  * It never starts a subprocess. Launching the app goes through Launch
//    Services (`NSWorkspace`), so `Scripts/verify-no-network.sh` can ban
//    `Process(` outright and the CLI cannot be turned into a curl wrapper.
//  * It never opens a socket, because nothing here has any reason to.
//
// It reaches the data by opening the same SQLite file the app uses, in WAL
// mode with a busy timeout, so both processes can be running at once.

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))

/// The CLI is not sandboxed, so it resolves the container path explicitly
/// rather than asking FileManager, which would hand it the wrong directory.
func resolvePaths() throws -> ContainerPaths {
    try ContainerPaths.resolve(host: .externalTool)
}

func openDatabase() throws -> Database {
    let paths = try resolvePaths()
    return try Database.openBoardDatabase(paths: paths)
}

/// Opens the board, runs the command, and closes again. The app may well be
/// running against the same file; WAL and a busy timeout are what make that
/// safe, and holding the handle no longer than needed is the other half.
func withDatabase(_ body: (Database) -> Int32) -> Int32 {
    do {
        let database = try openDatabase()
        defer { database.close() }
        return body(database)
    } catch let error as LocalBoardError {
        Output.error(error.errorDescription ?? "Could not open the board.")
        if let suggestion = error.recoverySuggestion { Output.error(suggestion) }
        return ExitStatus.failure
    } catch {
        Output.error(error.localizedDescription)
        return ExitStatus.failure
    }
}

func printUsage() {
    Output.line("""
        \(AppIdentity.displayName) — local-only Kanban and project management.

        USAGE
          localboard                     Open the app
          localboard add <title>         Add a card
          localboard list                List the cards
          localboard seed                Add sample cards
          localboard export              Write the project as JSON on stdout
          localboard trash <ID>          Move a card to the trash
          localboard restore <ID>        Take it back out again
          localboard labels              List, add or remove labels; put one on a card
          localboard columns             List, add or remove the board's columns
          localboard people              List, add or remove people
          localboard views               List, save or remove saved views
          localboard where               Print the data, diagnostics and attachment folders
          localboard version             Print the app and schema versions
          localboard help                Show this message

        OPTIONS
          --project <KEY>                Which project, when there is more than one
          --status "<name>"              Which column. Defaults to the first one
          --type epic|story|task|bug     Card type for `add`
          --priority lowest..highest     Card priority for `add`
          --due YYYY-MM-DD               Due date for `add`
          --notes "<text>"               Notes for `add`
          --assignee "<name>"            Who the card is for, on `add`
          --query "<filter>"             Filter `list` with the search language
          --view "<name>"                Run a saved view with `list`
          --color <name>                 Colour for `labels add`
          --counts-as todo|progress|done Category for `columns add`
          --move-to "<column>"           Where cards go when removing a column
          --off                          Take a label off, with `labels on`
          --all                          Include trashed cards in list and export

        QUERY LANGUAGE
          localboard list --query "due < +7d priority >= high"
          localboard list --query "is:overdue not type:epic"
          localboard list --query 'status = "In Progress" or is:done'

          Fields    due start created updated completed priority type status
                    title assignee
          Flags     is:done is:open is:overdue is:trashed is:assigned
                    is:unassigned
          Dates     2026-10-01, today, tomorrow, yesterday, +7d, -2w
          Joining   terms side by side mean all of them; `or`, `not` and
                    parentheses do what they look like

          Save one with `localboard views save "This week" "due < +7d"`,
          then run it with `localboard list --view "This week"`.

        Everything runs on this Mac. localboard makes no network connections.
        """)
}

func openApp() -> Int32 {
    let workspace = NSWorkspace.shared

    guard let application = workspace.urlForApplication(withBundleIdentifier: AppIdentity.bundleIdentifier) else {
        Output.error("""
            \(AppIdentity.displayName) is not installed where Launch Services can find it.
            Run `make install` from the project folder, then try again.
            """)
        return ExitStatus.failure
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true

    let group = DispatchGroup()
    group.enter()
    let result = LaunchResult()
    workspace.openApplication(at: application, configuration: configuration) { _, error in
        result.record(error)
        group.leave()
    }
    group.wait()

    if let failure = result.failure {
        Output.error("Could not open \(AppIdentity.displayName): \(failure.localizedDescription)")
        return ExitStatus.failure
    }
    return ExitStatus.success
}

func printLocations() -> Int32 {
    do {
        let paths = try resolvePaths()
        let exists = FileManager.default.fileExists(atPath: paths.databaseFile.path)
        Output.table(
            headers: ["WHAT", "WHERE"],
            rows: [
                ["data", paths.dataDirectory.path],
                ["database", paths.databaseFile.path + (exists ? "" : "  (not created yet)")],
                ["diagnostics", paths.diagnosticsDirectory.path],
                ["attachments", paths.attachmentsDirectory.path],
            ]
        )
        Output.line()
        Output.line("Diagnostics older than 24 hours are deleted automatically.")
        return ExitStatus.success
    } catch let error as LocalBoardError {
        Output.error(error.errorDescription ?? "Could not resolve the data folders.")
        if let suggestion = error.recoverySuggestion { Output.error(suggestion) }
        return ExitStatus.failure
    } catch {
        Output.error(error.localizedDescription)
        return ExitStatus.failure
    }
}

func printVersion() -> Int32 {
    Output.line("\(AppIdentity.displayName) \(BuildInfo.marketingVersion) (schema \(Migration.latestVersion))")
    return ExitStatus.success
}

let status: Int32
switch arguments.subcommand {
case nil:
    status = openApp()
case "where":
    status = printLocations()
case "version", "--version":
    status = printVersion()
case "help", "--help":
    printUsage()
    status = ExitStatus.success
case "add":
    status = withDatabase { addCommand(arguments, database: $0) }
case "list":
    status = withDatabase { listCommand(arguments, database: $0) }
case "seed":
    status = withDatabase { seedCommand(arguments, database: $0) }
case "export":
    status = withDatabase { exportCommand(arguments, database: $0) }
case "people":
    status = withDatabase { peopleCommand(arguments, database: $0) }
case "views":
    status = withDatabase { viewsCommand(arguments, database: $0) }
case "trash":
    status = withDatabase { trashCommand(arguments, database: $0, trashed: true) }
case "restore":
    status = withDatabase { trashCommand(arguments, database: $0, trashed: false) }
case "labels":
    status = withDatabase { labelsCommand(arguments, database: $0) }
case "columns":
    status = withDatabase { columnsCommand(arguments, database: $0) }
case .some(let unknown):
    Output.error("unknown command `\(unknown)`")
    printUsage()
    status = ExitStatus.usage
}

exit(status)
