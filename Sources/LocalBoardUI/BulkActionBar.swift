import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// What appears when several cards are picked out.
///
/// It sits at the bottom of the board rather than in the toolbar, because it
/// exists only while a selection does and a toolbar that changes shape is
/// harder to learn than a bar that arrives and leaves.
///
/// Every action here offers Undo afterwards. A bulk edit is the one action
/// where a mis-click costs twenty cards instead of one, and "are you sure"
/// before the fact is a worse answer than "that can be taken back" after it.
struct BulkActionBar: View {

    let model: BoardViewModel

    @State private var isFlagging = false
    @State private var flagReason = ""

    var body: some View {
        HStack(spacing: 12) {
            Text(countText)
                .font(.callout.weight(.medium))

            Divider().frame(height: 16)

            moveMenu
            assignMenu
            priorityMenu
            versionMenu

            Button("Flag…", systemImage: "flag") {
                flagReason = ""
                isFlagging = true
            }
            .buttonStyle(.plain)
            .font(.callout)

            Button("Unflag", systemImage: "flag.slash") {
                model.bulkFlag(false)
            }
            .buttonStyle(.plain)
            .font(.callout)

            Button("Trash", systemImage: "trash", role: .destructive) {
                model.bulkTrash()
            }
            .buttonStyle(.plain)
            .font(.callout)

            Spacer(minLength: 0)

            if let undo = model.lastBulkEdit, !undo.isEmpty {
                Button("Undo \(undo.label)", systemImage: "arrow.uturn.backward") {
                    model.undoLastBulkEdit()
                }
                .buttonStyle(.link)
                .font(.callout)
            }

            Button("Done") { model.clearPicks() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .sheet(isPresented: $isFlagging) { flagSheet }
    }

    private var countText: String {
        let count = model.selectedTaskIDs.count
        return count == 1 ? "1 card selected" : "\(count) cards selected"
    }

    private var moveMenu: some View {
        Menu("Move") {
            ForEach(model.visibleColumns) { column in
                Button(column.name) { model.bulkMove(toStatus: column.status.id) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var assignMenu: some View {
        Menu("Assign") {
            Button("Unassigned") { model.bulkAssign(nil) }
            if !model.people.isEmpty {
                Divider()
                ForEach(model.people) { person in
                    Button(person.name) { model.bulkAssign(person.id) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var priorityMenu: some View {
        Menu("Priority") {
            ForEach(Priority.allCases.sorted(by: >), id: \.self) { priority in
                Button(name(of: priority)) { model.bulkPriority(priority) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var versionMenu: some View {
        Menu("Version") {
            Button("None") { model.bulkVersion(nil) }
            if !model.versions.isEmpty {
                Divider()
                ForEach(model.versions) { version in
                    Button(version.name) { model.bulkVersion(version.id) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.versions.isEmpty)
    }

    private var flagSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Flag \(countText.replacingOccurrences(of: " selected", with: ""))")
                .font(.headline)

            TextField("What is in the way?", text: $flagReason)
                .textFieldStyle(.roundedBorder)

            Text("The reason is searchable: `flag = \"legal\"` finds everything held up by it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isFlagging = false }
                    .keyboardShortcut(.cancelAction)
                Button("Flag") {
                    model.bulkFlag(true, reason: flagReason)
                    isFlagging = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func name(of priority: Priority) -> String {
        switch priority {
        case .lowest: "Lowest"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .highest: "Highest"
        }
    }
}
