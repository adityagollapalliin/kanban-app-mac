import Foundation
import Testing
@testable import LocalBoardCore

/// The 24-hour retention rule is the one privacy guarantee with a moving part,
/// so it is tested against an injected clock rather than the wall clock. No test
/// here sleeps or touches the file system.
@Suite("Diagnostics retention")
struct DiagnosticsPolicyTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let policy = DiagnosticsPolicy()

    private func file(ageHours: Double, bytes: Int64 = 1_024) -> DiagnosticsFile {
        DiagnosticsFile(
            url: URL(fileURLWithPath: "/tmp/localboard-\(ageHours).log"),
            modifiedAt: now.addingTimeInterval(-ageHours * 3_600),
            byteSize: bytes
        )
    }

    @Test("Retention window is exactly 24 hours")
    func retentionIsTwentyFourHours() {
        #expect(policy.retention == 24 * 60 * 60)
        #expect(DiagnosticsPolicy.twentyFourHours == 86_400)
    }

    @Test("A file younger than 24 hours survives")
    func youngFileSurvives() {
        #expect(policy.isExpired(file(ageHours: 23.9), now: now) == false)
    }

    @Test("A file older than 24 hours expires")
    func oldFileExpires() {
        #expect(policy.isExpired(file(ageHours: 24.1), now: now))
    }

    /// The boundary is deliberate: a file aged exactly the retention window is
    /// kept, and expires a moment later. Documented so a future change to `>=`
    /// is a conscious decision rather than an accident.
    @Test("A file aged exactly 24 hours is kept until the next instant")
    func boundaryIsExclusive() {
        let exactly = file(ageHours: 24)
        #expect(policy.isExpired(exactly, now: now) == false)
        #expect(policy.isExpired(exactly, now: now.addingTimeInterval(1)))
    }

    @Test("Expired and surviving files partition the set")
    func partition() {
        let files = [file(ageHours: 1), file(ageHours: 25), file(ageHours: 100), file(ageHours: 12)]
        let expired = policy.expiredFiles(in: files, now: now)
        let surviving = policy.survivingFiles(in: files, now: now)

        #expect(expired.count == 2)
        #expect(surviving.count == 2)
        #expect(Set(expired + surviving) == Set(files))
    }

    @Test("Advancing the clock expires everything eventually")
    func clockAdvanceExpiresAll() {
        let clock = FixedClock(now)
        let files = [file(ageHours: 0), file(ageHours: 6), file(ageHours: 23)]

        #expect(policy.expiredFiles(in: files, now: clock.now).isEmpty)

        clock.advance(by: 25 * 3_600)
        #expect(policy.expiredFiles(in: files, now: clock.now).count == 3)
    }

    @Test("Next expiry is when the youngest survivor ages out")
    func nextExpiry() {
        let files = [file(ageHours: 20), file(ageHours: 2), file(ageHours: 30)]
        let next = policy.nextExpiry(in: files, now: now)
        // The 20-hour-old file expires first, four hours from now.
        #expect(next == now.addingTimeInterval(4 * 3_600))
    }

    @Test("Next expiry is nil when nothing survives")
    func nextExpiryWithNoSurvivors() {
        #expect(policy.nextExpiry(in: [file(ageHours: 99)], now: now) == nil)
        #expect(policy.nextExpiry(in: [], now: now) == nil)
    }

    @Test("Summary reports count, total size and age range")
    func summary() {
        let files = [
            file(ageHours: 1, bytes: 100),
            file(ageHours: 10, bytes: 250),
            file(ageHours: 5, bytes: 650),
        ]
        let summary = policy.summary(of: files)

        #expect(summary.fileCount == 3)
        #expect(summary.totalBytes == 1_000)
        #expect(summary.oldestModifiedAt == now.addingTimeInterval(-10 * 3_600))
        #expect(summary.newestModifiedAt == now.addingTimeInterval(-1 * 3_600))
    }

    @Test("Empty folder summarises to zero, not nil")
    func emptySummary() {
        #expect(policy.summary(of: []) == .empty)
    }

    @Test("A zero retention window expires everything but the present instant")
    func zeroRetention() {
        let eager = DiagnosticsPolicy(retention: 0)
        #expect(eager.isExpired(file(ageHours: 0), now: now) == false)
        #expect(eager.isExpired(file(ageHours: 0.001), now: now))
    }
}
