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

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if model.isLaned {
                lanedBoard
            } else {
                plainBoard
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var plainBoard: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(model.visibleColumns) { column in
                BoardColumnView(column: column, model: model, onOpenInWindow: onOpenInWindow)
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
                LaneRow(lane: lane, model: model, onOpenInWindow: onOpenInWindow)
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
