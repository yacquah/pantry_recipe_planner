import Foundation
import SQLite3

// SQLite needs to know whether the bytes you hand it will still be alive after
// the call returns. SQLITE_TRANSIENT means "copy them, I promise nothing".
// In C it is a cast of -1 to a function pointer, which Swift cannot import,
// so it gets rebuilt by hand. Every Swift/SQLite project rediscovers this line.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A value going into, or coming out of, the database.
///
/// `.null` is a real case rather than an absent value, which is the type
/// system agreeing with modelling rule 3: unknown is a value, not a zero.
public enum SQLValue: Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

/// One row, addressed by column name.
///
/// Every accessor returns an Optional. There is no `string(_:) -> String`
/// that substitutes "" for NULL, because that substitution is exactly how a
/// missing value turns into a plausible wrong answer.
public struct Row: Sendable {
    private let storage: [String: SQLValue]

    init(_ storage: [String: SQLValue]) { self.storage = storage }

    public func string(_ key: String) -> String? {
        if case .text(let value) = storage[key] ?? .null { return value }
        return nil
    }

    public func int(_ key: String) -> Int64? {
        if case .int(let value) = storage[key] ?? .null { return value }
        return nil
    }

    public func double(_ key: String) -> Double? {
        switch storage[key] ?? .null {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }
}

/// A connection to one SQLite file.
public final class Database {
    private var handle: OpaquePointer?

    public enum Failure: Error, CustomStringConvertible {
        case cannotOpen(String)
        case sql(message: String, statement: String)

        public var description: String {
            switch self {
            case .cannotOpen(let path):
                return "cannot open database at \(path)"
            case .sql(let message, let statement):
                return "SQL error: \(message)\n  in: \(statement)"
            }
        }
    }

    public init(path: String) throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            throw Failure.cannotOpen(path)
        }
        // Foreign keys are OFF by default in SQLite, for backwards
        // compatibility with code written before 2009. Every connection has to
        // opt in — otherwise the composite key tying events to lots silently
        // enforces nothing, and the schema's guarantees quietly evaporate.
        try run("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    private func lastError() -> String {
        guard let message = sqlite3_errmsg(handle) else { return "unknown error" }
        return String(cString: message)
    }

    private func prepare(_ sql: String, _ binds: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.sql(message: lastError(), statement: sql)
        }
        for (offset, value) in binds.enumerated() {
            let index = Int32(offset + 1)   // SQLite parameters are 1-based
            switch value {
            case .null:            sqlite3_bind_null(statement, index)
            case .int(let value):  sqlite3_bind_int64(statement, index, value)
            case .double(let val): sqlite3_bind_double(statement, index, val)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            }
        }
        return statement
    }

    /// Runs a statement that returns no rows. Yields the last inserted rowid.
    @discardableResult
    public func run(_ sql: String, _ binds: [SQLValue] = []) throws -> Int64 {
        let statement = try prepare(sql, binds)
        defer { sqlite3_finalize(statement) }

        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw Failure.sql(message: lastError(), statement: sql)
        }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs a script containing MANY statements.
    ///
    /// `run` and `query` go through sqlite3_prepare_v2, which compiles only the
    /// FIRST statement in the string and silently ignores whatever follows. For
    /// a migration file that would mean creating one table and quietly skipping
    /// the rest — a failure that looks like success. sqlite3_exec is the tool
    /// for scripts; it loops over every statement.
    ///
    /// No parameter binding, so never hand this a string built from user input.
    public func executeScript(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError()
            sqlite3_free(errorMessage)          // sqlite3_exec allocates this
            throw Failure.sql(message: message, statement: "<script>")
        }
    }

    public func query(_ sql: String, _ binds: [SQLValue] = []) throws -> [Row] {
        let statement = try prepare(sql, binds)
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw Failure.sql(message: lastError(), statement: sql)
            }

            var values: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard let rawName = sqlite3_column_name(statement, column) else { continue }
                let name = String(cString: rawName)

                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    values[name] = .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT:
                    values[name] = .double(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, column) {
                        values[name] = .text(String(cString: text))
                    } else {
                        values[name] = .null
                    }
                default:
                    values[name] = .null
                }
            }
            rows.append(Row(values))
        }
        return rows
    }

    /// Runs `body` inside a transaction, rolling back if anything throws.
    ///
    /// A capture writes to four tables. Partway through is not a state the
    /// database should ever be observed in — a lot with no capture event has a
    /// quantity of nothing, which is a lie rather than an absence.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN")
        do {
            let result = try body()
            try run("COMMIT")
            return result
        } catch {
            // The rollback itself may fail (a closed connection, say). The
            // original error is the one worth reporting, so this one is
            // deliberately discarded rather than allowed to mask it.
            _ = try? run("ROLLBACK")
            throw error
        }
    }
}
