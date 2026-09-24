import Foundation
import Testing
@testable import LocalBoardCore

/// The app and the CLI must agree on where the data lives. They resolve it
/// differently — the app asks FileManager, the CLI builds the container path —
/// so this checks both land on the same layout.
@Suite("Container paths")
struct ContainerPathsTests {

    @Test("Layout hangs off the data directory")
    func layout() {
        let root = URL(fileURLWithPath: "/tmp/localboard-test", isDirectory: true)
        let paths = ContainerPaths(dataDirectory: root)

        #expect(paths.databaseFile.lastPathComponent == "board.sqlite")
        #expect(paths.diagnosticsDirectory.lastPathComponent == "Diagnostics")
        #expect(paths.attachmentsDirectory.lastPathComponent == "Attachments")
        #expect(paths.diagnosticsDirectory.deletingLastPathComponent().path == root.path)
    }

    @Test("Diagnostics are a separate folder, never mixed with user content")
    func diagnosticsAreSeparate() {
        let paths = ContainerPaths(dataDirectory: URL(fileURLWithPath: "/tmp/x", isDirectory: true))
        #expect(paths.diagnosticsDirectory != paths.dataDirectory)
        #expect(paths.diagnosticsDirectory != paths.attachmentsDirectory)
        #expect(paths.databaseFile.deletingLastPathComponent() != paths.diagnosticsDirectory)
    }

    @Test("Sandbox is detected from the environment the sandbox sets")
    func hostDetection() {
        #expect(ContainerPaths.detectHost(environment: [:]) == .externalTool)
        #expect(
            ContainerPaths.detectHost(environment: ["APP_SANDBOX_CONTAINER_ID": AppIdentity.bundleIdentifier])
                == .sandboxedApp
        )
    }

    @Test("The CLI resolves the app's container, not its own Application Support")
    func externalToolResolvesContainer() throws {
        let paths = try ContainerPaths.resolve(host: .externalTool)
        let path = paths.dataDirectory.path

        #expect(path.contains("Library/Containers/\(AppIdentity.bundleIdentifier)"))
        #expect(path.hasSuffix("Data/Library/Application Support/\(AppIdentity.dataFolderName)"))
    }

    @Test("Explicit roots are honoured, which is what lets tests stay hermetic")
    func explicitRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = try ContainerPaths.resolve(host: .explicit(root))
        #expect(paths.dataDirectory == root)
    }

    @Test("Creating directories is idempotent")
    func createDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = ContainerPaths(dataDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }

        try paths.createDirectoriesIfNeeded()
        try paths.createDirectoriesIfNeeded()

        #expect(FileManager.default.fileExists(atPath: paths.diagnosticsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: paths.attachmentsDirectory.path))
    }
}
