import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The board: projects down the side, columns across the middle.
struct BoardView: View {

    @Bindable var model: BoardViewModel
    let externalChangeCount: Int

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail
        }
        .task { model.load() }
        // Another process wrote to the same file. AppEnvironment notices on
        // activation and bumps the counter; this is where the board catches up.
        .onChange(of: externalChangeCount) { model.load() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selectedBoardID) {
            ForEach(model.projects) { project in
                Section {
                    ForEach(model.boards.filter { $0.projectID == project.id }) { board in
                        Label(board.name, systemImage: "rectangle.split.3x1")
                            .tag(board.id)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(project.name)
                        Text(project.key)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if let failure = model.failure {
                failureBanner(failure)
            }

            if let snapshot = model.snapshot {
                board(snapshot)
            } else {
                ContentUnavailableView(
                    "No board selected",
                    systemImage: "rectangle.3.group",
                    description: Text("Pick a board in the sidebar.")
                )
            }
        }
        .navigationTitle(model.snapshot?.board.name ?? AppIdentity.displayName)
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard let snapshot = model.snapshot else { return "" }
        let count = snapshot.taskCount
        return count == 1 ? "1 card" : "\(count) cards"
    }

    private func board(_ snapshot: BoardSnapshot) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(snapshot.columns) { column in
                    BoardColumnView(column: column, model: model)
                }
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    /// A failed action says what failed and what to do, and goes away when the
    /// next one succeeds.
    private func failureBanner(_ error: LocalBoardError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(error.errorDescription ?? "Something went wrong.")
                    .font(.callout.weight(.medium))
                if let suggestion = error.recoverySuggestion ?? error.failureReason {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button("Dismiss") { model.dismissFailure() }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeOut(duration: 0.2), value: model.failure)
    }
}
