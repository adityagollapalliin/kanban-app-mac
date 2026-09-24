import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The columns, drawn either straight across or cut into lanes.
///
/// One view for both because they are the same board: a lane is a horizontal
/// slice of the same columns, and giving each its own renderer would be two
/// places for the drop behaviour and the WIP arithmetic to drift apart.
struct BoardCanvas: View {

    let model: BoardViewModel
    var onOpenInWindow: ((String) -> Void)?
    var onAddColumn: () -> Void

    @State private var lasso: Lasso?
    @State private var frames: [String: CGRect] = [:]
    @FocusState private var hasKeyboard: Bool

    /// Named so that card frames and the drag are measured against the same
    /// origin, and stay in step as the board scrolls.
    private static let space = "board"

    var body: some View {
        // A plain board scrolls sideways only, and each column scrolls itself.
        // This is not a style choice: a column's `LazyVStack` inside a view
        // that also scrolls vertically is handed unbounded height, decides all
        // of itself is visible, and builds every card — a thousand-card board
        // then costs half a gigabyte. Bounding the height is what makes the
        // laziness real. A laned board still needs the vertical axis, because
        // the lanes themselves stack down the page.
        ScrollView(model.isLaned ? [.horizontal, .vertical] : [.horizontal]) {
            Group {
                if model.isLaned {
                    lanedBoard
                } else {
                    plainBoard
                }
            }
            // Behind the columns, so a drag starting on a card still drags the
            // card and only a drag starting on empty board draws a lasso.
            .background(lassoCatcher)
            .overlay { if let lasso, lasso.isMeaningful { LassoOverlay(lasso: lasso) } }
            .onPreferenceChange(CardFrames.self) { frames = $0 }
            .coordinateSpace(name: Self.space)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The board itself takes the keyboard, so arrow keys move between
        // cards rather than scrolling the view out from under them. A text
        // field being edited holds focus instead, which is why the add-a-card
        // field still works while this is here.
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboard)
        .onAppear { hasKeyboard = true }
        .onKeyPress(phases: .down, action: handleKey)
        .accessibilityLabel("Board")
        .accessibilityHint("Arrow keys move between cards. Return opens one, space selects it.")
    }

    /// One handler rather than a dozen `onKeyPress(.upArrow)` modifiers: the
    /// modifier decides whether a key moves the focus or moves the card, and
    /// splitting that across two places is how the two drift apart.
    ///
    /// Anything not claimed here is returned as `.ignored`, so the scroll view
    /// and the text fields still get the keys they expect.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)

        switch press.key {
        case .upArrow:
            if command { model.reorderFocusedCard(offset: -1); return .handled }
            return model.moveFocus(.up) ? .handled : .ignored
        case .downArrow:
            if command { model.reorderFocusedCard(offset: 1); return .handled }
            return model.moveFocus(.down) ? .handled : .ignored
        case .leftArrow:
            if command { model.moveFocusedCard(step: -1); return .handled }
            return model.moveFocus(.left) ? .handled : .ignored
        case .rightArrow:
            if command { model.moveFocusedCard(step: 1); return .handled }
            return model.moveFocus(.right) ? .handled : .ignored
        case .return:
            guard model.focusedTaskID != nil else { return .ignored }
            model.openFocused()
            return .handled
        case .space:
            guard model.focusedTaskID != nil else { return .ignored }
            model.togglePickFocused()
            return .handled
        case .escape:
            // Escape gives everything back: the picks, then the focus.
            if model.hasSelection { model.clearPicks(); return .handled }
            if model.focusedTaskID != nil { model.focus(nil); return .handled }
            return .ignored
        case .delete, .deleteForward:
            guard let focused = model.focusedTaskID else { return .ignored }
            // Focus moves on before the card goes, so the next press has
            // somewhere to be rather than falling back to the first card.
            let next = model.grid.neighbour(of: focused, going: .down)
                ?? model.grid.neighbour(of: focused, going: .up)
            model.setTrashed(true, for: focused)
            model.focus(next)
            return .handled
        default:
            return .ignored
        }
    }

    /// The empty board, which is both where a lasso starts and what you click
    /// to clear a selection.
    private var lassoCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        if lasso == nil {
                            lasso = Lasso(start: value.startLocation, current: value.location)
                            // Shift or ⌘ adds to what is already picked; a
                            // plain drag starts again, exactly as a click does.
                            let adding = NSEvent.modifierFlags.contains(.shift)
                                || NSEvent.modifierFlags.contains(.command)
                            if !adding { model.clearPicks() }
                        }
                        lasso?.current = value.location
                        guard let lasso, lasso.isMeaningful else { return }
                        model.pick(frames.filter { lasso.covers($0.value) }.map(\.key), adding: true)
                    }
                    .onEnded { _ in
                        // A drag too small to be a lasso was a click on empty
                        // space, which means "never mind".
                        if lasso?.isMeaningful != true { model.clearPicks() }
                        lasso = nil
                    }
            )
    }

    private var plainBoard: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(model.visibleColumns) { column in
                BoardColumnView(
                    column: column, model: model,
                    coordinateSpace: Self.space, onOpenInWindow: onOpenInWindow
                )
            }
            addColumnButton
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The headers run across the top once, and each lane draws the same
    /// columns beneath them — so the columns still line up, which is the whole
    /// reason to read a board in lanes rather than as separate boards.
    private var lanedBoard: some View {
        VStack(alignment: .leading, spacing: 0) {
            laneHeaderRow

            ForEach(model.lanes) { lane in
                LaneRow(
                    lane: lane, model: model,
                    coordinateSpace: Self.space, onOpenInWindow: onOpenInWindow
                )
            }

            if model.lanes.isEmpty {
                Text("Nothing matches the filters on this board.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(24)
            }
        }
        .padding(16)
    }

    private var laneHeaderRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(model.visibleColumns) { column in
                LaneColumnHeader(column: column, model: model)
            }
            addColumnButton
        }
        .padding(.bottom, 8)
    }

    /// Sits where the next column would be, which is where someone looks for
    /// it — rather than in a menu they would have to go hunting through.
    private var addColumnButton: some View {
        Button(action: onAddColumn) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.title3)
                Text("Add Column")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(width: 160)
            .frame(minHeight: 80)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One lane: a collapsible heading, then the columns filtered to its cards.
private struct LaneRow: View {
    let lane: BoardLane
    let model: BoardViewModel
    let coordinateSpace: String
    var onOpenInWindow: ((String) -> Void)?

    @State private var isCollapsed = false

    private var columns: [LoadedColumn] { model.columns(in: lane) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading

            if !isCollapsed {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns) { column in
                        BoardColumnView(
                            column: column,
                            model: model,
                            laneID: lane.id,
                            isLane: true,
                            coordinateSpace: coordinateSpace,
                            onOpenInWindow: onOpenInWindow
                        )
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .background(
            lane.isPinned
                ? Color.orange.opacity(0.06)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private var heading: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isCollapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let symbol = lane.symbol {
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(lane.isPinned ? .orange : .secondary)
                }

                Text(lane.name.isEmpty ? "All Cards" : lane.name)
                    .font(.subheadline.weight(.semibold))

                Text("\(lane.taskIDs.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())

                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(lane.name), \(lane.taskIDs.count) cards")
        .accessibilityHint(isCollapsed ? "Expands the lane" : "Collapses the lane")
    }
}

/// A column heading on a laned board, where the cards live in the rows below.
private struct LaneColumnHeader: View {
    let column: LoadedColumn
    let model: BoardViewModel

    var body: some View {
        HStack(spacing: 6) {
            Text(column.name)
                .font(.subheadline.weight(.semibold))

            Text("\(column.tasks.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())

            Spacer(minLength: 0)

            if column.wipState != .fine {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(column.wipState == .breached ? .red : .orange)
                    .help(column.wipState == .breached ? "Over its limit" : "At its limit")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 300)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
