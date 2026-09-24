import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The work laid out against dates, with the dependencies drawn between.
///
/// A Gantt chart is a chart of *scheduled* work, so a card with neither a
/// start nor a due date has no place on one. Rather than inventing dates for
/// those cards — which would draw a confident picture out of nothing — they
/// are listed underneath as work that is not scheduled yet, which is a fact
/// worth seeing on its own.
struct TimelineView: View {

    let model: BoardViewModel
    var onOpenInWindow: ((String) -> Void)?

    /// How wide one day is. Wide enough to land on with a mouse, narrow enough
    /// that a quarter fits across a window.
    private static let dayWidth: CGFloat = 26
    private static let rowHeight: CGFloat = 30
    private static let labelWidth: CGFloat = 220

    private let calendar = Calendar.current

    var body: some View {
        if scheduled.isEmpty && unscheduled.isEmpty {
            ContentUnavailableView(
                "Nothing to lay out",
                systemImage: "chart.bar.xaxis",
                description: Text("Give a card a start or a due date and it appears here.")
            )
        } else {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    if !scheduled.isEmpty { chart }
                    if !unscheduled.isEmpty { unscheduledList }
                }
                .padding(16)
            }
        }
    }

    // MARK: - The chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 0) {
            dayHeader

            ZStack(alignment: .topLeading) {
                // The bars first, then the arrows on top, so a dependency line
                // is never hidden behind the work it points at.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(scheduled.enumerated()), id: \.element.id) { index, task in
                        row(task, index: index)
                    }
                }

                dependencyArrows
                    .allowsHitTesting(false)
            }
        }
    }

    private var dayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.labelWidth)

            ForEach(0..<dayCount, id: \.self) { offset in
                let day = date(atOffset: offset)
                VStack(spacing: 1) {
                    // Only the first of a month is named, so the strip reads
                    // as a calendar rather than as a wall of numbers.
                    Text(calendar.component(.day, from: day) == 1
                         ? day.formatted(.dateTime.month(.abbreviated))
                         : "")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(isToday(day) ? Color.accentColor : .secondary)
                }
                .frame(width: Self.dayWidth)
                .background(isWeekend(day) ? Color.secondary.opacity(0.06) : .clear)
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(_ task: BoardTask, index: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if task.flagged {
                    Image(systemName: "flag.fill").font(.caption2).foregroundStyle(.red)
                }
                Text(model.tag(for: task))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(task.title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            .padding(.trailing, 8)

            ZStack(alignment: .leading) {
                weekendStripes

                bar(task)
                    .offset(x: CGFloat(startOffset(of: task)) * Self.dayWidth)
            }
            .frame(width: CGFloat(dayCount) * Self.dayWidth, alignment: .leading)
        }
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleSelection(of: task.id) }
        .contextMenu {
            Button("Get Info", systemImage: "info.circle") { model.selectedTaskID = task.id }
            if let onOpenInWindow {
                Button("Open in New Window", systemImage: "macwindow.on.rectangle") {
                    onOpenInWindow(task.id)
                }
            }
        }
    }

    private func bar(_ task: BoardTask) -> some View {
        let days = max(1, length(of: task))
        let blocked = isBlocked(task)

        return RoundedRectangle(cornerRadius: 5)
            .fill(barColor(task).opacity(task.completedAt == nil ? 0.85 : 0.4))
            .overlay(alignment: .leading) {
                if blocked {
                    // A blocked bar is hatched rather than merely tinted: the
                    // timeline is read at a glance and colour alone is the
                    // thing that disappears at that size.
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(.leading, 4)
                }
            }
            .frame(width: CGFloat(days) * Self.dayWidth - 4, height: Self.rowHeight - 10)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(model.isPicked(task.id) || model.selectedTaskID == task.id
                                  ? Color.accentColor : .clear, lineWidth: 2)
            )
            .help(barHelp(task))
    }

    private var weekendStripes: some View {
        HStack(spacing: 0) {
            ForEach(0..<dayCount, id: \.self) { offset in
                let day = date(atOffset: offset)
                Rectangle()
                    .fill(isToday(day)
                          ? Color.accentColor.opacity(0.10)
                          : (isWeekend(day) ? Color.secondary.opacity(0.06) : .clear))
                    .frame(width: Self.dayWidth)
            }
        }
        .accessibilityHidden(true)
    }

    /// The arrows between a card and whatever it is waiting on.
    ///
    /// Drawn from the blocker's right edge to the blocked card's left, which
    /// is the direction the work flows and the direction the eye reads.
    private var dependencyArrows: some View {
        Canvas { context, _ in
            for edge in edges {
                guard let fromRow = scheduled.firstIndex(where: { $0.id == edge.from }),
                      let toRow = scheduled.firstIndex(where: { $0.id == edge.to })
                else { continue }

                let fromTask = scheduled[fromRow]
                let toTask = scheduled[toRow]

                let startX = Self.labelWidth
                    + CGFloat(startOffset(of: fromTask) + max(1, length(of: fromTask))) * Self.dayWidth - 4
                let startY = CGFloat(fromRow) * Self.rowHeight + Self.rowHeight / 2
                let endX = Self.labelWidth + CGFloat(startOffset(of: toTask)) * Self.dayWidth
                let endY = CGFloat(toRow) * Self.rowHeight + Self.rowHeight / 2

                var path = Path()
                path.move(to: CGPoint(x: startX, y: startY))
                let midX = max(startX + 8, endX - 8)
                path.addLine(to: CGPoint(x: midX, y: startY))
                path.addLine(to: CGPoint(x: midX, y: endY))
                path.addLine(to: CGPoint(x: endX, y: endY))

                context.stroke(
                    path,
                    with: .color(.orange.opacity(0.7)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )

                var head = Path()
                head.move(to: CGPoint(x: endX, y: endY))
                head.addLine(to: CGPoint(x: endX - 5, y: endY - 3))
                head.addLine(to: CGPoint(x: endX - 5, y: endY + 3))
                head.closeSubpath()
                context.fill(head, with: .color(.orange.opacity(0.7)))
            }
        }
        .frame(
            width: Self.labelWidth + CGFloat(dayCount) * Self.dayWidth,
            height: CGFloat(scheduled.count) * Self.rowHeight
        )
    }

    private var unscheduledList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 12)

            Text("Not scheduled")
                .font(.headline)
            Text("These have no start or due date, so there is nothing to draw. Giving one a date puts it on the chart.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(unscheduled.prefix(30)) { task in
                HStack(spacing: 6) {
                    Text(model.tag(for: task))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text(task.title).font(.caption).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.toggleSelection(of: task.id) }
            }

            if unscheduled.count > 30 {
                Text("and \(unscheduled.count - 30) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Working it out

    private var allTasks: [BoardTask] { model.visibleColumns.flatMap(\.tasks) }

    /// Anything with at least one date, earliest first.
    private var scheduled: [BoardTask] {
        allTasks
            .filter { $0.startDate != nil || $0.dueDate != nil }
            .sorted { start(of: $0) < start(of: $1) }
    }

    private var unscheduled: [BoardTask] {
        allTasks.filter { $0.startDate == nil && $0.dueDate == nil }
    }

    /// Blocking relationships between cards that are both on the chart.
    ///
    /// Read from the links on each card rather than from a second source, so
    /// the arrows and the inspector can never disagree.
    private var edges: [(from: String, to: String)] {
        var found: [(String, String)] = []
        var seen: Set<String> = []

        for task in scheduled {
            for entry in model.links(forTask: task.id) where entry.kind == .blockedBy {
                let key = "\(entry.otherID)->\(task.id)"
                if seen.insert(key).inserted { found.append((entry.otherID, task.id)) }
            }
        }
        return found
    }

    private func isBlocked(_ task: BoardTask) -> Bool {
        model.links(forTask: task.id).contains { $0.kind == .blockedBy }
    }

    /// A card with only a due date is a milestone: one day, on that day.
    private func start(of task: BoardTask) -> Date {
        calendar.startOfDay(for: task.startDate ?? task.dueDate ?? Date())
    }

    private func end(of task: BoardTask) -> Date {
        calendar.startOfDay(for: task.dueDate ?? task.startDate ?? Date())
    }

    private var range: (first: Date, last: Date) {
        let today = calendar.startOfDay(for: Date())
        guard !scheduled.isEmpty else { return (today, today) }

        let first = scheduled.map(start(of:)).min() ?? today
        let last = scheduled.map(end(of:)).max() ?? today
        // A few days of margin either side, so a bar never sits flush against
        // the edge with nothing to read it against.
        return (
            calendar.date(byAdding: .day, value: -2, to: min(first, today)) ?? first,
            calendar.date(byAdding: .day, value: 3, to: max(last, today)) ?? last
        )
    }

    private var dayCount: Int {
        let bounds = range
        return max(1, (calendar.dateComponents([.day], from: bounds.first, to: bounds.last).day ?? 1) + 1)
    }

    private func date(atOffset offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: range.first) ?? range.first
    }

    private func startOffset(of task: BoardTask) -> Int {
        max(0, calendar.dateComponents([.day], from: range.first, to: start(of: task)).day ?? 0)
    }

    private func length(of task: BoardTask) -> Int {
        (calendar.dateComponents([.day], from: start(of: task), to: end(of: task)).day ?? 0) + 1
    }

    private func isToday(_ day: Date) -> Bool { calendar.isDateInToday(day) }

    private func isWeekend(_ day: Date) -> Bool { calendar.isDateInWeekend(day) }

    private func barColor(_ task: BoardTask) -> Color {
        if task.flagged { return .red }
        if let stripe = CardAppearance.stripe(for: task, model: model) { return stripe }
        return .accentColor
    }

    private func barHelp(_ task: BoardTask) -> String {
        var parts = ["\(model.tag(for: task)) \(task.title)"]
        if let start = task.startDate {
            parts.append("From \(start.formatted(date: .abbreviated, time: .omitted))")
        }
        if let due = task.dueDate {
            parts.append("Due \(due.formatted(date: .abbreviated, time: .omitted))")
        }
        if isBlocked(task) { parts.append("Blocked by something else on this chart") }
        return parts.joined(separator: " · ")
    }
}
