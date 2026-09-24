import AppKit
import Foundation
import Observation
import LocalBoardCore
import LocalBoardStore

/// Everything the views need, assembled once at launch.
///
/// Launch-time budget: the container directories are created and the database
/// is opened here, but nothing is *read* from it until a view asks. Migrations
/// are a no-op when `user_version` already matches, which is the usual case, so
/// this stays well inside the one-second budget.
@MainActor
@Observable
public final class AppEnvironment {

    public private(set) var paths: ContainerPaths?
    public private(set) var database: Database?
    public private(set) var diagnostics: DiagnosticsDirectory?
    public private(set) var startupError: LocalBoardError?

    /// Bumped whenever another process (the `localboard` CLI) commits a change,
    /// so views can refresh. Sampled on window activation — never polled.
    public private(set) var externalChangeCount = 0

    private var maintenance: DiagnosticsMaintenance?
    private var lastSeenDataVersion: Int64 = 0
    private var wakeObserver: (any NSObjectProtocol)?
    private var activationObserver: (any NSObjectProtocol)?

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        do {
            let resolved = try ContainerPaths.resolve()
            try resolved.createDirectoriesIfNeeded()
            paths = resolved

            let diagnosticsDirectory = DiagnosticsDirectory(paths: resolved)
            diagnostics = diagnosticsDirectory

            // Rule 4: purge before anything else happens, every single launch.
            let maintainer = DiagnosticsMaintenance(directory: diagnosticsDirectory)
            maintainer.start()
            maintenance = maintainer

            let opened = try Database.openBoardDatabase(paths: resolved)
            database = opened
            lastSeenDataVersion = (try? opened.dataVersion) ?? 0

            diagnosticsDirectory.record("app.launch version=\(Migration.latestVersion)")
            observeSystemEvents()
        } catch let error as LocalBoardError {
            startupError = error
            Log.app.error("Startup failed: \(String(describing: error.errorDescription), privacy: .public)")
        } catch {
            startupError = .containerUnavailable(reason: error.localizedDescription)
        }
    }

    public func stop() {
        maintenance?.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        database?.close()
    }

    // MARK: - Event-driven refresh

    private func observeSystemEvents() {
        // A Mac asleep past the retention window purges the moment it wakes,
        // instead of waiting for the next timer tick.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.maintenance?.purgeNow()
                self?.checkForExternalChanges()
            }
        }

        // Cheap, event-driven way to notice CLI writes: one PRAGMA read when the
        // app is brought forward. No timer, no file watcher, no idle CPU.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForExternalChanges()
            }
        }
    }

    public func checkForExternalChanges() {
        guard let database else { return }
        guard let current = try? database.dataVersion else { return }
        guard current != lastSeenDataVersion else { return }
        lastSeenDataVersion = current
        externalChangeCount += 1
    }
}
