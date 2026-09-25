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

    /// Owned here rather than by a view, so that the Settings window and the
    /// board window edit the same people rather than two copies of them.
    public private(set) var board: BoardViewModel?
    public private(set) var startupError: LocalBoardError?

    /// Bumped whenever another process (the `localboard` CLI) commits a change,
    /// so views can refresh. Sampled on window activation — never polled.
    public private(set) var externalChangeCount = 0

    /// Whether the menu bar item is shown, and whether due dates are reminded
    /// about. Both live with the file rather than with the Mac, so they travel
    /// with the boards they are about.
    public private(set) var showsMenuBarExtra = false
    public private(set) var remindsAboutDueDates = false

    private let reminders = DueDateReminders()

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
            board = BoardViewModel(database: opened, paths: resolved)
            lastSeenDataVersion = (try? opened.dataVersion) ?? 0

            let settings = AppSettings(database: opened)
            showsMenuBarExtra = (try? settings.showsMenuBarExtra) ?? false
            remindsAboutDueDates = (try? settings.remindsAboutDueDates) ?? false

            diagnosticsDirectory.record("app.launch version=\(Migration.latestVersion)")
            observeSystemEvents()
            refreshReminders()
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

    // MARK: - Optional extras

    public func setShowsMenuBarExtra(_ on: Bool) {
        guard let database else { return }
        showsMenuBarExtra = on
        try? AppSettings(database: database).setShowsMenuBarExtra(on)
    }

    public func setRemindsAboutDueDates(_ on: Bool) async {
        guard let database else { return }

        // Asking permission only at the moment somebody turns reminders on,
        // rather than at launch: a permission dialog on first run is answered
        // by reflex, and usually with "no".
        if on, await reminders.requestPermission() == false {
            remindsAboutDueDates = false
            try? AppSettings(database: database).setRemindsAboutDueDates(false)
            return
        }

        remindsAboutDueDates = on
        try? AppSettings(database: database).setRemindsAboutDueDates(on)

        if on { refreshReminders() } else { Task { await reminders.cancelAll() } }
    }

    /// Rewrites the scheduled reminders from what is on the board now.
    public func refreshReminders() {
        guard remindsAboutDueDates, let board else { return }

        let tasks = board.snapshot?.columns.flatMap(\.tasks) ?? []
        let tags = Dictionary(tasks.map { ($0.id, board.tag(for: $0)) },
                              uniquingKeysWith: { first, _ in first })
        let standalone = board.reminders
        Task {
            await reminders.reschedule(for: tasks, tags: tags)
            await reminders.reschedule(reminders: standalone)
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
