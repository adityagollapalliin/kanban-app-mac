import Foundation
import LocalBoardCore
import LocalBoardStore

/// Moving around the board without the mouse.
///
/// Focus is deliberately a third thing, alongside the open card and the picked
/// cards. Arrow keys have to be able to travel across a board without opening
/// twenty cards on the way, and without destroying a selection someone spent
/// six clicks building.
@MainActor
extension BoardViewModel {

    /// Every card on the board as the keyboard sees it: by column, in the
    /// order drawn. On a laned board the lanes are stacked within each column,
    /// which is how they are read.
    public var grid: BoardGrid {
        guard isLaned else {
            return BoardGrid(columns: visibleColumns.map { $0.tasks.map(\.id) })
        }

        var stacked: [[String]] = Array(repeating: [], count: visibleColumns.count)
        for lane in lanes {
            for (index, column) in columns(in: lane).enumerated() where index < stacked.count {
                stacked[index].append(contentsOf: column.tasks.map(\.id))
            }
        }
        return BoardGrid(columns: stacked)
    }

    public var focusedTask: BoardTask? {
        guard let focusedTaskID else { return nil }
        return task(id: focusedTaskID)
    }

    /// The column the keyboard is in, which is where ⌘N adds a card.
    public var focusedColumn: LoadedColumn? {
        guard let focusedTaskID else { return nil }
        return visibleColumns.first { $0.tasks.contains { $0.id == focusedTaskID } }
    }

    /// Moves the keyboard's focus. Returns whether it went anywhere, so the
    /// view can leave the keypress unhandled — and let the scroll view have
    /// it — when the board ends there.
    @discardableResult
    public func moveFocus(_ direction: BoardDirection) -> Bool {
        let grid = grid

        // Nothing focused yet: the first arrow key picks up where the eye
        // already is — the open card, then the first pick, then the top left.
        guard let current = focusedTaskID, grid.contains(current) else {
            focusedTaskID = selectedTaskID ?? selectedTaskIDs.first ?? grid.firstCard
            return focusedTaskID != nil
        }

        guard let next = grid.neighbour(of: current, going: direction) else { return false }
        focusedTaskID = next
        return true
    }

    public func focus(_ taskID: String?) {
        focusedTaskID = taskID
    }

    /// Opens the focused card in the inspector. Enter rather than click: the
    /// keyboard's equivalent of the thing the mouse does.
    public func openFocused() {
        guard let focusedTaskID else { return }
        selectedTaskID = focusedTaskID
    }

    /// Adds the focused card to the picked set, or takes it out again. Space,
    /// because it is the one key that means "this one too" everywhere else.
    public func togglePickFocused() {
        guard let focusedTaskID else { return }
        togglePicked(focusedTaskID)
    }

    /// ⌘← and ⌘→: moves the card itself rather than the focus.
    ///
    /// Sideways moves the card to the next column along, including an empty
    /// one — unlike focus, which steps over empty columns because there is
    /// nothing there to land on.
    public func moveFocusedCard(step: Int) {
        guard let focusedTaskID, let index = grid.adjacentColumn(of: focusedTaskID, step: step),
              visibleColumns.indices.contains(index) else { return }
        move(focusedTaskID, toStatus: visibleColumns[index].status.id)
    }

    /// ⌘↑ and ⌘↓: reorders within the column the card is already in.
    public func reorderFocusedCard(offset: Int) {
        guard let focusedTaskID, let column = focusedColumn,
              let row = column.tasks.firstIndex(where: { $0.id == focusedTaskID }) else { return }

        let destination = row + offset
        guard column.tasks.indices.contains(destination) else { return }

        if offset < 0 {
            move(focusedTaskID, toStatus: column.status.id, before: column.tasks[destination].id)
        } else if destination + 1 < column.tasks.count {
            move(focusedTaskID, toStatus: column.status.id, before: column.tasks[destination + 1].id)
        } else {
            moveToEnd(of: column.status.id, taskID: focusedTaskID)
        }
        // The move rewrote sort orders; keep the keyboard on the card it moved
        // rather than on whatever now occupies that row.
        self.focusedTaskID = focusedTaskID
    }

    /// ⌘N. Opens the add-a-card field where the keyboard already is, rather
    /// than always in the first column — someone working in Review wants the
    /// new card in Review.
    public func requestQuickAdd() {
        quickAddStatusID = focusedColumn?.status.id ?? visibleColumns.first?.status.id
        quickAddToken += 1
    }
}

// MARK: - The same cards, flat

@MainActor
extension BoardViewModel {

    /// Every card the board is currently showing, in column order.
    ///
    /// The list and the calendar are the same board read differently, so they
    /// read the same filtered set — a quick filter applies to all three, and
    /// "showing 3 of 12" means the same thing on each.
    public var visibleTasks: [BoardTask] {
        visibleColumns.flatMap(\.tasks)
    }

    /// How many days in a column counts as stale on this board.
    public var staleDays: Int { snapshot?.board.staleDays ?? 3 }

    /// The name of the column a card sits in, which is what a list shows
    /// rather than the status id.
    public func columnName(for task: BoardTask) -> String {
        visibleColumns.first { $0.tasks.contains { $0.id == task.id } }?.name
            ?? statusName(task.statusID)
    }
}
