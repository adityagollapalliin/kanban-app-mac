import Foundation
import LocalBoardCore
import LocalBoardStore

/// A migrated in-memory database, built through the public API — this target
/// cannot see the store tests' own helpers.
func makeDatabase() throws -> Database {
    let database = try Database(location: .memory)
    try database.migrate()
    return database
}

let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
