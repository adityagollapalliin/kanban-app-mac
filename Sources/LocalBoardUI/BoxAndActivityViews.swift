import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// Cards grouped by the person on them, with what state their work is in.
///
/// The workload view asks "is anyone overloaded". This one asks the simpler
/// question underneath it: what is each person actually holding, and how much
/// of it has started. So it counts by status category rather than by hours,
/// and needs no capacity to be useful.
struct BoxView: View {

    let model: BoardViewModel

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(model.people) { person in
                    box(for: person, cards: cards(of: person))
                }
                box(for: nil, cards: unassigned)
            }
            .padding(14)
        }
    }

    private func cards(of person: Person) -> [BoardTask] {
        model.visibleTasks.filter { task in
            model.assignees(of: task).contains { $0.personID == person.id }
        }
    }

    private var unassigned: [BoardTask] {
        model.visibleTasks.filter { model.assignees(of: $0).isEmpty }
    }

    @ViewBuilder
    private func box(for person: Person?, cards: [BoardTask]) -> some View {
        // Somebody with nothing is shown; nobody-with-nothing is not. An empty
        // "Nobody" box on a fully assigned board is a heading about an absence.
        if person != nil || !cards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header(person, count: cards.count)
                breakdown(cards)
                Divider()
                cardList(cards)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(person?.name ?? "Nobody"), \(cards.count) cards")
        }
    }

    private func header(_ person: Person?, count: Int) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(person.map { PaletteColor.named($0.color).color } ?? Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)

            Text(person?.name ?? "Nobody")
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 0)

            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }

    /// One bar, split by where the work is. A person with ten cards all in
    /// "To Do" and a person with ten spread across the board are carrying very
    /// different weeks, and a count alone cannot say so.
    private func breakdown(_ cards: [BoardTask]) -> some View {
        let counts: [(category: StatusCategory, count: Int)] = StatusCategory.allCases.map { category in
            (category, cards.filter { model.category(of: $0) == category }.count)
        }
        let total = max(1, cards.count)

        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(counts, id: \.category) { entry in
                        if entry.count > 0 {
                            Rectangle()
                                .fill(color(entry.category))
                                .frame(width: proxy.size.width * (Double(entry.count) / Double(total)))
                        }
                    }
                }
            }
            .frame(height: 5)
            .clipShape(Capsule())

            HStack(spacing: 8) {
                ForEach(counts, id: \.category) { entry in
                    if entry.count > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(color(entry.category)).frame(width: 5, height: 5)
                            Text("\(entry.count) \(label(entry.category))")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func cardList(_ cards: [BoardTask]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(cards.prefix(6)) { task in
                Button {
                    model.selectedTaskID = task.id
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: CardAppearance.symbol(forType: task.type))
                            .font(.system(size: 8))
                            .foregroundStyle(CardAppearance.color(forType: task.type))
                        Text(task.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if cards.count > 6 {
                Text("+\(cards.count - 6) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ category: StatusCategory) -> Color {
        switch category {
        case .toDo: Color.secondary.opacity(0.45)
        case .inProgress: .blue
        case .done: .green
        }
    }

    private func label(_ category: StatusCategory) -> String {
        switch category {
        case .toDo: "to do"
        case .inProgress: "doing"
        case .done: "done"
        }
    }
}

/// What has happened, newest first.
///
/// Assembled from what the file already records rather than from a log written
/// alongside it — see `ActivityRepository` for why. Local only: this is the
/// history of a file on one Mac, and there is nothing else it could be.
struct ActivityView: View {

    let model: BoardViewModel

    @State private var kinds: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing has happened yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Creating, moving, commenting on and logging time against cards all show up here.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(byDay, id: \.day) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    row(entry)
                                }
                            } header: {
                                dayHeader(group.day)
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            ForEach(Self.filters, id: \.key) { filter in
                let key = filter.key
                Toggle(filter.label, isOn: Binding(
                    get: { kinds.isEmpty || kinds.contains(key) },
                    set: { on in
                        // Empty means everything. Turning one off from that
                        // state means "only the others", not "none".
                        if kinds.isEmpty { kinds = Set(Self.filters.map(\.key)) }
                        if on { kinds.insert(key) } else { kinds.remove(key) }
                        if kinds.count == Self.filters.count { kinds = [] }
                    }
                ))
                .toggleStyle(.button)
                .buttonStyle(.accessoryBar)
                .font(.caption)
            }

            Spacer(minLength: 0)

            Text("\(entries.count) entries")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private static let filters: [(key: String, label: String)] = [
        ("moves", "Moves"), ("comments", "Comments"), ("files", "Files"), ("time", "Time"),
    ]

    private var entries: [ActivityRepository.Entry] {
        model.activityFeed().filter { entry in
            guard !kinds.isEmpty else { return true }
            switch entry.kind {
            case .created, .statusChanged, .completed: return kinds.contains("moves")
            case .commented: return kinds.contains("comments")
            case .attached: return kinds.contains("files")
            case .logged: return kinds.contains("time")
            }
        }
    }

    private var byDay: [(day: Date, entries: [ActivityRepository.Entry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.at) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    private func dayHeader(_ day: Date) -> some View {
        Text(dayLabel(day))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(.bar)
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }

    private func row(_ entry: ActivityRepository.Entry) -> some View {
        Button {
            model.selectedTaskID = entry.taskID
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: entry.kind.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                if let task = model.task(id: entry.taskID) {
                    Text(model.tag(for: task))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Text(describe(entry))
                    .font(.callout)
                    .lineLimit(2)

                Spacer(minLength: 0)

                Text(entry.at.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(describe(entry))
    }

    private func describe(_ entry: ActivityRepository.Entry) -> String {
        let title = model.task(id: entry.taskID)?.title ?? "a card"

        switch entry.kind {
        case .created:
            return "\(title) was created"
        case .statusChanged(let from, let to):
            let fromName = from.map { model.statusName($0) } ?? "nowhere"
            return "\(title) moved from \(fromName) to \(model.statusName(to))"
        case .commented(let body):
            let firstLine = body.split(separator: "\n").first.map(String.init) ?? body
            return "Comment on \(title): \(firstLine)"
        case .attached(let name):
            return "\(name) was attached to \(title)"
        case .logged(let minutes):
            return "\(minutes) minutes logged against \(title)"
        case .completed:
            return "\(title) was finished"
        }
    }
}

/// Every card in the file, not just this space's.
///
/// The same filters apply — that is the point of it being a view rather than a
/// separate app — so a quick filter set on the board narrows this too.
struct EverythingView: View {

    let model: BoardViewModel
    var onOpenInWindow: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Every card in every space")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(cards.count) cards")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if cards.isEmpty {
                ContentUnavailableView(
                    "Nothing matches",
                    systemImage: "globe",
                    description: Text("The filters that apply to the board apply here too.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(bySpace, id: \.name) { group in
                            Section {
                                ForEach(group.cards) { task in
                                    row(task)
                                }
                            } header: {
                                Text(group.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 5)
                                    .background(.bar)
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private var cards: [BoardTask] { model.everything() }

    private var bySpace: [(name: String, cards: [BoardTask])] {
        let grouped = Dictionary(grouping: cards, by: \.projectID)
        return grouped.keys
            .map { id in (model.projects.first { $0.id == id }?.name ?? "Elsewhere", grouped[id] ?? []) }
            .sorted { $0.name < $1.name }
    }

    private func row(_ task: BoardTask) -> some View {
        Button {
            model.selectedTaskID = task.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: CardAppearance.symbol(forType: task.type))
                    .font(.caption)
                    .foregroundStyle(CardAppearance.color(forType: task.type))

                Text(model.tag(for: task))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Text(task.title)
                    .lineLimit(1)

                if task.flagged {
                    Image(systemName: "flag.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                Spacer(minLength: 0)

                if let due = task.dueDate {
                    Text(due.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(due < .now && task.completedAt == nil ? .red : .secondary)
                }

                Text(model.statusName(task.statusID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in a Window", systemImage: "macwindow") { onOpenInWindow?(task.id) }
        }
        .accessibilityLabel("\(model.tag(for: task)), \(task.title), \(model.statusName(task.statusID))")
    }
}
