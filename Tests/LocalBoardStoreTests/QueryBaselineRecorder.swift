import Foundation
import Testing
@testable import LocalBoardStore

/// Writes `Fixtures/query-baseline.json` from the parser as it stands.
///
/// Disabled, because recording the baseline is the one thing this suite must
/// never do by accident: a run that quietly re-recorded it would turn every
/// compatibility failure into a pass. It is run deliberately, by hand, and
/// only when a change to the language has been approved:
///
/// ```sh
/// RECORD_QUERY_BASELINE=1 swift test --filter "Record the query baseline"
/// ```
///
/// The resulting diff is the record of exactly what changed meaning.
@Suite(.enabled(
    if: ProcessInfo.processInfo.environment["RECORD_QUERY_BASELINE"] != nil,
    "Set RECORD_QUERY_BASELINE=1 to re-record; never let an ordinary run do it"
))
struct QueryBaselineRecorder {

    @Test("Record the query baseline")
    func record() throws {
        var records: [QueryCompatibilityTests.Record] = []
        var seen = Set<String>()

        for entry in QueryCorpus.all where seen.insert(entry.query).inserted {
            records.append(try QueryCompatibilityTests.record(entry))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)

        try FileManager.default.createDirectory(
            at: QueryCompatibilityTests.baselineURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: QueryCompatibilityTests.baselineURL)

        let rejected = records.filter(\.rejected).count
        print("""
            Recorded \(records.count) queries to \(QueryCompatibilityTests.baselineURL.path)
              compiles: \(records.count - rejected)
              rejected: \(rejected)
            """)
    }
}
