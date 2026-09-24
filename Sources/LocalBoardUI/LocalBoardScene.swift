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
        }

        // ⌥-click a card, or use its menu. A card opened this way is the same
        // card the board is showing, edited through the same view model.
        WindowGroup(id: TaskWindow.identifier, for: String.self) { $taskID in
            TaskWindow(taskID: taskID)
                .environment(environment)
        }
        .defaultSize(width: 380, height: 560)

        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}
