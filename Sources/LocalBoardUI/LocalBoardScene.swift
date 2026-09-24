import AppKit
import SwiftUI
import LocalBoardCore

/// The app's scene graph.
///
/// Declared in the library rather than the app target so that both build paths
/// — the Xcode app target and `Scripts/bundle-spm.sh` — share one entry point
/// (`App/main.swift`) and cannot drift apart.
public struct LocalBoardScene: App {

    @State private var environment = AppEnvironment()

    public init() {}

    public var body: some Scene {
        WindowGroup(AppIdentity.displayName) {
            RootView()
                .environment(environment)
                .task { environment.start() }
        }
        .defaultSize(width: 1_180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // Undo and redo belong in the Edit menu with their standard
            // shortcuts, not only on a button somebody has to find.
            CommandGroup(replacing: .undoRedo) {
                Button(environment.board?.undoLabel.map { "Undo \($0)" } ?? "Undo") {
                    environment.board?.undo()
                }
                .keyboardShortcut("z")
                .disabled(environment.board?.canUndo != true)

                Button(environment.board?.redoLabel.map { "Redo \($0)" } ?? "Redo") {
                    environment.board?.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(environment.board?.canRedo != true)
            }
        }

        // ⌥-click a card, or use its menu. A card opened this way is the same
        // card the board is showing, edited through the same view model.
        WindowGroup(id: TaskWindow.identifier, for: String.self) { $taskID in
            TaskWindow(taskID: taskID)
                .environment(environment)
        }
        .defaultSize(width: 380, height: 560)

        // Optional, and off unless asked for: a menu bar item nobody wanted is
        // clutter in the one strip of screen everything else competes for.
        MenuBarExtra(isInserted: Binding(
            get: { environment.showsMenuBarExtra },
            set: { environment.setShowsMenuBarExtra($0) }
        )) {
            MenuBarBoard()
                .environment(environment)
        } label: {
            MenuBarLabel()
                .environment(environment)
        }

        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}
