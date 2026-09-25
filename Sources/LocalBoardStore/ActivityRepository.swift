import Foundation
import LocalBoardCore

/// What happened, in order.
///
/// Derived rather than recorded. Everything the feed shows is already in the
/// file — a card's creation, its status changes, its comments, its attached
/// files, its logged hours — so an `activity` table would be a second copy of
/// facts the app already has, kept in step by hand at every mutation site.
/// The cost of deriving it is one query per kind when the screen opens; the
/// cost of recording it would be a lifetime of remembering to.
public struct ActivityRepository {

    public struct Entry: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case created
            case statusChanged(from: String?, to: String)
            case commented(String)
            case attached(String)
            case logged(minutes: Int)
            case completed

            public var symbol: String {
                switch self {
                case .created: "plus.circle"
                case .statusChanged: "arrow.right.circle"
                case .commented: "text.bubble"
                case .attached: "paperclip"
                case .logged: "timer"
                case .completed: "checkmark.circle"
                }
            }
        }

        public let id: String
        public let taskID: String
        public let kind: Kind
        public let at: Date

        public init(id: String, taskID: String, kind: Kind, at: Date) {
            self.id = id
            self.taskID = taskID
            self.kind = kind
            self.at = at
        }
    }

    let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// The feed for a project, newest first.
    ///
    /// `limit` is applied after merging, so a noisy afternoon of comments
    /// cannot crowd the status changes out of the answer — each source is
    /// read in full for the window, then the window is cut.
    public func feed(inProject projectID: String, limit: Int = 200) throws -> [Entry] {
        var entries: [Entry] = []

        for row in try database.query(
            """
            SELECT status_change.*, task.project_id AS project_id FROM status_change
            JOIN task ON task.id = status_change.task_id
            WHERE task.project_id = ? AND task.trashed = 0
            ORDER BY status_change.at DESC LIMIT ?;
            """,
            [projectID, limit]
        ) {
            let change = try StatusChange(row: row)
            entries.append(Entry(
                id: change.id,
                taskID: change.taskID,
                // A card's first status change is its creation: it did not
                // move there, it started there.
                kind: change.fromStatusID == nil
                    ? .created
                    : .statusChanged(from: change.fromStatusID, to: change.toStatusID),
                at: change.at
            ))
        }

        for row in try database.query(
            """
            SELECT comment.* FROM comment
            JOIN task ON task.id = comment.task_id
            WHERE task.project_id = ? AND task.trashed = 0
            ORDER BY comment.created_at DESC LIMIT ?;
            """,
            [projectID, limit]
        ) {
            let comment = try Comment(row: row)
            entries.append(Entry(
                id: comment.id, taskID: comment.taskID,
                kind: .commented(comment.bodyMarkdown), at: comment.createdAt
            ))
        }

        for row in try database.query(
            """
            SELECT attachment.* FROM attachment
            JOIN task ON task.id = attachment.task_id
            WHERE task.project_id = ? AND task.trashed = 0
            ORDER BY attachment.added_at DESC LIMIT ?;
            """,
            [projectID, limit]
        ) {
            let attachment = try Attachment(row: row)
            entries.append(Entry(
                id: attachment.id, taskID: attachment.taskID,
                kind: .attached(attachment.filename), at: attachment.addedAt
            ))
        }

        for row in try database.query(
            """
            SELECT work_log.* FROM work_log
            JOIN task ON task.id = work_log.task_id
            WHERE task.project_id = ? AND task.trashed = 0
            ORDER BY work_log.created_at DESC LIMIT ?;
            """,
            [projectID, limit]
        ) {
            let entry = try WorkLogEntry(row: row)
            entries.append(Entry(
                id: entry.id, taskID: entry.taskID,
                kind: .logged(minutes: entry.minutes), at: entry.createdAt
            ))
        }

        return entries.sorted { $0.at > $1.at }.prefix(limit).map { $0 }
    }

    /// One card's own history, for the panel that shows it.
    public func feed(ofTask taskID: String) throws -> [Entry] {
        try feed(inProject: try projectID(ofTask: taskID)).filter { $0.taskID == taskID }
    }

    private func projectID(ofTask taskID: String) throws -> String {
        guard let row = try database.queryOne("SELECT project_id FROM task WHERE id = ?;", [taskID]),
              let projectID = row.string("project_id") else {
            throw LocalBoardError.notFound(entity: "task \(taskID)")
        }
        return projectID
    }
}
