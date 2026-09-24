import AppKit
import SwiftUI
import LocalBoardCore
import LocalBoardStore

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            DiagnosticsSettingsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            PeopleSettingsView()
                .tabItem { Label("People", systemImage: "person.2") }
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 380)
    }
}

/// Requirement 2.4: show where diagnostics live, how big they are, and offer a
/// one-click delete. The 24-hour purge happens whether or not this pane is ever
/// opened; this is visibility, not the mechanism.
struct DiagnosticsSettingsView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var summary: DiagnosticsSummary = .empty
    @State private var message: String?
    @State private var failure: LocalBoardError?

    var body: some View {
        Form {
            Section("Location") {
                if let directory = environment.diagnostics?.directory {
                    Text(directory.path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .accessibilityLabel("Diagnostics folder: \(directory.path)")

                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([directory])
                    }
                    .accessibilityHint("Opens the diagnostics folder in Finder")
                } else {
                    Text("Not available yet.").foregroundStyle(.secondary)
                }
            }

            Section("Contents") {
                LabeledContent("Files", value: "\(summary.fileCount)")
                LabeledContent("Size", value: summary.totalBytes.formatted(.byteCount(style: .file)))
                LabeledContent("Oldest entry", value: oldestDescription)
                LabeledContent("Kept for", value: "24 hours, then deleted automatically")
            }

            Section {
                HStack {
                    Button("Delete Now", role: .destructive, action: deleteNow)
                        .accessibilityHint("Deletes every diagnostic file immediately")
                    Spacer()
                    if let message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
            } footer: {
                Text("Diagnostics never contain your task titles, descriptions, comments or file names, and never leave this Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
        .onChange(of: environment.externalChangeCount) { _, _ in refresh() }
        .alert(
            failure?.errorDescription ?? "Something went wrong.",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure?.recoverySuggestion ?? "")
        }
    }

    private var oldestDescription: String {
        guard let oldest = summary.oldestModifiedAt else { return "None" }
        return oldest.formatted(.relative(presentation: .named))
    }

    private func refresh() {
        guard let diagnostics = environment.diagnostics else { return }
        do {
            summary = try diagnostics.summary()
        } catch let error as LocalBoardError {
            failure = error
        } catch {
            failure = .diagnosticsPurgeFailed(detail: error.localizedDescription)
        }
    }

    private func deleteNow() {
        guard let diagnostics = environment.diagnostics else { return }
        do {
            let deleted = try diagnostics.deleteAll()
            message = deleted == 1 ? "Deleted 1 file." : "Deleted \(deleted) files."
            refresh()
        } catch let error as LocalBoardError {
            failure = error
        } catch {
            failure = .diagnosticsPurgeFailed(detail: error.localizedDescription)
        }
    }

}

/// Plain-language statement of the privacy posture, with the paths that back it
/// up. The same facts are in PRIVACY.md.
struct PrivacySettingsView: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Form {
            Section("What leaves this Mac") {
                Label("Nothing", systemImage: "wifi.slash")
                Text("\(AppIdentity.displayName) has no network entitlement, so macOS will not let it open a connection even if it tried. There are no accounts, no sync and no analytics.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Where your work is stored") {
                if let paths = environment.paths {
                    Text(paths.dataDirectory.path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([paths.dataDirectory])
                    }
                }
                Text("Boards, tasks, comments and attachments stay here until you delete them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


/// The people cards can be assigned to.
///
/// No accounts, no invitations, no sign-in: a person here is a name, so that
/// `assignee = "Sam"` has something to match and a card can say who is
/// carrying it. That is the whole of it, and it is why this pane is a list and
/// a text field rather than a directory.
struct PeopleSettingsView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var newName = ""
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let model = environment.board {
                content(model)
            } else {
                Text("Not available yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func content(_ model: BoardViewModel) -> some View {
        if model.people.isEmpty {
            ContentUnavailableView {
                Label("Nobody yet", systemImage: "person.2")
            } description: {
                Text("Add a name and cards can be assigned to it.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(model.people) { person in
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                        Text(person.name)

                        Spacer(minLength: 0)

                        Button {
                            model.deletePerson(person.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(person.name). Their cards stay, unassigned.")
                        .accessibilityLabel("Remove \(person.name)")
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        Divider()

        HStack(spacing: 8) {
            TextField("Add someone", text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($addFieldFocused)
                .onSubmit { add(to: model) }

            Button("Add") { add(to: model) }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)

        Text("Removing someone leaves their cards where they are, unassigned.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
    }

    private func add(to model: BoardViewModel) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.createPerson(named: name)
        newName = ""
        addFieldFocused = true
    }
}
