import Foundation

/// Resolves every on-disk location the app uses.
///
/// Two processes need these paths and they resolve them differently:
///
/// - The **sandboxed app** asks `FileManager`, which already redirects
///   Application Support into the container.
/// - The **`localboard` CLI** is not sandboxed, so `FileManager` would hand it
///   `~/Library/Application Support` — the wrong directory. It builds the
///   container path explicitly instead.
///
/// Both land on the same bytes on disk.
public struct ContainerPaths: Sendable, Equatable {

    public enum Host: Sendable, Equatable {
        /// Running inside the App Sandbox (the `.app`).
        case sandboxedApp
        /// Running outside it (the CLI, or a unit test).
        case externalTool
        /// An explicit root, used by tests.
        case explicit(URL)
    }

    /// `.../Application Support/LocalBoard`
    public let dataDirectory: URL
    /// `.../Application Support/LocalBoard/board.sqlite`
    public let databaseFile: URL
    /// `.../Application Support/LocalBoard/Diagnostics`
    public let diagnosticsDirectory: URL
    /// `.../Application Support/LocalBoard/Attachments`
    public let attachmentsDirectory: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        self.databaseFile = dataDirectory.appendingPathComponent(AppIdentity.databaseFileName)
        self.diagnosticsDirectory = dataDirectory
            .appendingPathComponent(AppIdentity.diagnosticsFolderName, isDirectory: true)
        self.attachmentsDirectory = dataDirectory
            .appendingPathComponent(AppIdentity.attachmentsFolderName, isDirectory: true)
    }

    /// Detects whether this process is sandboxed. The sandbox sets
    /// `APP_SANDBOX_CONTAINER_ID` in the environment of every process it contains.
    public static func detectHost(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Host {
        environment["APP_SANDBOX_CONTAINER_ID"] == nil ? .externalTool : .sandboxedApp
    }

    public static func resolve(
        host: Host = detectHost(),
        fileManager: FileManager = .default
    ) throws -> ContainerPaths {
        switch host {
        case .explicit(let root):
            return ContainerPaths(dataDirectory: root)

        case .sandboxedApp:
            let supportDirectories = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            guard let support = supportDirectories.first else {
                throw LocalBoardError.containerUnavailable(
                    reason: "macOS did not report an Application Support directory for this process."
                )
            }
            return ContainerPaths(
                dataDirectory: support.appendingPathComponent(AppIdentity.dataFolderName, isDirectory: true)
            )

        case .externalTool:
            // ~/Library/Containers/<bundle id>/Data/Library/Application Support/LocalBoard
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            let container = home
                .appendingPathComponent("Library/Containers", isDirectory: true)
                .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
                .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
                .appendingPathComponent(AppIdentity.dataFolderName, isDirectory: true)
            return ContainerPaths(dataDirectory: container)
        }
    }

    /// Creates the directory tree if it is missing. Safe to call on every launch.
    public func createDirectoriesIfNeeded(fileManager: FileManager = .default) throws {
        for directory in [dataDirectory, diagnosticsDirectory, attachmentsDirectory] {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw LocalBoardError.containerUnavailable(
                    reason: "Could not create \(directory.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }
}
