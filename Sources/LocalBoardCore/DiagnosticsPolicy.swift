import Foundation

/// One diagnostic file on disk, reduced to the only three facts the policy needs.
public struct DiagnosticsFile: Sendable, Equatable, Hashable {
    public let url: URL
    public let modifiedAt: Date
    public let byteSize: Int64

    public init(url: URL, modifiedAt: Date, byteSize: Int64) {
        self.url = url
        self.modifiedAt = modifiedAt
        self.byteSize = byteSize
    }
}

/// What Settings › Diagnostics displays.
public struct DiagnosticsSummary: Sendable, Equatable {
    public let fileCount: Int
    public let totalBytes: Int64
    public let oldestModifiedAt: Date?
    public let newestModifiedAt: Date?

    public init(fileCount: Int, totalBytes: Int64, oldestModifiedAt: Date?, newestModifiedAt: Date?) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.oldestModifiedAt = oldestModifiedAt
        self.newestModifiedAt = newestModifiedAt
    }

    public static let empty = DiagnosticsSummary(
        fileCount: 0, totalBytes: 0, oldestModifiedAt: nil, newestModifiedAt: nil
    )
}

/// Decides which diagnostic files have outlived the retention window.
///
/// Deliberately a pure value type with no file-system access: the whole 24-hour
/// rule is testable by handing it a list of `(date, size)` pairs and a `now`.
/// `DiagnosticsDirectory` (in the Store layer) does the actual I/O.
public struct DiagnosticsPolicy: Sendable, Equatable {

    /// The hard rule from the brief: diagnostics live at most 24 hours.
    public static let twentyFourHours: TimeInterval = 24 * 60 * 60

    public let retention: TimeInterval

    public init(retention: TimeInterval = DiagnosticsPolicy.twentyFourHours) {
        self.retention = max(0, retention)
    }

    /// A file expires once it is *strictly older* than the retention window.
    /// A file modified exactly `retention` ago is kept; it expires a moment later.
    public func isExpired(_ file: DiagnosticsFile, now: Date) -> Bool {
        now.timeIntervalSince(file.modifiedAt) > retention
    }

    public func expiredFiles(in files: [DiagnosticsFile], now: Date) -> [DiagnosticsFile] {
        files.filter { isExpired($0, now: now) }
    }

    public func survivingFiles(in files: [DiagnosticsFile], now: Date) -> [DiagnosticsFile] {
        files.filter { !isExpired($0, now: now) }
    }

    /// When the oldest surviving file will expire, so the purge timer can be
    /// scheduled instead of polled. `nil` means there is nothing left to purge.
    public func nextExpiry(in files: [DiagnosticsFile], now: Date) -> Date? {
        survivingFiles(in: files, now: now)
            .map { $0.modifiedAt.addingTimeInterval(retention) }
            .min()
    }

    public func summary(of files: [DiagnosticsFile]) -> DiagnosticsSummary {
        guard !files.isEmpty else { return .empty }
        return DiagnosticsSummary(
            fileCount: files.count,
            totalBytes: files.reduce(0) { $0 + $1.byteSize },
            oldestModifiedAt: files.map(\.modifiedAt).min(),
            newestModifiedAt: files.map(\.modifiedAt).max()
        )
    }
}
