import Foundation
import os

/// Logging rules for this app, enforced by `Scripts/lint-source.sh`:
///
/// 1. User content — task titles, descriptions, comments, labels, people's
///    names, file names — is **never** interpolated into a log line, not even
///    marked `.private`. Records are referred to by UUID.
/// 2. Identifiers are interpolated as `.private` so they are redacted in
///    `log stream` output from another process.
/// 3. There is no `.public` interpolation of anything derived from user data.
///
/// The lint script fails the build if a logger call interpolates an identifier
/// named title/description/body/name/comment/note, or uses `privacy: .public`.
public enum Log {
    public static let app = Logger(subsystem: AppIdentity.loggingSubsystem, category: "app")
    public static let store = Logger(subsystem: AppIdentity.loggingSubsystem, category: "store")
    public static let migration = Logger(subsystem: AppIdentity.loggingSubsystem, category: "migration")
    public static let diagnostics = Logger(subsystem: AppIdentity.loggingSubsystem, category: "diagnostics")
    public static let cli = Logger(subsystem: AppIdentity.loggingSubsystem, category: "cli")
    public static let ui = Logger(subsystem: AppIdentity.loggingSubsystem, category: "ui")
}
