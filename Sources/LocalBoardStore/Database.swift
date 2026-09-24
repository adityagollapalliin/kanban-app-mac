import Foundation
import SQLite3
import LocalBoardCore

/// A connection to the board database.
///
/// Concurrency model: one connection, guarded by a recursive lock. Every public
/// method takes the lock, so nested calls (a `transaction` that runs queries)
/// do not deadlock. SQLite itself is opened `FULLMUTEX` as a second belt.
///
/// Cross-process model: WAL journalling plus a five-second busy timeout, so the
/// sandboxed app and the `localboard` CLI can hold the file open at the same
/// time. Writers take `BEGIN IMMEDIATE` to fail fast rather than deadlock
/// mid-transaction.
public final class Database: @unchecked Sendable {

    public enum Location: Sendable, Equatable {
        case file(URL)
        /// Private in-memory database. Used by tests.
        case memory
    }

    private let handle: OpaquePointer
    private let lock = NSRecursiveLock()
    private var statementCache: [String: Statement] = [:]
    private var transactionDepth = 0
    private var isOpen = true

    public let location: Location

    // MARK: - Opening

    public init(location: Location) throws {
        self.location = location

        let path: String
        switch location {
        case .file(let url): path = url.path
        case .memory: path = ":memory:"
        }

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &connection, flags, nil)

        guard status == SQLITE_OK, let opened = connection else {
            let detail: String
            if let connection {
                detail = Statement.errorMessage(connection)
            } else {
                detail = "SQLite returned status \(status)."
            }
            sqlite3_close_v2(connection)
            throw LocalBoardError.databaseOpenFailed(path: path, detail: detail)
        }

        self.handle = opened
        try configureConnection()
    }

    /// Opens the board database in the app's container, creating the directory
    /// tree and running any pending migrations.
    public static func openBoardDatabase(
        paths: ContainerPaths,
        migrations: [Migration] = Migration.all,
        fileManager: FileManager = .default
    ) throws -> Database {
        try paths.createDirectoriesIfNeeded(fileManager: fileManager)
        let database = try Database(location: .file(paths.databaseFile))
        try database.migrate(using: migrations)
        return database
    }

    private func configureConnection() throws {
        // Fail fast rather than crash if another process holds the write lock.
        sqlite3_busy_timeout(handle, 5_000)

        try executeRaw("PRAGMA foreign_keys = ON;")
        try executeRaw("PRAGMA synchronous = NORMAL;")
        try executeRaw("PRAGMA temp_store = MEMORY;")

        if case .file = location {
            // WAL is what makes the CLI and the app safe to run at the same time.
            let mode = try queryRaw("PRAGMA journal_mode = WAL;").first?.string("journal_mode")
            if mode?.lowercased() != "wal" {
                Log.store.warning("Database did not enter WAL mode; falling back to the default journal.")
            }
        }
    }

    deinit {
        statementCache.removeAll()
        sqlite3_close_v2(handle)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return }
        statementCache.removeAll()
        sqlite3_close_v2(handle)
        isOpen = false
    }

    // MARK: - Executing

    /// Runs one or more statements with no parameters and no results.
    public func executeRaw(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        defer { sqlite3_free(errorPointer) }

        guard status == SQLITE_OK else {
            let detail = errorPointer.map { String(cString: $0) } ?? Statement.errorMessage(handle)
            throw LocalBoardError.databaseQueryFailed(detail: detail)
        }
    }

    private func queryRaw(_ sql: String) throws -> [Row] {
        try query(sql, [])
    }

    /// Runs a parameterised statement that returns no rows.
    @discardableResult
    public func execute(_ sql: String, _ parameters: [SQLValueConvertible] = []) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        let statement = try cachedStatement(for: sql)
        defer { statement.reset() }
        try statement.bind(parameters.map(\.sqlValue))
        while try statement.step() != nil {}
        return Int(sqlite3_changes(handle))
    }

    /// Runs a parameterised query and materialises the rows.
    public func query(_ sql: String, _ parameters: [SQLValueConvertible] = []) throws -> [Row] {
        lock.lock()
        defer { lock.unlock() }

        let statement = try cachedStatement(for: sql)
        defer { statement.reset() }
        try statement.bind(parameters.map(\.sqlValue))

        var rows: [Row] = []
        while let row = try statement.step() {
            rows.append(row)
        }
        return rows
    }

    /// Streams rows to a handler without building an array — used by the board
    /// views so a 1,000-task fetch never materialises twice.
    public func forEachRow(
        _ sql: String,
        _ parameters: [SQLValueConvertible] = [],
        handler: (Row) throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let statement = try cachedStatement(for: sql)
        defer { statement.reset() }
        try statement.bind(parameters.map(\.sqlValue))
        while let row = try statement.step() {
            try handler(row)
        }
    }

    public func queryOne(_ sql: String, _ parameters: [SQLValueConvertible] = []) throws -> Row? {
        try query(sql, parameters).first
    }

    public func count(_ sql: String, _ parameters: [SQLValueConvertible] = []) throws -> Int {
        guard let row = try queryOne(sql, parameters) else { return 0 }
        return Int(row[0].integerValue ?? 0)
    }

    private func cachedStatement(for sql: String) throws -> Statement {
        if let cached = statementCache[sql] { return cached }
        let statement = try Statement(connection: handle, sql: sql)
        // Bounded so a pathological number of distinct queries cannot grow the
        // cache without limit; board work reuses a small set of statements.
        if statementCache.count >= 128 {
            statementCache.removeAll(keepingCapacity: true)
        }
        statementCache[sql] = statement
        return statement
    }

    // MARK: - Transactions

    /// Runs `body` inside a write transaction. Nested calls become savepoints,
    /// so a command built from smaller commands still commits atomically.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        let depth = transactionDepth
        let savepointName = "localboard_sp_\(depth)"

        if depth == 0 {
            try executeRaw("BEGIN IMMEDIATE;")
        } else {
            try executeRaw("SAVEPOINT \(savepointName);")
        }
        transactionDepth += 1

        do {
            let result = try body()
            transactionDepth -= 1
            if transactionDepth == 0 {
                try executeRaw("COMMIT;")
            } else {
                try executeRaw("RELEASE \(savepointName);")
            }
            return result
        } catch {
            transactionDepth -= 1
            if transactionDepth == 0 {
                try? executeRaw("ROLLBACK;")
            } else {
                try? executeRaw("ROLLBACK TO \(savepointName);")
                try? executeRaw("RELEASE \(savepointName);")
            }
            throw error
        }
    }

    // MARK: - Metadata

    public var userVersion: Int {
        get throws {
            guard let row = try queryOne("PRAGMA user_version;"),
                  let version = row[0].integerValue else { return 0 }
            return Int(version)
        }
    }

    func setUserVersion(_ version: Int) throws {
        // PRAGMA does not accept bound parameters; `version` is an Int we
        // produced ourselves from the migration list, never user input.
        try executeRaw("PRAGMA user_version = \(version);")
    }

    /// Increments whenever *any* connection — including the CLI in another
    /// process — commits. The app samples this on window activation instead of
    /// polling, which is what keeps idle CPU at zero.
    public var dataVersion: Int64 {
        get throws {
            guard let row = try queryOne("PRAGMA data_version;"),
                  let version = row[0].integerValue else { return 0 }
            return version
        }
    }

    public var lastInsertRowID: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Reclaims space and refreshes query-planner statistics. Called from
    /// Settings, never automatically, so it cannot surprise the energy budget.
    public func compact() throws {
        try executeRaw("PRAGMA optimize;")
        try executeRaw("VACUUM;")
    }
}

extension SQLValue {
    var integerValue: Int64? {
        switch self {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        default: return nil
        }
    }
}
