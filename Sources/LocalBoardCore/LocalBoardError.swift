import Foundation

/// Every error the user can see. Each case carries a plain-language description
/// and a recovery suggestion — there are no thrown strings and no fatalError in
/// production paths.
public enum LocalBoardError: Error, LocalizedError, Equatable {
    case containerUnavailable(reason: String)
    case databaseOpenFailed(path: String, detail: String)
    case databaseQueryFailed(detail: String)
    case migrationFailed(version: Int, detail: String)
    case schemaTooNew(fileVersion: Int, supportedVersion: Int)
    case diagnosticsPurgeFailed(detail: String)
    case notFound(entity: String)
    case invalidInput(field: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return "\(AppIdentity.displayName) could not open its data folder."
        case .databaseOpenFailed:
            return "\(AppIdentity.displayName) could not open your board database."
        case .databaseQueryFailed:
            return "A database operation did not complete."
        case .migrationFailed(let version, _):
            return "Upgrading your data to version \(version) did not finish."
        case .schemaTooNew(let fileVersion, let supportedVersion):
            return """
                Your data was saved by a newer version of \(AppIdentity.displayName) \
                (format \(fileVersion); this build understands \(supportedVersion)).
                """
        case .diagnosticsPurgeFailed:
            return "Old diagnostic files could not be deleted."
        case .notFound(let entity):
            return "That \(entity) no longer exists."
        case .invalidInput(let field, _):
            return "\(field) is not valid."
        }
    }

    public var failureReason: String? {
        switch self {
        case .containerUnavailable(let reason): return reason
        case .databaseOpenFailed(_, let detail): return detail
        case .databaseQueryFailed(let detail): return detail
        case .migrationFailed(_, let detail): return detail
        case .schemaTooNew: return nil
        case .diagnosticsPurgeFailed(let detail): return detail
        case .notFound: return nil
        case .invalidInput(_, let detail): return detail
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .containerUnavailable:
            return "Check that your home folder is available, then quit and reopen \(AppIdentity.displayName)."
        case .databaseOpenFailed:
            return "Quit and reopen the app. If it keeps happening, restore from a backup folder."
        case .databaseQueryFailed:
            return "Try the action again. Nothing was saved."
        case .migrationFailed:
            return "Your previous data was left untouched. Reopen the app to retry the upgrade."
        case .schemaTooNew:
            return "Update \(AppIdentity.displayName) to the newer version, or open a backup made by this one."
        case .diagnosticsPurgeFailed:
            return "Open Settings › Diagnostics and choose Delete Now."
        case .notFound:
            return "Refresh the view to see the current contents."
        case .invalidInput:
            return "Correct the highlighted field and try again."
        }
    }
}
