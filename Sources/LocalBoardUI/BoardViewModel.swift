import Foundation
import Observation
import LocalBoardCore
import LocalBoardStore

/// The board's state, and the only place a view touches the database.
///
/// Reads are synchronous and run on the main actor. That is a deliberate choice
/// for a local SQLite file rather than an oversight: a board query is indexed,
/// returns at most a few thousand rows, and completes well inside a frame. The
/// day that stops being true, this is the one type that has to change.
@MainActor
@Observable
public final class BoardViewModel {

    public private(set) var workspaces: [Workspace] = []
    public private(set) var projects: [Project] = []
    public private(set) var boards: [Board] = []
    public private(set) var snapshot: BoardSnapshot?

    /// What went wrong with the last action. Shown, then dismissed by the next
    /// successful one — an error the user cannot clear is an error they learn
    /// to ignore.
    public private(set) var failure: LocalBoardError?

    public var selectedBoardID: String? {
        didSet {
            guard selectedBoardID != oldValue else { return }
            reloadSnapshot()
        }
    }

    /// The card open in the inspector. Cleared when the card leaves the board,
    /// so closing is never something the user has to do after a trash.
    public var selectedTaskID: String?

    public var selectedTask: BoardTask? {
        guard let selectedTaskID else { return nil }
        return snapshot?.columns.lazy.flatMap(\.tasks).first { $0.id == selectedTaskID }
    }

    /// The statuses this board shows, in column order — what the inspector's
    /// status picker offers.
    public var statuses: [Status] {
        snapshot?.columns.map(\.status) ?? []
    }

    private let database: Database
    private let boardRepository: BoardRepository
    private let taskRepository: TaskRepository

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.boardRepository = BoardRepository(database: database, clock: clock)
        self.taskRepository = TaskRepository(database: database, clock: clock)
    }

    // MARK: - Loading

    /// Called once when the board appears, and again whenever another process
    /// commits a change.
    public func load() {
        perform {
            // Idempotent: on an existing file this only finds the first board.
            let starter = try boardRepository.ensureStarterContent()
            workspaces = try boardRepository.workspaces()

            projects = try workspaces.flatMap { try boardRepository.projects(inWorkspace: $0.id) }
            boards = try projects.flatMap { try boardRepository.boards(inProject: $0.id) }

            // Keep the user where they were across a reload; fall back to the
            // starter board, then to whatever exists.
            if let current = selectedBoardID, boards.contains(where: { $0.id == current }) {
                reloadSnapshot()
            } else {
                selectedBoardID = starter?.id ?? boards.first?.id
            }
        }
    }

    private func reloadSnapshot() {
        guard let selectedBoardID else {
            snapshot = nil
            return
        }
        perform { snapshot = try boardRepository.snapshot(boardID: selectedBoardID) }
    }

    public func project(for board: Board) -> Project? {
        projects.first { $0.id == board.projectID }
    }

    /// The prefix shown on every card: WORK-14.
    public func tag(for task: BoardTask) -> String {
        let key = projects.first { $0.id == task.projectID }?.key ?? "TASK"
        return "\(key)-\(task.number)"
    }

    // MARK: - Acting

    public func addTask(title: String, toStatus statusID: String) {
        guard let projectID = snapshot?.columns.first?.status.projectID else { return }
        perform {
            try taskRepository.create(inProject: projectID, statusID: statusID, title: title)
            reloadSnapshot()
        }
    }

    /// Drops a card into a column, either above a specific card or at the end.
    public func move(_ taskID: String, toStatus statusID: String, before: String? = nil) {
        // Dropping a card onto itself is a no-op, not a move to nowhere.
        guard taskID != before else { return }

        perform {
            let after = try neighbourAbove(before: before, inStatus: statusID, moving: taskID)
            try taskRepository.move(taskID, toStatus: statusID, after: after, before: before)
            reloadSnapshot()
        }
    }

    /// The card a drop should land after: the one above `before` in the
    /// destination column, skipping the card being moved.
    private func neighbourAbove(before: String?, inStatus statusID: String, moving taskID: String) throws -> String? {
        let column = try taskRepository.tasks(
            inProject: snapshot?.board.projectID ?? "",
            statusID: statusID
        ).filter { $0.id != taskID }

        guard let before else { return column.last?.id }
        guard let index = column.firstIndex(where: { $0.id == before }), index > 0 else { return nil }
        return column[index - 1].id
    }

    public func setTrashed(_ trashed: Bool, for taskID: String) {
        perform {
            try taskRepository.setTrashed(trashed, for: taskID)
            if trashed, selectedTaskID == taskID { selectedTaskID = nil }
            reloadSnapshot()
        }
    }

    public func rename(_ taskID: String, to title: String) {
        perform {
            try taskRepository.setTitle(title, for: taskID)
            reloadSnapshot()
        }
    }

    public func setDescription(_ markdown: String, for taskID: String) {
        perform {
            try taskRepository.setDescription(markdown, for: taskID)
            reloadSnapshot()
        }
    }

    public func setType(_ type: TaskType, for taskID: String) {
        perform {
            try taskRepository.setType(type, for: taskID)
            reloadSnapshot()
        }
    }

    public func setPriority(_ priority: Priority, for taskID: String) {
        perform {
            try taskRepository.setPriority(priority, for: taskID)
            reloadSnapshot()
        }
    }

    public func setDueDate(_ due: Date?, for taskID: String) {
        perform {
            try taskRepository.setDueDate(due, for: taskID)
            reloadSnapshot()
        }
    }

    /// Sends a card to the end of another column — the inspector's equivalent
    /// of dragging it there.
    public func moveToEnd(of statusID: String, taskID: String) {
        move(taskID, toStatus: statusID, before: nil)
    }

    // MARK: - Error handling

    /// Every database call the views make comes through here, so no view has a
    /// `try` in it and no failure can reach the user as a crash.
    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            failure = nil
        } catch let error as LocalBoardError {
            failure = error
            Log.app.error("Board action failed: \(String(describing: error.errorDescription), privacy: .public)")
        } catch {
            failure = .databaseQueryFailed(detail: error.localizedDescription)
            Log.app.error("Board action failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func dismissFailure() {
        failure = nil
    }
}
