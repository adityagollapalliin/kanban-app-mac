import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The same cards against a month.
///
/// A calendar answers the question a board cannot: not "what is in flight" but
/// "what lands on the 14th, and is that too much". So the month is the unit,
/// dates can be changed by dragging, and the cards that have no date at all
/// sit in a strip at the bottom where they can be dragged onto one — because a
/// calendar that silently omitted them would answer the question wrongly.
struct CalendarView: View {

    let model: BoardViewModel
    var onOpenInWindow: ((String) -> Void)?

    @State private var anchor = Date.now
    @State private var field: DateField = .due
    @State private var dropTarget: Date?

    private let calendar = Calendar.current

    /// Which date the month is drawn against. Both are real questions —
    /// "what is due" and "what starts" — and a calendar that could only answer
    /// one of them would be half a view.
    enum DateField: String, CaseIterable, Identifiable {
        case due, start
        var id: String { rawValue }

        var label: String { self == .due ? "Due Dates" : "Start Dates" }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            weekdayHeader
            monthGrid
            if !undated.isEmpty { undatedStrip }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                step(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .accessibilityLabel("Previous month")

            Text(monthTitle)
                .font(.headline)
                .frame(minWidth: 160)
                .accessibilityLabel(monthTitle)

            Button {
                step(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .accessibilityLabel("Next month")

            Button("Today") { anchor = .now }
                .buttonStyle(.borderless)
                .disabled(calendar.isDate(anchor, equalTo: .now, toGranularity: .month))

            Spacer(minLength: 0)

            Picker("Dates", selection: $field) {
                ForEach(DateField.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel("Which date to show cards on")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var monthTitle: String {
        anchor.formatted(.dateTime.month(.wide).year())
    }

    private func step(by months: Int) {
        guard let moved = calendar.date(byAdding: .month, value: months, to: anchor) else { return }
        anchor = moved
    }

    // MARK: - The grid

    private var weekdayHeader: some View {
        HStack(spacing: 1) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }

    /// Rotated to the user's first day of the week, which is not Sunday
    /// everywhere and is not the app's business to decide.
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var monthGrid: some View {
        GeometryReader { proxy in
            let rows = weeks.count
            let height = max(72, (proxy.size.height - CGFloat(rows - 1)) / CGFloat(max(rows, 1)))
            let buckets = byDay

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                    ForEach(days, id: \.self) { day in
                        dayCell(day, height: height, cards: buckets[calendar.startOfDay(for: day)] ?? [])
                    }
                }
                .padding(12)
            }
        }
    }

    private func dayCell(_ day: Date, height: CGFloat, cards: [BoardTask]) -> some View {
        let isToday = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: anchor, toGranularity: .month)

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption.monospacedDigit().weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.accentColor : (inMonth ? Color.primary : Color.secondary.opacity(0.6)))

                Spacer(minLength: 0)

                if cards.count > 3 {
                    Text("\(cards.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(cards.prefix(3)) { task in
                chip(task)
            }

            if cards.count > 3 {
                Text("+\(cards.count - 3) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        .background(cellBackground(inMonth: inMonth, isTargeted: dropTarget == day))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(dropTarget == day ? Color.accentColor : .clear, lineWidth: 2)
        }
        .dropDestination(for: String.self) { ids, _ in
            dropTarget = nil
            guard let id = ids.first else { return false }
            setDate(day, on: id)
            return true
        } isTargeted: { targeted in
            dropTarget = targeted ? day : (dropTarget == day ? nil : dropTarget)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(dayLabel(day, cards: cards))
    }

    private func cellBackground(inMonth: Bool, isTargeted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(inMonth ? AnyShapeStyle(.quaternary.opacity(0.25)) : AnyShapeStyle(.clear))
    }

    private func dayLabel(_ day: Date, cards: [BoardTask]) -> String {
        let date = day.formatted(date: .complete, time: .omitted)
        guard !cards.isEmpty else { return "\(date), nothing \(field == .due ? "due" : "starting")" }
        return "\(date), \(cards.count) card\(cards.count == 1 ? "" : "s"): "
            + cards.map(\.title).joined(separator: ", ")
    }

    private func chip(_ task: BoardTask) -> some View {
        HStack(spacing: 3) {
            Image(systemName: CardAppearance.symbol(forType: task.type))
                .font(.system(size: 8))
                .foregroundStyle(CardAppearance.color(forType: task.type))

            Text(task.title)
                .font(.caption2)
                .lineLimit(1)

            if task.flagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(chipColor(task), in: RoundedRectangle(cornerRadius: 4))
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .draggable(task.id) {
            Text(task.title)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .onTapGesture { model.toggleSelection(of: task.id) }
        .contextMenu {
            Button("Open in a Window", systemImage: "macwindow") { onOpenInWindow?(task.id) }
            Button("Clear the Date", systemImage: "calendar.badge.minus") { setDate(nil, on: task.id) }
        }
        .help(model.tag(for: task) + "  " + task.title)
        .accessibilityLabel("\(model.tag(for: task)), \(task.title)")
    }

    private func chipColor(_ task: BoardTask) -> Color {
        if let stripe = CardAppearance.stripe(for: task, model: model) {
            return stripe.opacity(0.22)
        }
        return Color.secondary.opacity(0.16)
    }

    // MARK: - Cards without a date

    /// A strip rather than a hidden list. These are exactly the cards a
    /// calendar is being consulted about — the ones nobody has committed to a
    /// day — so they are on screen, and draggable onto one.
    private var undatedStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No \(field == .due ? "due" : "start") date  (\(undated.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Lazy, and it has to be: a project where nobody has set a date
            // has every card in this strip, and building a thousand chips for
            // a row four of them wide costs more than the whole rest of the
            // app. The strip scrolls on its own, so its width is bounded and
            // the laziness is real.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(undated) { task in
                        chip(task)
                            .frame(width: 170)
                    }
                }
                .padding(.bottom, 2)
                .frame(height: 26)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(undated.count) cards with no date. Drag one onto a day to give it one.")
    }

    // MARK: - Dates

    private func date(of task: BoardTask) -> Date? {
        field == .due ? task.dueDate : task.startDate
    }

    private func setDate(_ day: Date?, on taskID: String) {
        // Keeping the time of day would put a card on a day at 03:41 for no
        // reason anyone chose; a date dropped on a calendar means the day.
        let value = day.map { calendar.startOfDay(for: $0) }
        if field == .due {
            model.setDueDate(value, for: taskID)
        } else {
            model.setStartDate(value, for: taskID)
        }
    }

    /// Cards bucketed by the day they land on, worked out once per redraw
    /// rather than once per cell: forty-two cells each filtering a thousand
    /// cards is forty thousand comparisons to draw one month.
    private var byDay: [Date: [BoardTask]] {
        var buckets: [Date: [BoardTask]] = [:]
        for task in model.visibleTasks {
            guard let date = date(of: task) else { continue }
            buckets[calendar.startOfDay(for: date), default: []].append(task)
        }
        return buckets
    }

    private var undated: [BoardTask] {
        model.visibleTasks.filter { date(of: $0) == nil }
    }

    /// Whole weeks, so the grid is rectangular and the days either side of the
    /// month are visible rather than blank — work does not stop on the 1st.
    private var days: [Date] {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: anchor)),
              let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }

        let leading = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        let total = leading + range.count
        let trailing = (7 - total % 7) % 7

        return (0..<(total + trailing)).compactMap {
            calendar.date(byAdding: .day, value: $0 - leading, to: monthStart)
        }
    }

    private var weeks: [[Date]] {
        stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }
}
