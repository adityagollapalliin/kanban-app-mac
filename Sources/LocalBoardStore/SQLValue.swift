import Foundation

/// A value as SQLite stores it. Everything bound into a statement goes through
/// this type — the app never interpolates a value into SQL text, so there is no
/// injection surface, including in the query language compiler.
public enum SQLValue: Sendable, Equatable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLValueConvertible {
    var sqlValue: SQLValue { get }
}

extension SQLValue: SQLValueConvertible {
    public var sqlValue: SQLValue { self }
}

extension String: SQLValueConvertible {
    public var sqlValue: SQLValue { .text(self) }
}

extension Int: SQLValueConvertible {
    public var sqlValue: SQLValue { .integer(Int64(self)) }
}

extension Int64: SQLValueConvertible {
    public var sqlValue: SQLValue { .integer(self) }
}

extension Double: SQLValueConvertible {
    public var sqlValue: SQLValue { .real(self) }
}

extension Bool: SQLValueConvertible {
    public var sqlValue: SQLValue { .integer(self ? 1 : 0) }
}

extension Data: SQLValueConvertible {
    public var sqlValue: SQLValue { .blob(self) }
}

extension UUID: SQLValueConvertible {
    public var sqlValue: SQLValue { .text(uuidString) }
}

/// Dates are stored as Unix epoch seconds in a REAL column: sortable and
/// comparable in SQL, which the query language relies on for `due < +7d`.
extension Date: SQLValueConvertible {
    public var sqlValue: SQLValue { .real(timeIntervalSince1970) }
}

extension Optional where Wrapped: SQLValueConvertible {
    public var sqlValue: SQLValue {
        switch self {
        case .none: return .null
        case .some(let wrapped): return wrapped.sqlValue
        }
    }
}
