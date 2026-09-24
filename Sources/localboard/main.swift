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

func printUsage() {
    Output.line("""
        \(AppIdentity.displayName) — local-only Kanban and project management.

        USAGE
          localboard                     Open the app
          localboard where               Print the data, diagnostics and attachment folders
          localboard version             Print the app and schema versions
          localboard help                Show this message

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
    var failure: (any Error)?
    workspace.openApplication(at: application, configuration: configuration) { _, error in
        failure = error
        group.leave()
    }
    group.wait()

    if let failure {
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
case "add", "list", "seed", "export":
    Output.error("`\(arguments.subcommand ?? "")` arrives with the Kanban milestone. Run `localboard help` for what works today.")
    status = ExitStatus.usage
case .some(let unknown):
    Output.error("unknown command `\(unknown)`")
    printUsage()
    status = ExitStatus.usage
}

exit(status)
