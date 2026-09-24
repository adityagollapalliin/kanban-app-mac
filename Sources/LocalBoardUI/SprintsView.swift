import Charts
import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// Sprints: what is running, what is planned, and how it has been going.
///
/// The running sprint is at the top with its burndown, because that is the
/// question someone opens this screen to ask. Velocity is underneath, because
/// it is the question they ask next.
struct SprintsView: View {

    let model: BoardViewModel

    @State private var editing: Sprint?
    @State private var isCreating = false
    @State private var completing: Sprint?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let active = model.activeSprint {
                    activeSection(active)
                }

                plannedSection
                velocitySection
                finishedSection
            }
            .padding(24)
        }
        .navigationTitle("Sprints")
        .safeAreaInset(edge: .top) { header }
        .sheet(isPresented: $isCreating) { SprintSheet(model: model, existing: nil) }
        .sheet(item: $editing) { sprint in SprintSheet(model: model, existing: sprint) }
        .sheet(item: $completing) { sprint in CompleteSprintSheet(model: model, sprint: sprint) }
    }

    private var header: some View {
        HStack {
            Text("Sprints").font(.headline)
            Spacer()
            Button("New Sprint…", systemImage: "plus") { isCreating = true }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Running

    private func activeSection(_ sprint: Sprint) -> some View {
        let tasks = model.tasks(inSprint: sprint.id)
        let done = tasks.count { $0.completedAt != nil }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(sprint.name, systemImage: "figure.run")
                    .font(.title3.weight(.semibold))

                Text("Active")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.green.opacity(0.18), in: Capsule())

                if sprint.isOverrunning(now: .now) {
                    Label("Past its end date", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()

                Button("Complete…") { completing = sprint }
                Button("Edit…") { editing = sprint }
                    .buttonStyle(.link)
            }

            if !sprint.goal.isEmpty {
                Text(sprint.goal)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                statistic("Cards", "\(done)/\(tasks.count)")
                statistic("Points", pointsSummary(tasks))
                if let ends = sprint.endsAt {
                    statistic("Ends", ends.formatted(date: .abbreviated, time: .omitted))
                }
            }

            burndown(sprint)
        }
    }

    private func burndown(_ sprint: Sprint) -> some View {
        let points = model.burndown(for: sprint)

        return Group {
            if points.isEmpty {
                empty("The burndown appears once the sprint has dates.")
            } else {
                Chart {
                    ForEach(points) { point in
                        // The straight line the sprint would follow if work
                        // went evenly. It is a reference, not a prediction,
                        // which is why it is dashed and grey.
                        LineMark(
                            x: .value("Day", point.day),
                            y: .value("Ideal", point.ideal),
                            series: .value("Series", "Ideal")
                        )
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                        if !point.isProjected {
                            LineMark(
                                x: .value("Day", point.day),
                                y: .value("Remaining", point.remaining),
                                series: .value("Series", "Remaining")
                            )
                            .foregroundStyle(.blue)
                            .interpolationMethod(.monotone)
                        }
                    }
                }
                .chartYAxisLabel("Points left")
                .frame(height: 200)

                Text("Measured against what the sprint committed to on its first day. Work added later shows as a line that does not reach zero, which is the point.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Planned and finished

    private var plannedSection: some View {
        let planned = model.sprints.filter { $0.state == .planned }

        return Group {
            if !planned.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Planned").font(.headline)

                    ForEach(planned) { sprint in
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sprint.name)
                                Text("\(model.tasks(inSprint: sprint.id).count) cards")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Start") { model.startSprint(sprint.id) }
                                .disabled(model.activeSprint != nil)
                                .help(model.activeSprint == nil
                                      ? "Starts the sprint and records what it committed to"
                                      : "Complete the running sprint first")
                            Button("Edit…") { editing = sprint }
                                .buttonStyle(.link)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.deleteSprint(sprint.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var finishedSection: some View {
        let finished = model.sprints.filter { $0.state == .complete }

        return Group {
            if !finished.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Finished").font(.headline)
                    ForEach(finished) { sprint in
                        HStack {
                            Text(sprint.name)
                            Spacer()
                            if let at = sprint.completedAt {
                                Text(at.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Velocity

    private var velocitySection: some View {
        let velocity = model.velocity()

        return VStack(alignment: .leading, spacing: 8) {
            Text("Velocity").font(.headline)
            Text("Committed against delivered, over finished sprints. A sprint still running has not achieved a velocity yet, so it is not here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if velocity.isEmpty {
                empty("No sprint has been completed yet.")
            } else {
                Chart {
                    ForEach(velocity) { entry in
                        BarMark(
                            x: .value("Sprint", entry.sprint.name),
                            y: .value("Points", entry.committedPoints)
                        )
                        .foregroundStyle(.secondary.opacity(0.35))
                        .position(by: .value("Kind", "Committed"))

                        BarMark(
                            x: .value("Sprint", entry.sprint.name),
                            y: .value("Points", entry.completedPoints)
                        )
                        .foregroundStyle(.green)
                        .position(by: .value("Kind", "Delivered"))
                    }
                }
                .frame(height: 180)

                if let average = averageVelocity(velocity) {
                    Text("Averaging \(average) points a sprint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func averageVelocity(_ entries: [SprintVelocity]) -> String? {
        guard !entries.isEmpty else { return nil }
        let total = entries.reduce(0.0) { $0 + $1.completedPoints }
        guard total > 0 else { return nil }
        return (total / Double(entries.count))
            .formatted(FloatingPointFormatStyle<Double>().precision(.fractionLength(0...1)))
    }

    // MARK: - Furniture

    private func statistic(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private func pointsSummary(_ tasks: [BoardTask]) -> String {
        let total = tasks.reduce(0.0) { $0 + ($1.estimate ?? 0) }
        let done = tasks.filter { $0.completedAt != nil }.reduce(0.0) { $0 + ($1.estimate ?? 0) }
        let format = FloatingPointFormatStyle<Double>().precision(.fractionLength(0...1))
        return total == 0 ? "—" : "\(done.formatted(format))/\(total.formatted(format))"
    }

    private func empty(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Writing or editing one sprint.
struct SprintSheet: View {
    let model: BoardViewModel
    let existing: Sprint?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var goal = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(14 * 86_400)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "New sprint" : "Edit sprint").font(.headline)

            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Goal (optional)", text: $goal, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

            DatePicker("Starts", selection: $start, displayedComponents: .date)
            DatePicker("Ends", selection: $end, in: start..., displayedComponents: .date)

            Text("Starting the sprint records what it contains, so the burndown has a fixed line to measure against.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = existing?.name ?? ""
            goal = existing?.goal ?? ""
            start = existing?.startsAt ?? Date()
            end = existing?.endsAt ?? Date().addingTimeInterval(14 * 86_400)
        }
    }

    private func save() {
        if let existing {
            model.updateSprint(existing.id, name: name, goal: goal, from: start, to: end)
        } else {
            model.createSprint(named: name, goal: goal, from: start, to: end)
        }
        dismiss()
    }
}

/// Closing a sprint, and deciding where the unfinished work goes.
struct CompleteSprintSheet: View {
    let model: BoardViewModel
    let sprint: Sprint

    @Environment(\.dismiss) private var dismiss
    @State private var destination: String?

    private var unfinished: [BoardTask] {
        model.tasks(inSprint: sprint.id).filter { $0.completedAt == nil }
    }

    private var candidates: [Sprint] {
        model.sprints.filter { $0.state == .planned && $0.id != sprint.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Complete \(sprint.name)").font(.headline)

            if unfinished.isEmpty {
                Label("Everything in this sprint is finished.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Text("\(unfinished.count) card\(unfinished.count == 1 ? " is" : "s are") unfinished. Unfinished work is never quietly marked done — say where it should go.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Carry over to", selection: $destination) {
                    Text("No sprint — back to the backlog").tag(String?.none)
                    ForEach(candidates) { sprint in
                        Text(sprint.name).tag(String?.some(sprint.id))
                    }
                }
                .pickerStyle(.radioGroup)

                ForEach(unfinished.prefix(5)) { task in
                    Text("\(model.tag(for: task))  \(task.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if unfinished.count > 5 {
                    Text("and \(unfinished.count - 5) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Complete Sprint") {
                    model.completeSprint(sprint.id, carryingOverTo: destination)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
