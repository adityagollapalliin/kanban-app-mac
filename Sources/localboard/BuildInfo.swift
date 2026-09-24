import Foundation

/// Mirrors MARKETING_VERSION in Config/AppInfo.xcconfig. The CLI has no bundle
/// of its own to read it from.
enum BuildInfo {
    static let marketingVersion = "0.1.0"
}
