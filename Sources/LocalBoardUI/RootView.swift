import SwiftUI
import LocalBoardCore

/// The window's contents: the board once the database is open, the reason why
/// not if it never opened.
public struct RootView: View {

    @Environment(AppEnvironment.self) private var environment

    public init() {}

    public var body: some View {
        Group {
            if let error = environment.startupError {
                StartupErrorView(error: error)
            } else if let model = environment.board {
                BoardView(model: model, externalChangeCount: environment.externalChangeCount)
            } else {
                opening
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        // nil means "follow the Mac", which is what `system` is for: an
        // explicit .light would freeze the app in light mode rather than
        // following a Mac that switches at sunset.
        .preferredColorScheme(environment.board?.appearance.colorScheme)
        // An empty accent means the one the user chose in System Settings,
        // which is the right default: the app should look like the rest of
        // their Mac unless they ask otherwise.
        .tint(accent)
    }

    private var accent: Color? {
        guard let name = environment.board?.accentName, !name.isEmpty else { return nil }
        return PaletteColor.named(name).color
    }

    /// The gap between the window appearing and the file being open. Usually
    /// too brief to read, which is why it says nothing that would need reading.
    private var opening: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Opening your boards")
    }
}

/// Errors are shown, never swallowed, and always carry a next step.
struct StartupErrorView: View {
    let error: LocalBoardError

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(error.errorDescription ?? "Something went wrong.")
                .font(.headline)
                .multilineTextAlignment(.center)

            if let reason = error.failureReason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: 520)
    }
}
