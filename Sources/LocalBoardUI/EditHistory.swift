import Foundation
import LocalBoardCore
import LocalBoardStore

/// Undo and redo for card edits.
///
/// One mechanism for one card and for twenty: an edit captures what the cards
/// were beforehand, and undoing writes that back. Two separate systems — one
/// for bulk actions, one for ordinary edits — would be one too many, and the
/// one people reach for would inevitably be the one that was not wired up.
///
/// What it deliberately does **not** cover: anything living in another table.
/// Labels, checklists, comments and links are not card fields, and an undo
/// stack that silently restored some of an action but not all of it would be
/// worse than one that admits its limits. Those actions simply do not go on
/// the stack, so Undo never claims to reverse something it cannot.
struct EditHistory {

    /// How far back it goes. Deep enough to cover a bad five minutes, shallow
    /// enough that the stack is never itself the thing using the memory.
    static let depth = 50

    private var undoStack: [TaskRepository.UndoRecord] = []
    private var redoStack: [TaskRepository.UndoRecord] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    /// Records an edit that has just happened.
    ///
    /// A new edit clears the redo stack, because the future it led to is no
    /// longer the one the user is in.
    mutating func record(_ record: TaskRepository.UndoRecord) {
        guard !record.isEmpty else { return }
        undoStack.append(record)
        if undoStack.count > Self.depth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Takes the next thing to undo, handing back what to restore and asking
    /// for the state it is about to replace so redo can put it back.
    mutating func popUndo(currentState: (TaskRepository.UndoRecord) -> TaskRepository.UndoRecord)
        -> TaskRepository.UndoRecord? {
        guard let record = undoStack.popLast() else { return nil }
        redoStack.append(currentState(record))
        return record
    }

    mutating func popRedo(currentState: (TaskRepository.UndoRecord) -> TaskRepository.UndoRecord)
        -> TaskRepository.UndoRecord? {
        guard let record = redoStack.popLast() else { return nil }
        undoStack.append(currentState(record))
        return record
    }

    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
