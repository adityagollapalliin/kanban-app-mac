import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// Who is carrying how much, against what they said they can carry.
///
/// The bar goes red only when there is a capacity to be over. Somebody who has
/// never set one is drawn without a ceiling rather than as permanently
/// overloaded — a view that shouts at everybody is a view nobody reads.
struct WorkloadView: View {

    let model: BoardViewModel

    @State private var anchor = Date.now
    @State private var days = 7
    @State private var dropTarget: String?
    @State private var editingCapacity: Person?

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            if loads.isEmpty {
                ContentUnavailableView(
                    "Nobody to show",
                    systemImage: "person.2",
                    description: Text("Add people in Settings, then put them on some cards.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(loads) { load in
                            personRow(load)
                        }
                        unassignedRow
                    }
                    .padding(14)
                }
            }
        }
        .sheet(item: $editingCapacity) { person in
            CapacitySheet(person: person, model: model)
        }
    }

    private var loads: [WorkloadRepository.Load] {
        model.workload(from: calendar.startOfDay(for: anchor), days: days)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                shift(by: -days)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Earlier")

            Text(windowLabel)
                .font(.headline)
                .frame(minWidth: 220)

            Button {
                shift(by: days)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Later")

            Button("This Week") { anchor = .now }
                .buttonStyle(.borderless)

            Spacer(minLength: 0)

            Picker("Window", selection: $days) {
                Text("Week").tag(7)
                Text("Fortnight").tag(14)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func shift(by amount: Int) {
        guard let moved = calendar.date(byAdding: .day, value: amount, to: anchor) else { return }
        anchor = moved
    }

    private var windowLabel: String {
        let start = calendar.startOfDay(for: anchor)
        guard let end = calendar.date(byAdding: .day, value: days - 1, to: start) else { return "" }
        return "\(start.formatted(date: .abbreviated, time: .omitted)) – "
            + end.formatted(date: .abbreviated, time: .omitted)
    }

    private var windowDays: [Date] {
        let start = calendar.startOfDay(for: anchor)
        return (0..<days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    // MARK: - One person

    private func personRow(_ load: WorkloadRepository.Load) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(PaletteColor.named(load.person.color).color)
                    .frame(width: 9, height: 9)

                Text(load.person.name)
                    .font(.subheadline.weight(.semibold))

                Text(amount(load.total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(load.isOver(days: days) ? .red : .secondary)

                if load.person.hasCapacity {
                    Text("of \(amount(load.capacity(days: days)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Button("Set capacity") { editingCapacity = load.person }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }

                if load.unestimatedCount > 0 {
                    // A week of unestimated work is not an empty week, and the
                    // bar cannot show what nobody has sized.
                    Label("\(load.unestimatedCount) unestimated", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 0)

                if load.person.hasCapacity {
                    Button("Capacity…") { editingCapacity = load.person }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            capacityBar(load)
            dayStrip(load)
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility(load))
    }

    private func capacityBar(_ load: WorkloadRepository.Load) -> some View {
        GeometryReader { proxy in
            let fraction = load.person.hasCapacity ? min(1.4, load.fraction(days: days)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(load.isOver(days: days) ? Color.red : Color.accentColor)
                    .frame(width: max(0, min(proxy.size.width, proxy.size.width * fraction)))
            }
        }
        .frame(height: 6)
        .opacity(load.person.hasCapacity ? 1 : 0.25)
    }

    /// A card lands on the day it is due. Spreading it over the days between
    /// start and due would be a guess about pacing, and a wrong guess moves
    /// the red day to the wrong day.
    private func dayStrip(_ load: WorkloadRepository.Load) -> some View {
        HStack(spacing: 4) {
            ForEach(windowDays, id: \.self) { day in
                let amount = load.byDay[calendar.startOfDay(for: day)] ?? 0
                VStack(spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(dayColor(amount, load: load))
                        .frame(height: 20)
                        .overlay {
                            if amount > 0 {
                                Text(self.amount(amount))
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .frame(maxWidth: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(dropTarget == key(load.person, day) ? Color.accentColor : .clear, lineWidth: 2)
                }
                .dropDestination(for: String.self) { ids, _ in
                    dropTarget = nil
                    guard let id = ids.first else { return false }
                    model.reassign(id, to: load.person.id, on: day)
                    return true
                } isTargeted: { targeted in
                    dropTarget = targeted ? key(load.person, day) : nil
                }
            }
        }
    }

    private func key(_ person: Person, _ day: Date) -> String {
        "\(person.id)-\(calendar.startOfDay(for: day).timeIntervalSince1970)"
    }

    private func dayColor(_ amount: Double, load: WorkloadRepository.Load) -> Color {
        guard amount > 0 else { return Color.secondary.opacity(0.12) }
        guard load.person.hasCapacity else { return .accentColor.opacity(0.6) }

        let perDay = load.person.weeklyCapacity / 5
        return amount > perDay ? .red.opacity(0.85) : .accentColor.opacity(0.75)
    }

    /// The cards nobody is on. Draggable onto a person, which is the whole
    /// point of showing them here rather than leaving them out.
    private var unassignedRow: some View {
        let cards = model.visibleTasks.filter {
            model.assignees(of: $0).isEmpty && $0.completedAt == nil
        }

        return Group {
            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nobody yet  (\(cards.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 6) {
                            ForEach(cards) { task in
                                Text(task.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.quaternary, in: Capsule())
                                    .draggable(task.id) { Text(task.title).padding(6) }
                                    .frame(maxWidth: 200)
                            }
                        }
                        .frame(height: 24)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .padding(10)
                .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func amount(_ value: Double) -> String {
        let unit = loads.first?.person.capacityUnit ?? .hours
        let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return "\(text)\(unit.short)"
    }

    private func accessibility(_ load: WorkloadRepository.Load) -> String {
        guard load.person.hasCapacity else {
            return "\(load.person.name), carrying \(amount(load.total)), no capacity set"
        }
        let state = load.isOver(days: days) ? "over capacity" : "within capacity"
        return "\(load.person.name), \(amount(load.total)) of \(amount(load.capacity(days: days))), \(state)"
    }
}

/// What a person can take on, and over what.
private struct CapacitySheet: View {
    let person: Person
    let model: BoardViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var unit = CapacityUnit.hours
    @State private var period = CapacityPeriod.week

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(person.name)'s capacity")
                .font(.headline)

            HStack {
                TextField("Amount", text: $amount)
                    .frame(width: 80)

                Picker("", selection: $unit) {
                    ForEach(CapacityUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()

                Picker("", selection: $period) {
                    ForEach(CapacityPeriod.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            Text("""
                A daily figure is counted as five days to the week, not seven: \
                capacity is working days. Leave it at zero and the bar is drawn \
                without a ceiling rather than as somebody who can do nothing.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setCapacity(Double(amount) ?? 0, unit: unit, period: period, for: person.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            amount = person.capacityAmount > 0 ? String(Int(person.capacityAmount)) : ""
            unit = person.capacityUnit
            period = person.capacityPeriod
        }
    }
}
