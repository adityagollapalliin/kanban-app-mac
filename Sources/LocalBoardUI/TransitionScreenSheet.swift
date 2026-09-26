import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The small screen a transition can stop and show.
///
/// It asks only for what is still missing. A screen that demanded things the
/// card already carries would be a dialog nobody learns anything from, and one
/// that appeared on every move would be a dialog people learn to dismiss
/// without reading — which is worse than not asking.
struct TransitionScreenSheet: View {

    let pending: PendingTransition
    let model: BoardViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    /// Only the fields this card has not answered.
    private var asking: [FieldReference] {
        pending.transition.screenFields.filter { !model.isFilledIn($0, on: pending.taskID) }
    }

    private var title: String {
        pending.transition.screenTitle.isEmpty
            ? (pending.transition.name.isEmpty
                ? "Moving to \(model.statusName(id: pending.statusID))"
                : pending.transition.name)
            : pending.transition.screenTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let task = model.task(id: pending.taskID) {
                    Text("\(model.tag(for: task)) · \(task.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding()

            Form {
                ForEach(asking, id: \.self) { field in
                    entry(field)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("Nothing is saved until you move it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    model.cancelPendingTransition()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Move") {
                    var typed: [FieldReference: String] = [:]
                    for field in asking {
                        typed[field] = values[field.stored] ?? ""
                    }
                    model.completePendingTransition(typed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420)
    }

    @ViewBuilder
    private func entry(_ field: FieldReference) -> some View {
        let binding = Binding(
            get: { values[field.stored] ?? "" },
            set: { values[field.stored] = $0 }
        )

        switch field {
        case .builtIn("assignee"):
            Picker("Assignee", selection: binding) {
                Text("Nobody").tag("")
                ForEach(model.people) { person in
                    Text(person.name).tag(person.id)
                }
            }

        case .builtIn("resolution"):
            Picker("Resolution", selection: binding) {
                Text("None").tag("")
                ForEach(model.resolutions) { resolution in
                    Text(resolution.name).tag(resolution.id)
                }
            }

        case .builtIn("priority"):
            Picker("Priority", selection: binding) {
                Text("Unchanged").tag("")
                ForEach(model.priorityValues) { value in
                    Text(value.name).tag(String(value.code))
                }
            }

        case .builtIn(let name) where ["due", "start"].contains(name):
            // Read the way the search field reads a date, so `+7d` works here
            // too rather than only in a query.
            TextField(
                name.prefix(1).uppercased() + name.dropFirst(),
                text: binding,
                prompt: Text("2026-10-01, today or +7d")
            )

        case .builtIn(let name):
            TextField(name.prefix(1).uppercased() + name.dropFirst(), text: binding)

        case .custom(let id):
            let name = model.customFields.first { $0.id == id }?.name ?? "Field"
            TextField(name, text: binding)
        }
    }
}
