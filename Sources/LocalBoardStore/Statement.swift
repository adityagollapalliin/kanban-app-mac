import Foundation
import SQLite3
import LocalBoardCore

/// `SQLITE_TRANSIENT` is a macro in C and therefore invisible to Swift. It tells
/// SQLite to copy the bound bytes, which is what we want for every bind here.
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One row of a result set, addressable by index or column name.
public struct Row: Sendable {
    private let values: [SQLValue]
    private let indexByName: [String: Int]

    init(values: [SQLValue], indexByName: [String: Int]) {
        self.values = values
        self.indexByName = indexByName
    }

    public subscript(index: Int) -> SQLValue {
        guard values.indices.contains(index) else { return .null }
        return values[index]
    }

    public subscript(name: String) -> SQLValue {
        guard let index = indexByName[name] else { return .null }
        return self[index]
    }

    public func string(_ name: String) -> String? {
        if case .text(let value) = self[name] { return value }
        return nil
    }

    public func int(_ name: String) -> Int64? {
        switch self[name] {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        default: return nil
        }
    }

    public func double(_ name: String) -> Double? {
        switch self[name] {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    public func bool(_ name: String) -> Bool? {
        guard let value = int(name) else { return nil }
        return value != 0
    }

    public func date(_ name: String) -> Date? {
        guard let seconds = double(name) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func uuid(_ name: String) -> UUID? {
        guard let text = string(name) else { return nil }
        return UUID(uuidString: text)
    }

    public func data(_ name: String) -> Data? {
        if case .blob(let value) = self[name] { return value }
        return nil
    }
}

/// A prepared statement. Not `Sendable` by design: it is only ever used inside
/// `Database`'s lock, which is what serialises access to the connection.
final class Statement {
    private let handle: OpaquePointer
    private let connection: OpaquePointer
    private(set) lazy var columnNames: [String] = {
        (0..<Int(sqlite3_column_count(handle))).map { index in
            guard let name = sqlite3_column_name(handle, Int32(index)) else { return "" }
            return String(cString: name)
        }
    }()

    init(connection: OpaquePointer, sql: String) throws {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let prepared = statement else {
            let message = Statement.errorMessage(connection)
            sqlite3_finalize(statement)
            throw LocalBoardError.databaseQueryFailed(
                detail: "Preparing statement failed (\(status)): \(message)"
            )
        }
        self.handle = prepared
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(handle)
    }

    static func errorMessage(_ connection: OpaquePointer) -> String {
        guard let message = sqlite3_errmsg(connection) else { return "unknown SQLite error" }
        return String(cString: message)
    }

    func bind(_ parameters: [SQLValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)

        let expected = Int(sqlite3_bind_parameter_count(handle))
        guard parameters.count == expected else {
            throw LocalBoardError.databaseQueryFailed(
                detail: "Statement expects \(expected) parameter(s) but \(parameters.count) were supplied."
            )
        }

        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(handle, index)
            case .integer(let number):
                status = sqlite3_bind_int64(handle, index, number)
            case .real(let number):
                status = sqlite3_bind_double(handle, index, number)
            case .text(let string):
                status = sqlite3_bind_text(handle, index, string, -1, sqliteTransient)
            case .blob(let bytes):
                status = bytes.withUnsafeBytes { buffer in
                    if let base = buffer.baseAddress, buffer.count > 0 {
                        return sqlite3_bind_blob(handle, index, base, Int32(buffer.count), sqliteTransient)
                    }
                    return sqlite3_bind_zeroblob(handle, index, 0)
                }
            }
            guard status == SQLITE_OK else {
                throw LocalBoardError.databaseQueryFailed(
                    detail: "Binding parameter \(index) failed: \(Statement.errorMessage(connection))"
                )
            }
        }
    }

    /// Advances one row. Returns `nil` when the statement is done.
    func step() throws -> Row? {
        let status = sqlite3_step(handle)
        switch status {
        case SQLITE_ROW:
            return currentRow()
        case SQLITE_DONE:
            return nil
        default:
            throw LocalBoardError.databaseQueryFailed(
                detail: "Executing statement failed (\(status)): \(Statement.errorMessage(connection))"
            )
        }
    }

    private func currentRow() -> Row {
        let names = columnNames
        var values: [SQLValue] = []
        values.reserveCapacity(names.count)

        for index in 0..<names.count {
            let column = Int32(index)
            switch sqlite3_column_type(handle, column) {
            case SQLITE_INTEGER:
                values.append(.integer(sqlite3_column_int64(handle, column)))
            case SQLITE_FLOAT:
                values.append(.real(sqlite3_column_double(handle, column)))
            case SQLITE_TEXT:
                if let text = sqlite3_column_text(handle, column) {
                    values.append(.text(String(cString: text)))
                } else {
                    values.append(.null)
                }
            case SQLITE_BLOB:
                let byteCount = Int(sqlite3_column_bytes(handle, column))
                if byteCount > 0, let bytes = sqlite3_column_blob(handle, column) {
                    values.append(.blob(Data(bytes: bytes, count: byteCount)))
                } else {
                    values.append(.blob(Data()))
                }
            default:
                values.append(.null)
            }
        }

        var indexByName: [String: Int] = [:]
        indexByName.reserveCapacity(names.count)
        for (index, name) in names.enumerated() where indexByName[name] == nil {
            indexByName[name] = index
        }
        return Row(values: values, indexByName: indexByName)
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }
}
