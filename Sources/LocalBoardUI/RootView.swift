import SwiftUI
import LocalBoardCore

/// Milestone 0 places a deliberate placeholder here: the shell, the error
/// surface and the data path are real, the board is not yet. Milestone 1
/// replaces the body with the workspace sidebar and the Kanban board.
public struct RootView: View {

    @Environment(AppEnvironment.self) private var environment

    public init() {}

    public var body: some View {
        Group {
            if let error = environment.startupError {
                StartupErrorView(error: error)
            } else {
                placeholder
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("\(AppIdentity.displayName) is ready")
                .font(.title2)

            Text("Your boards will appear here. Everything stays on this Mac.")
                .foregroundStyle(.secondary)

            if let paths = environment.paths {
                Text(paths.dataDirectory.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
                    .accessibilityLabel("Data folder location")
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
