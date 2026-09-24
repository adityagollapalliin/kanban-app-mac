import Foundation

/// The app never reads the wall clock directly. Everything time-dependent —
/// most importantly the 24-hour diagnostics purge — takes a `ClockProvider`, so
/// tests can move time without sleeping.
public protocol ClockProvider: Sendable {
    var now: Date { get }
}

public struct SystemClock: ClockProvider {
    public init() {}
    public var now: Date { Date() }
}

/// Test clock. Lives here rather than in the test target so both test targets
/// and the debug seeding command can use it.
public final class FixedClock: ClockProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date) { self.current = start }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    public func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = date
    }
}
