import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// How this board shows its work: lanes, card rows, colours, staleness.
///
/// A menu rather than a preferences window because every one of these is worth
/// trying and undoing in a second — you find out whether grouping by assignee
/// helps by looking at it, not by reading a description of it.
struct BoardSettingsMenu: View {

    let model: BoardViewModel

    var body: some View {
        Menu {
            swimlaneSection
            Divider()
            cardFieldSection
            Divider()
            colorSection
            Divider()
            staleSection
        } label: {
            Label("Board", systemImage: "slider.horizontal.3")
                .labelStyle(.titleAndIcon)
        }
        .help("Swimlanes, card layout and colours for this board")
    }

    private var board: Board? { model.snapshot?.board }

    @ViewBuilder
    private var swimlaneSection: some View {
        Menu("Swimlanes") {
            ForEach(SwimlaneMode.allCases, id: \.self) { mode in
                Button {
                    model.setSwimlaneMode(mode)
                } label: {
                    if board?.swimlaneMode == mode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        }
    }

    /// The cap is stated in the menu rather than enforced silently, so turning
    /// a fourth row on explains itself instead of appearing to do nothing.
    @ViewBuilder
    private var cardFieldSection: some View {
        Menu("Card Rows (\(board?.cardFields.count ?? 0) of \(CardField.maximumPerBoard))") {
            ForEach(CardField.allCases, id: \.self) { field in
                Button {
                    model.toggleCardField(field)
                } label: {
                    if board?.cardFields.contains(field) == true {
                        Label(field.label, systemImage: "checkmark")
                    } else {
                        Text(field.label)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var colorSection: some View {
        Menu("Card Colour") {
            ForEach(CardColorRule.allCases, id: \.self) { rule in
                if rule == .query {
                    Menu(rule.label) {
                        if model.savedViews.isEmpty {
                            Text("Save a view first")
                        }
                        ForEach(model.savedViews) { view in
                            Button {
                                model.setColorRule(.query, viewID: view.id)
                            } label: {
                                if board?.colorViewID == view.id {
                                    Label(view.name, systemImage: "checkmark")
                                } else {
                                    Text(view.name)
                                }
                            }
                        }
                    }
                } else {
                    Button {
                        model.setColorRule(rule)
                    } label: {
                        if board?.colorRule == rule {
                            Label(rule.label, systemImage: "checkmark")
                        } else {
                            Text(rule.label)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var staleSection: some View {
        Menu("Stale After") {
            ForEach([1, 2, 3, 5, 7, 14], id: \.self) { days in
                Button {
                    model.setStaleDays(days)
                } label: {
                    let text = days == 1 ? "1 day" : "\(days) days"
                    if board?.staleDays == days {
                        Label(text, systemImage: "checkmark")
                    } else {
                        Text(text)
                    }
                }
            }
        }
        .help("When the days-in-column dots turn amber")
    }
}

/// Editing the lanes a board is cut into by query.
struct SwimlaneEditor: View {

    let model: BoardViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Swimlanes")
                .font(.headline)

            Text("Lanes are matched top to bottom and the first match wins, so a card appears once. Pinned lanes are matched before the board's grouping, whatever it is set to.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.swimlanes) { lane in
                    HStack(spacing: 8) {
                        if lane.pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("Pinned above the grouping")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lane.name)
                            Text(lane.query)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.deleteSwimlane(lane.id)
                        }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(height: 180)

            Divider()

            HStack(spacing: 8) {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                TextField("Query", text: $newQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button("Add") {
                    model.createSwimlane(named: newName, query: newQuery)
                    newName = ""
                    newQuery = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
