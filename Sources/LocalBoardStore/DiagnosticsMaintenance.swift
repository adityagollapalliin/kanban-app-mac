import Foundation
import LocalBoardCore

/// Runs the 24-hour purge without keeping the Mac awake.
///
/// Energy budget notes, because this is the app's only timer:
///  * The interval is one hour with **fifteen minutes of leeway**, so the
///    kernel coalesces the wakeup with whatever else is already scheduled
///    instead of waking the CPU on its own account. App Nap stays available.
///  * There is no polling anywhere else in the app; every other update is
///    driven by an event.
///  * The app also purges at launch and on wake from sleep, so a Mac that was
///    asleep past the retention window cleans up the moment it comes back.
public final class DiagnosticsMaintenance: @unchecked Sendable {

    public static let interval: TimeInterval = 60 * 60
    public static let leeway: DispatchTimeInterval = .seconds(15 * 60)

    private let directory: DiagnosticsDirectory
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleIdentifier).diagnostics", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()

    public init(directory: DiagnosticsDirectory) {
        self.directory = directory
    }

    /// Purges immediately, then on a low-frequency, high-leeway timer.
    public func start() {
        purgeNow()

        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + DiagnosticsMaintenance.interval,
            repeating: DiagnosticsMaintenance.interval,
            leeway: DiagnosticsMaintenance.leeway
        )
        source.setEventHandler { [weak self] in
            self?.purgeNow()
        }
        source.resume()
        timer = source
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    /// Safe to call from launch, from wake-from-sleep, and from the timer.
    public func purgeNow() {
        do {
            let deleted = try directory.purgeExpired()
            if deleted > 0 {
                directory.record("diagnostics.purge deleted=\(deleted)")
            }
        } catch {
            Log.diagnostics.error("Scheduled diagnostics purge did not complete.")
        }
    }

    deinit {
        timer?.cancel()
    }
}
