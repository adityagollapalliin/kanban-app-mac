import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// Why a card was closed, which parts of the product it touches, which
/// releases it affects, and where the problem shows up.
///
/// One section rather than four, because all four are answers a project's own
/// vocabulary supplies — and a card with none of them set should take up no
/// room at all.
struct CardVocabularySection: View {

    let task: BoardTask
    let model: BoardViewModel

    private var isDone: Bool { task.completedAt != nil }

    var body: some View {
        Section("Classification") {
            kind
            if isDone || task.resolutionID != nil { resolution }
            if !model.components.isEmpty { components }
            if !model.versions.isEmpty { versions }
            environment
        }
    }

    // MARK: Kind

    /// The kind of card, from the project's own list.
    ///
    /// Read by the card's raw code rather than the built-in enumeration: a
    /// project can define its own kinds, and the enumeration reads those as
    /// ordinary work. Showing it would call an Initiative a Task.
    private var kind: some View {
        Picker("Kind", selection: Binding(
            get: { task.typeCode },
            set: { model.setIssueTypeCode($0, on: task.id) }
        )) {
            ForEach(model.issueTypes) { type in
                Label(type.name, systemImage: type.symbol.isEmpty ? "square" : type.symbol)
                    .tag(type.code)
            }
        }
    }

    // MARK: Resolution

    private var resolution: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker("Resolution", selection: Binding(
                get: { task.resolutionID },
                set: { model.setResolution($0, on: task.id) }
            )) {
                Text("Unresolved").tag(String?.none)
                ForEach(model.resolutions) { option in
                    Text(option.name).tag(String?.some(option.id))
                }
            }

            if let resolvedAt = task.resolvedAt, task.resolutionID != nil {
                Text("Resolved \(resolvedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Components

    private var components: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Components")
                Spacer()
                Menu {
                    ForEach(model.components) { component in
                        let already = model.components(for: task).contains { $0.id == component.id }
                        Button {
                            if already {
                                model.removeComponent(component.id, from: task.id)
                            } else {
                                model.addComponent(component.id, to: task.id)
                            }
                        } label: {
                            if already {
                                Label(component.name, systemImage: "checkmark")
                            } else {
                                Text(component.name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            let chosen = model.components(for: task)
            if chosen.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(chosen) { component in
                        Button {
                            model.removeComponent(component.id, from: task.id)
                        } label: {
                            Text(component.name)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Click to take it off")
                    }
                }
            }
        }
    }

    // MARK: Versions

    private var versions: some View {
        VStack(alignment: .leading, spacing: 6) {
            versionRow(.fix)
            versionRow(.affects)
        }
    }

    private func versionRow(_ role: VersionRole) -> some View {
        let chosen = model.versions(for: task, role: role)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(role.label)
                Spacer()
                Menu {
                    ForEach(model.versions) { version in
                        let already = chosen.contains { $0.id == version.id }
                        Button {
                            if already {
                                model.removeVersion(version.id, from: task.id, as: role)
                            } else {
                                model.addVersion(version.id, to: task.id, as: role)
                            }
                        } label: {
                            if already {
                                Label(version.name, systemImage: "checkmark")
                            } else {
                                Text(version.name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if chosen.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(chosen.map(\.name).joined(separator: ", "))
                    .font(.caption)
            }
        }
    }

    // MARK: Environment

    private var environment: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Environment")
            TextField(
                "Safari 18 on an M1, staging only",
                text: Binding(
                    get: { task.environment },
                    set: { model.setEnvironment($0, on: task.id) }
                ),
                axis: .vertical
            )
            .lineLimit(1...3)
        }
    }
}
