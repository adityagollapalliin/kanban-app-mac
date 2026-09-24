import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The row of toggles above the board, and the facet dropdowns beside them.
///
/// Everything here narrows: several filters on at once mean *all* of them, and
/// a facet is one more `AND`. Nothing here is a mode that replaces what else
/// is set, because a filter that silently turns another one off is a filter
/// you cannot trust.
struct QuickFilterBar: View {

    @Bindable var model: BoardViewModel

    @State private var isAddingFilter = false
    @State private var newName = ""
    @State private var editing: QuickFilter?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.quickFilters) { filter in
                        toggle(filter)
                    }

                    addButton

                    Divider().frame(height: 16)

                    facets

                    if model.hasActiveFilters {
                        Button("Clear", systemImage: "xmark.circle.fill") {
                            model.clearFilters()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Turn off every filter and facet")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

            Divider()
        }
        .background(.bar)
        .sheet(isPresented: $isAddingFilter) {
            QuickFilterSheet(model: model, existing: nil)
        }
        .sheet(item: $editing) { filter in
            QuickFilterSheet(model: model, existing: filter)
        }
    }

    private func toggle(_ filter: QuickFilter) -> some View {
        let isOn = model.activeQuickFilterIDs.contains(filter.id)

        return Button {
            model.toggleQuickFilter(filter.id)
        } label: {
            Text(filter.name)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isOn ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                            in: Capsule())
                .foregroundStyle(isOn ? .white : .primary)
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: isOn ? 0 : 1))
        }
        .buttonStyle(.plain)
        // The query is the tooltip, so a filter is never a button whose
        // meaning you have to take on trust.
        .help(filter.query)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button("Edit…") { editing = filter }
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.deleteQuickFilter(filter.id)
            }
        }
    }

    private var addButton: some View {
        Button {
            newName = ""
            isAddingFilter = true
        } label: {
            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help("Keep the current search as a quick filter")
        .accessibilityLabel("Add a quick filter")
    }

    @ViewBuilder
    private var facets: some View {
        facetMenu(
            title: "Assignee",
            selection: model.person(id: model.facetAssigneeID)?.name,
            options: model.people.map { ($0.id, $0.name) },
            binding: $model.facetAssigneeID
        )

        facetMenu(
            title: "Epic",
            selection: model.epics.first { $0.id == model.facetEpicID }?.title,
            options: model.epics.map { ($0.id, $0.title) },
            binding: $model.facetEpicID
        )

        facetMenu(
            title: "Label",
            selection: model.labels.first { $0.id == model.facetLabelID }?.name,
            options: model.labels.map { ($0.id, $0.name) },
            binding: $model.facetLabelID
        )

        Menu {
            Button("Any Type") { model.facetType = nil }
            Divider()
            ForEach(TaskType.allCases, id: \.self) { type in
                Button(typeName(type)) { model.facetType = type }
            }
        } label: {
            facetLabel(title: "Type", selection: model.facetType.map(typeName))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func facetMenu(
        title: String,
        selection: String?,
        options: [(String, String)],
        binding: Binding<String?>
    ) -> some View {
        Menu {
            Button("Any \(title)") { binding.wrappedValue = nil }
            if !options.isEmpty {
                Divider()
                ForEach(options, id: \.0) { option in
                    Button(option.1) { binding.wrappedValue = option.0 }
                }
            }
        } label: {
            facetLabel(title: title, selection: selection)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(options.isEmpty)
    }

    private func facetLabel(title: String, selection: String?) -> some View {
        HStack(spacing: 3) {
            Text(selection ?? title)
                .font(.caption)
                .foregroundStyle(selection == nil ? .secondary : .primary)
            Image(systemName: "chevron.down")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(selection == nil ? Color.clear : Color.accentColor.opacity(0.15))
        )
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
    }

    private func typeName(_ type: TaskType) -> String {
        switch type {
        case .epic: "Epic"
        case .story: "Story"
        case .task: "Task"
        case .bug: "Bug"
        }
    }
}

/// Writing or editing one quick filter.
struct QuickFilterSheet: View {
    let model: BoardViewModel
    let existing: QuickFilter?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "New quick filter" : "Edit quick filter")
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("Query", text: $query, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .lineLimit(2...4)

            Text("Filters combine with everything else that is on. `is:mine` follows whoever is chosen in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            name = existing?.name ?? ""
            // A new filter starts from what is already typed, because "I have
            // found the thing I keep looking for" is how these get made.
            query = existing?.query ?? model.queryText
        }
    }

    private func save() {
        if let existing {
            model.updateQuickFilter(existing.id, name: name, query: query)
        } else {
            model.createQuickFilter(named: name, query: query)
        }
        dismiss()
    }
}
