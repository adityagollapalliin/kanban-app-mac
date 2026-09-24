import Foundation
import LocalBoardCore

/// Editing many cards at once, and putting them back.
///
/// Every bulk operation returns what the cards were beforehand. That is the
/// whole design: a bulk edit is the one action where a mis-click costs twenty
/// cards instead of one, so "what did this replace" is captured at the moment
/// of the change rather than reconstructed afterwards from a history that only
/// records status.
extension TaskRepository {

    /// The cards as they stood before a bulk edit, enough to put them back.
    public struct UndoRecord: Sendable, Equatable {
        public let label: String
        public let tasks: [BoardTask]

        public init(label: String, tasks: [BoardTask]) {
            self.label = label
            self.tasks = tasks
        }

        public var isEmpty: Bool { tasks.isEmpty }
    }

    /// A card that has gone missing between selection and action is dropped
    /// rather than failing the whole edit — the other nineteen still want
    /// doing, and there is nothing to put back for a card that is not there.
    private func capture(_ taskIDs: [String], label: String) -> UndoRecord {
        UndoRecord(label: label, tasks: taskIDs.compactMap { try? task(id: $0) })
    }

    // MARK: - Bulk edits

    @discardableResult
    public func moveAll(_ taskIDs: [String], toStatus statusID: String) throws -> UndoRecord {
        let undo = capture(taskIDs, label: "Move")
        try database.transaction {
            // In the order given, each landing after the last, so a selection
            // dragged across keeps the order it was picked up in.
            for taskID in undo.tasks.map(\.id) {
                try move(taskID, toStatus: statusID, after: lastTaskID(inStatus: statusID, excluding: taskIDs))
            }
        }
        return undo
    }

    @discardableResult
    public func setAssigneeAll(_ personID: String?, for taskIDs: [String]) throws -> UndoRecord {
        let undo = capture(taskIDs, label: "Assign")
        try database.transaction {
            for taskID in undo.tasks.map(\.id) { try setAssignee(personID, for: taskID) }
        }
        return undo
    }

    @discardableResult
    public func setPriorityAll(_ priority: Priority, for taskIDs: [String]) throws -> UndoRecord {
        let undo = capture(taskIDs, label: "Set Priority")
        try database.transaction {
            for taskID in undo.tasks.map(\.id) { try setPriority(priority, for: taskID) }
        }
        return undo
    }

    @discardableResult
    public func setFlagAll(_ flagged: Bool, reason: String = "", for taskIDs: [String]) throws -> UndoRecord {
        let undo = capture(taskIDs, label: flagged ? "Flag" : "Unflag")
        try database.transaction {
            for taskID in undo.tasks.map(\.id) { try setFlag(flagged, reason: reason, for: taskID) }
        }
        return undo
    }

    @discardableResult
    public func setVersionAll(_ versionID: String?, for taskIDs: [String]) throws -> UndoRecord {
        let undo = capture(taskIDs, label: "Set Version")
        try database.transaction {
            for taskID in undo.tasks.map(\.id) { try setVersion(versionID, for: taskID) }
        }
        return undo
    }

    @discardableResult
    public func setDueDateAll(_ due: Date?, for taskIDs: [String]) throws -> UndoRecord {
        let undo = capture(taskIDs, label: "Set Due Date")
        try database.transaction {
            for taskID in undo.tasks.map(\.id) { try setDueDate(due, for: taskID) }
        }
        return undo
    }

    @discardableResult
    public func setTrashedAll(_ trashed: Bool, for taskIDs: [String]) throws -> UndoRecord {
        let undo = capture(taskIDs, label: trashed ? "Move to Trash" : "Put Back")
        try database.transaction {
            for taskID in undo.tasks.map(\.id) { try setTrashed(trashed, for: taskID) }
        }
        return undo
    }

    // MARK: - Undo

    /// Writes the captured cards back over whatever is there now.
    ///
    /// Status is restored through the ordinary move, so putting a bulk move
    /// back writes its own history entry rather than rewriting the old one.
    /// The history says the cards went there and came back, which is what
    /// happened.
    public func restore(_ record: UndoRecord) throws {
        try database.transaction {
            for previous in record.tasks {
                guard let current = try? task(id: previous.id) else { continue }

                try update(
                    previous.id,
                    """
                    assignee_id = ?, priority = ?, due_date = ?, version_id = ?,
                    flagged = ?, flag_reason = ?, trashed = ?
                    """,
                    [
                        previous.assigneeID.sqlValue, previous.priority.rawValue,
                        previous.dueDate.sqlValue, previous.versionID.sqlValue,
                        previous.flagged, previous.flagReason, previous.trashed,
                    ]
                )

                if current.statusID != previous.statusID {
                    try move(previous.id, toStatus: previous.statusID, after: nil, before: nil)
                }
            }
        }
    }

    /// The last card in a column, skipping any that are themselves moving.
    private func lastTaskID(inStatus statusID: String, excluding moving: [String]) throws -> String? {
        let excluded = Set(moving)
        return try database.query(
            """
            SELECT id FROM task WHERE status_id = ? AND trashed = 0 ORDER BY sort_order;
            """,
            [statusID]
        ).compactMap { $0.string("id") }.last { !excluded.contains($0) }
    }
}
