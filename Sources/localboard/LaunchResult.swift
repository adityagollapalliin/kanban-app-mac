import Foundation

/// Carries the outcome of `NSWorkspace.openApplication` back across the thread
/// boundary it is delivered on.
///
/// The completion handler runs on an arbitrary queue. `DispatchGroup.wait()`
/// already orders that write before the read that follows it, but the compiler
/// has no way to see that ordering, so a plain captured `var` is a data race as
/// far as strict concurrency is concerned — and it is indistinguishable from
/// one that genuinely is. The lock makes the guarantee checkable rather than
/// asserted in a comment.
final class LaunchResult: @unchecked Sendable {

    private let lock = NSLock()
    private var error: (any Error)?

    func record(_ error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        self.error = error
    }

    var failure: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}
