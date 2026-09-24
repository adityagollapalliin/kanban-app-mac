import AppKit
import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// Reaching a folder outside the sandbox, the only way the sandbox allows.
///
/// The user picks the folder; macOS hands back a URL the app may open, and a
/// *security-scoped bookmark* is the durable form of that permission. Without
/// the bookmark the path is a string the app has no right to read after the
/// next launch. Resolving one is asking macOS "does this app still have
/// permission for this folder?", and the answer can be no — the folder moved,
/// the permission was revoked — which is why every call here can come back
/// empty rather than assuming it worked.
@MainActor
enum RepositoryAccess {

    /// Asks the user for a folder and returns it with a bookmark to keep.
    static func chooseFolder() -> (url: URL, bookmark: Data?)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Link"
        panel.message = "Pick the folder containing the repository. It is read, never written."

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return (url, bookmark)
    }

    /// Runs `body` with the folder open, and closes it again afterwards.
    ///
    /// The stop is in a `defer` because a security-scoped resource left open
    /// leaks a permission the app is meant to hold only while it is looking.
    static func withAccess<T>(to link: RepositoryLink, _ body: (URL) -> T) -> T? {
        guard let bookmark = link.bookmark else {
            // No bookmark: this database was written on another Mac, or the
            // link predates the permission. The path alone is not enough.
            return nil
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }

        return body(url)
    }
}
