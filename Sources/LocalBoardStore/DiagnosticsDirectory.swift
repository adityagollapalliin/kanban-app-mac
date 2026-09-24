import Foundation
import LocalBoardCore

/// Owns the `Diagnostics` folder: enumerating it, reporting its size, writing
/// to it, and enforcing the 24-hour retention rule.
///
/// The *decision* about what is expired lives in `DiagnosticsPolicy` in the Core
/// layer and is a pure function of `(modification date, now)`. This type only
/// performs the I/O, so the retention rule is tested without touching the clock
/// or the file system.
public final class DiagnosticsDirectory: @unchecked Sendable {

    public let directory: URL
    public let policy: DiagnosticsPolicy

    private let fileManager: FileManager
    private let clock: ClockProvider
    private let lock = NSLock()

    public init(
        directory: URL,
        policy: DiagnosticsPolicy = DiagnosticsPolicy(),
        clock: ClockProvider = SystemClock(),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.policy = policy
        self.clock = clock
        self.fileManager = fileManager
    }

    public convenience init(
        paths: ContainerPaths,
        policy: DiagnosticsPolicy = DiagnosticsPolicy(),
        clock: ClockProvider = SystemClock(),
        fileManager: FileManager = .default
    ) {
        self.init(
            directory: paths.diagnosticsDirectory,
            policy: policy,
            clock: clock,
            fileManager: fileManager
        )
    }

    // MARK: - Reading

    /// Every file currently in the folder. Missing folder means no files, not an
    /// error — the folder is created lazily on first write.
    public func files() throws -> [DiagnosticsFile] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            throw LocalBoardError.diagnosticsPurgeFailed(
                detail: "Could not read the diagnostics folder: \(error.localizedDescription)"
            )
        }

        return contents.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return DiagnosticsFile(
                url: url,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                byteSize: Int64(values.fileSize ?? 0)
            )
        }
    }

    /// What Settings › Diagnostics shows: file count, total size, age range.
    public func summary() throws -> DiagnosticsSummary {
        policy.summary(of: try files())
    }

    // MARK: - Purging

    @discardableResult
    public func purgeExpired() throws -> Int {
        let now = clock.now
        let expired = policy.expiredFiles(in: try files(), now: now)
        return try delete(expired, reason: "expired")
    }

    /// The "Delete now" button in Settings.
    @discardableResult
    public func deleteAll() throws -> Int {
        try delete(try files(), reason: "user request")
    }

    @discardableResult
    private func delete(_ targets: [DiagnosticsFile], reason: String) throws -> Int {
        guard !targets.isEmpty else { return 0 }

        lock.lock()
        defer { lock.unlock() }

        var deleted = 0
        var failures: [String] = []

        for file in targets {
            do {
                try fileManager.removeItem(at: file.url)
                deleted += 1
            } catch CocoaError.fileNoSuchFile {
                // Already gone — another process or an earlier pass removed it.
                deleted += 1
            } catch {
                // File names are ours, not user content, but the path contains
                // the home directory, so it is logged privately.
                failures.append(error.localizedDescription)
            }
        }

        Log.diagnostics.info(
            "Deleted \(deleted, privacy: .public) diagnostic file(s) (\(reason, privacy: .public))."
        )

        if let first = failures.first, deleted == 0 {
            throw LocalBoardError.diagnosticsPurgeFailed(detail: first)
        }
        return deleted
    }

    /// When the oldest surviving file becomes purgeable, so maintenance can be
    /// scheduled rather than polled.
    public func nextExpiry() throws -> Date? {
        policy.nextExpiry(in: try files(), now: clock.now)
    }

    // MARK: - Writing

    /// Appends one line to today's diagnostic file.
    ///
    /// Callers pass only app-generated text: event names, durations, error
    /// categories, record UUIDs. User content never reaches this method, and
    /// `Scripts/lint-source.sh` fails the build if it looks like it might.
    public func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }

        let now = clock.now
        let line = "\(DiagnosticsDirectory.timestamp(now))\t\(event)\n"
        guard let bytes = line.data(using: .utf8) else { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(
                "\(AppIdentity.commandLineName)-\(DiagnosticsDirectory.dayStamp(now)).log"
            )

            if fileManager.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: bytes)
            } else {
                try bytes.write(to: file, options: .atomic)
            }
        } catch {
            // Diagnostics must never take the app down or surface an alert.
            Log.diagnostics.error("Could not append to the diagnostics log.")
        }
    }

    // Format styles rather than cached `DateFormatter` instances: they are
    // value types and `Sendable`, so they need no synchronisation.
    private static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }

    private static func dayStamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    }
}
