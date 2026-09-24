import Foundation

/// Single source of truth for how the app names itself on disk.
///
/// Renaming the app means changing these constants and the matching values in
/// `Config/AppInfo.xcconfig`. Nothing else in the codebase hardcodes the name.
public enum AppIdentity {
    public static let displayName = "LocalBoard"
    public static let bundleIdentifier = "dev.localboard.LocalBoard"
    public static let commandLineName = "localboard"

    /// Folder inside the container's Application Support directory.
    public static let dataFolderName = "LocalBoard"

    /// Clearly named, separate from user content, purged every 24 hours.
    public static let diagnosticsFolderName = "Diagnostics"

    public static let databaseFileName = "board.sqlite"
    public static let attachmentsFolderName = "Attachments"

    /// Subsystem for `os.Logger`. Never used as a network identifier — there is no network.
    public static let loggingSubsystem = bundleIdentifier
}
