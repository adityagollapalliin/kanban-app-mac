import Charts
import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The three charts a Kanban board can honestly draw from its own history.
///
/// Every number here comes from `status_change`, which is recorded as work
/// moves rather than computed nightly — so these are not estimates, they are
/// what happened. Nothing is fetched and nothing is stored: each chart is a
/// question asked of the history when the screen opens.
struct AnalyticsView: View {

    let model: BoardViewModel

    @State private var window = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                windowPicker
                cumulativeFlow
                controlChart
                burnup
            }
            .padding(24)
        }
        .navigationTitle("Analytics")
    }

    private var windowPicker: some View {
        Picker("Period", selection: $window) {
            Text("2 weeks").tag(14)
            Text("30 days").tag(30)
            Text("90 days").tag(90)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
    }

    // MARK: - Cumulative flow

    private var cumulativeFlow: some View {
        let points = model.cumulativeFlow(days: window)

        return section(
            title: "Cumulative Flow",
            caption: "How much work stood in each stage at the end of each day. A band that widens over time is a stage that work is going into faster than it comes out."
        ) {
            if points.isEmpty {
                empty("No history yet. The diagram fills in as cards move.")
            } else {
                Chart {
                    ForEach(points) { point in
                        ForEach(StatusCategory.allCases, id: \.self) { category in
                            AreaMark(
                                x: .value("Day", point.day),
                                y: .value("Cards", point.count(for: category)),
                                stacking: .standard
                            )
                            .foregroundStyle(by: .value("Stage", name(of: category)))
                        }
                    }
                }
                .chartForegroundStyleScale([
                    "To Do": Color.secondary,
                    "In Progress": Color.blue,
                    "Done": Color.green,
                ])
                .chartYAxisLabel("Cards")
                .frame(height: 220)
            }
        }
    }

    // MARK: - Control chart

    private var controlChart: some View {
        let points = model.controlChart(days: window)
        let averages = points.rollingAverage(window: 7, using: \.cycleTime)
        let deviation = points.standardDeviation(using: \.cycleTime)
        let mean = points.isEmpty ? 0 : points.reduce(0) { $0 + $1.cycleTime } / Double(points.count)

        return section(
            title: "Control Chart",
            caption: "How long each finished card took. Cycle time runs from the moment work started; lead time from the moment it was asked for. The band is one standard deviation either side of the average — a dot outside it did not merely take longer, it took unusually long."
        ) {
            if points.isEmpty {
                empty("Nothing has been finished in this period yet.")
            } else {
                Chart {
                    // The band first, so the dots sit on top of it.
                    RectangleMark(
                        xStart: .value("From", points.first?.completedAt ?? .now),
                        xEnd: .value("To", points.last?.completedAt ?? .now),
                        yStart: .value("Low", max(0, mean - deviation)),
                        yEnd: .value("High", mean + deviation)
                    )
                    .foregroundStyle(.blue.opacity(0.08))

                    ForEach(points) { point in
                        PointMark(
                            x: .value("Finished", point.completedAt),
                            y: .value("Days", point.cycleTime)
                        )
                        .foregroundStyle(.blue)
                        .symbolSize(40)

                        PointMark(
                            x: .value("Finished", point.completedAt),
                            y: .value("Days", point.leadTime)
                        )
                        .foregroundStyle(.secondary.opacity(0.5))
                        .symbolSize(20)
                    }

                    ForEach(Array(zip(points, averages)), id: \.0.id) { point, average in
                        LineMark(
                            x: .value("Finished", point.completedAt),
                            y: .value("Rolling average", average),
                            series: .value("Series", "average")
                        )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                    }
                }
                .chartYAxisLabel("Days")
                .frame(height: 220)

                HStack(spacing: 16) {
                    legend(color: .blue, text: "Cycle time")
                    legend(color: .secondary.opacity(0.5), text: "Lead time")
                    legend(color: .orange, text: "Rolling average")
                    Spacer()
                    Text(summary(mean: mean, deviation: deviation))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Burnup

    private var burnup: some View {
        let scope = selectedScope
        let points = model.burnup(taskIDs: scope.ids, days: window)

        return section(
            title: "Burnup — \(scope.name)",
            caption: "Work finished against work asked for. Both lines move: a release that slipped because it grew looks nothing like one that slipped because it stalled, and only the upper line tells them apart."
        ) {
            if points.isEmpty {
                empty("Pick a release or an epic with cards in it.")
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Day", point.day),
                            y: .value("Cards", point.scope),
                            series: .value("Series", "Scope")
                        )
                        .foregroundStyle(.secondary)

                        LineMark(
                            x: .value("Day", point.day),
                            y: .value("Cards", point.done),
                            series: .value("Series", "Done")
                        )
                        .foregroundStyle(.green)

                        AreaMark(
                            x: .value("Day", point.day),
                            y: .value("Cards", point.done)
                        )
                        .foregroundStyle(.green.opacity(0.12))
                    }
                }
                .chartYAxisLabel("Cards")
                .frame(height: 200)

                HStack(spacing: 16) {
                    legend(color: .secondary, text: "Scope")
                    legend(color: .green, text: "Finished")
                    Spacer()
                }
            }
        }
    }

    /// What the burnup is about: the first unreleased version, or failing
    /// that the first epic. Both are things someone is waiting on.
    private var selectedScope: (name: String, ids: Set<String>) {
        if let version = model.versions.first(where: { !$0.released }) {
            let ids = Set(((try? model.versionRepository.tasks(inVersion: version.id)) ?? []).map(\.id))
            if !ids.isEmpty { return (version.name, ids) }
        }
        if let epic = model.epics.first {
            let children = model.snapshot?.columns
                .flatMap(\.tasks)
                .filter { $0.epicID == epic.id }
                .map(\.id) ?? []
            if !children.isEmpty { return (epic.title, Set(children)) }
        }
        return ("nothing yet", [])
    }

    // MARK: - Furniture

    private func section(
        title: String,
        caption: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
                .padding(.top, 4)
        }
    }

    private func empty(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func summary(mean: Double, deviation: Double) -> String {
        let format = FloatingPointFormatStyle<Double>().precision(.fractionLength(1))
        return "Average \(mean.formatted(format))d, σ \(deviation.formatted(format))d"
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func name(of category: StatusCategory) -> String {
        switch category {
        case .toDo: "To Do"
        case .inProgress: "In Progress"
        case .done: "Done"
        }
    }
}
