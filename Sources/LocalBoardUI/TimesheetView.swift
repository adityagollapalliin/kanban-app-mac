import SwiftUI
import Charts
import LocalBoardCore
import LocalBoardStore

/// A week of hours, one line per card.
///
/// Editable in place, because the reason anybody opens a timesheet is that
/// something in it is wrong — and a grid you can only read is a grid you have
/// to go and correct somewhere else.
struct TimesheetView: View {

    let model: BoardViewModel

    @State private var week = TimesheetWeek(containing: Date())
    @State private var personID: String?
    @State private var editing: String?
    @State private var typed = ""

    private var sheet: Timesheet {
        _ = model.timeRevision
        return model.timesheet(for: week, personID: personID)
    }

    var body: some View {
        let sheet = sheet

        VStack(spacing: 0) {
            header

            if sheet.rows.isEmpty {
                ContentUnavailableView(
                    "Nothing logged this week",
                    systemImage: "clock",
                    description: Text("Start a timer on a card, or type into a cell once something is here.")
                )
            } else {
                ScrollView {
                    // A LazyVStack of rows rather than a `Grid`: a Grid builds
                    // every row the moment it is asked to, and a week in which
                    // a team logged against three hundred cards would build
                    // three hundred rows of editable cells before drawing one.
                    // The columns line up because each is a fixed width, which
                    // is what a timesheet's columns are anyway.
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(sheet.rows) { row in
                                line(row)
                            }
                            Divider().padding(.vertical, 2)
                            totals(sheet)
                        } header: {
                            headings
                        }
                    }
                    .padding()
                    // Pinned left rather than centred: a scroll view hands its
                    // content only the width it asked for, which leaves a
                    // timesheet floating in the middle of the window.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("Timesheet")
    }

    private var header: some View {
        HStack {
            Button("Previous week", systemImage: "chevron.left") { week = week.shifted(by: -1) }
                .labelStyle(.iconOnly)
            Text(week.title)
                .font(.headline)
                .frame(minWidth: 160)
            Button("Next week", systemImage: "chevron.right") { week = week.shifted(by: 1) }
                .labelStyle(.iconOnly)
            Button("This week") { week = TimesheetWeek(containing: Date()) }
                .buttonStyle(.borderless)

            Spacer()

            Picker("Person", selection: $personID) {
                Text("Everyone").tag(String?.none)
                ForEach(model.people) { person in
                    Text(person.name).tag(String?.some(person.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Fixed, not a minimum: a column that grows to fit the longest title in
    /// its own row puts every row's days in a different place.
    private static let cardColumn: CGFloat = 260

    private var headings: some View {
        HStack(spacing: 8) {
            Text("Card")
                .font(.caption.weight(.semibold))
                .frame(width: Self.cardColumn, alignment: .leading)
            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption.weight(.semibold))
                    .frame(width: 52)
            }
            Text("Total")
                .font(.caption.weight(.semibold))
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func line(_ row: TimesheetRow) -> some View {
        HStack(spacing: 8) {
            cardLabel(row)
            ForEach(0..<7, id: \.self) { day in
                cell(row, day)
            }
            Text(DurationFormat.clock(row.total))
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(width: 60, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func totals(_ sheet: Timesheet) -> some View {
        HStack(spacing: 8) {
            Text("Total")
                .font(.callout.weight(.semibold))
                .frame(width: Self.cardColumn, alignment: .leading)
            ForEach(Array(sheet.dailyTotals.enumerated()), id: \.offset) { _, minutes in
                Text(minutes == 0 ? "—" : DurationFormat.clock(minutes))
                    .font(.callout.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
            Text(DurationFormat.clock(sheet.total))
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 60, alignment: .trailing)
        }

        if sheet.billableTotal > 0 {
            HStack(spacing: 8) {
                Text("Billable")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .frame(width: Self.cardColumn, alignment: .leading)
                ForEach(Array(sheet.dailyBillableTotals.enumerated()), id: \.offset) { _, minutes in
                    Text(minutes == 0 ? "" : DurationFormat.clock(minutes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.green)
                        .frame(width: 52, alignment: .trailing)
                }
                Text(DurationFormat.clock(sheet.billableTotal))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.green)
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }

    private func cardLabel(_ row: TimesheetRow) -> some View {
        Button {
            model.selectedTaskID = row.taskID
        } label: {
            HStack(spacing: 5) {
                if !row.cardKey.isEmpty {
                    Text(row.cardKey)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(row.title).font(.callout).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: Self.cardColumn, alignment: .leading)
    }

    @ViewBuilder
    private func cell(_ row: TimesheetRow, _ day: Int) -> some View {
        let key = "\(row.id)|\(day)"
        let minutes = row.minutes[day]

        if editing == key {
            TextField("", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .frame(width: 52)
                .onSubmit { commit(row, day) }
                .onExitCommand { editing = nil }
        } else {
            Button {
                typed = minutes == 0 ? "" : DurationFormat.clock(minutes)
                editing = key
            } label: {
                Text(minutes == 0 ? "—" : DurationFormat.clock(minutes))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(minutes == 0 ? .secondary : .primary)
                    .frame(width: 52, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(minutes == 0 ? "Click to log time" : "\(DurationFormat.short(minutes)) — click to change")
        }
    }

    private func commit(_ row: TimesheetRow, _ day: Int) {
        defer { editing = nil }
        let trimmed = typed.trimmingCharacters(in: .whitespaces)

        // Emptying a cell means nothing was worked that day. Rubbish typed in
        // leaves the figure alone rather than clearing somebody's hours.
        if trimmed.isEmpty {
            model.setTimesheetCell(0, task: row.taskID, day: week.days[day], personID: row.personID)
            return
        }
        guard let minutes = DurationFormat.minutes(from: trimmed) else { return }
        model.setTimesheetCell(minutes, task: row.taskID, day: week.days[day], personID: row.personID)
    }
}

/// How long work sits in each column.
///
/// Read from the status history rather than from anything anybody typed, so
/// it is a fact about what happened rather than an estimate.
struct TimeInStatusView: View {

    let model: BoardViewModel

    private var report: [TimeInStatusSummary] { model.timeInStatusReport() }

    var body: some View {
        let report = report

        Group {
            if report.isEmpty {
                ContentUnavailableView(
                    "Nothing has moved yet",
                    systemImage: "clock.arrow.2.circlepath",
                    description: Text("Once cards start crossing the board, this shows where the time goes.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Chart(report) { summary in
                            BarMark(
                                x: .value("Days", summary.averageSeconds / 86_400),
                                y: .value("Column", model.statusName(id: summary.statusID))
                            )
                        }
                        .chartXAxisLabel("Average days")
                        .frame(height: CGFloat(report.count) * 34 + 40)

                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow {
                                Text("Column").font(.caption.weight(.semibold))
                                Text("Average").font(.caption.weight(.semibold))
                                Text("Longest").font(.caption.weight(.semibold))
                                Text("Cards").font(.caption.weight(.semibold))
                                Text("Visits").font(.caption.weight(.semibold))
                            }
                            Divider().gridCellUnsizedAxes(.horizontal)

                            ForEach(report) { summary in
                                GridRow {
                                    Text(model.statusName(id: summary.statusID))
                                    Text(summary.averageDescription).monospacedDigit()
                                    Text(summary.longestDescription).monospacedDigit()
                                    Text("\(summary.taskCount)").monospacedDigit()
                                    Text("\(summary.visits)")
                                        .monospacedDigit()
                                        // More visits than cards means work is
                                        // coming back, which is the thing this
                                        // report is best at showing.
                                        .foregroundStyle(summary.visits > summary.taskCount ? .orange : .primary)
                                }
                                .font(.callout)
                            }
                        }

                        Text("Time in the column a card is in now is counted up to this moment, so these figures move as the day goes on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("Time in Status")
    }
}
