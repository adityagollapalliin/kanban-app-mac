import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// One card in a window of its own.
///
/// The point is being able to read two cards side by side, which an inspector
/// pinned to the board cannot do. It edits the same view model as the board,
/// so a change made here appears there immediately — these are two views of
/// one card, not two copies of it.
public struct TaskWindow: View {

    public static let identifier = "card"

    let taskID: String?

    @Environment(AppEnvironment.self) private var environment

    public init(taskID: String?) {
        self.taskID = taskID
    }

    public var body: some View {
        Group {
            if let model = environment.board, let task = task(in: model) {
                TaskDetailView(task: task, model: model)
                    .navigationTitle(model.tag(for: task))
                    .navigationSubtitle(task.title)
            } else {
                // The card was trashed or deleted while its window was open.
                // Saying so beats an empty window that looks broken.
                ContentUnavailableView(
                    "This card is no longer on the board",
                    systemImage: "square.slash",
                    description: Text("It may have been trashed. Close this window and look in the Trash.")
                )
            }
        }
        .frame(minWidth: 320, minHeight: 420)
        // A card in its own window is the same app, so it follows the same
        // appearance and accent as the board it came from.
        .preferredColorScheme(environment.board?.appearance.colorScheme)
        .tint(environment.board.flatMap { $0.accentName.isEmpty ? nil : PaletteColor.named($0.accentName).color })
    }

    private func task(in model: BoardViewModel) -> BoardTask? {
        guard let taskID else { return nil }
        return model.snapshot?.columns.lazy.flatMap(\.tasks).first { $0.id == taskID }
            ?? model.snapshot?.backlog?.tasks.first { $0.id == taskID }
    }
}
