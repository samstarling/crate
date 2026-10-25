import Foundation
import SQLCipher

/// A minimal wrapper around an (optionally SQLCipher-encrypted) SQLite database.
nonisolated final class SQLiteDatabase {
    struct Error: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var handle: OpaquePointer?

    enum Value {
        case text(String)
        case int(Int)
    }

    init(url: URL, key: String? = nil, readOnly: Bool = true) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(handle)
            throw Error(message: "Couldn't open \(url.lastPathComponent): \(message)")
        }
        if let key {
            try execute("PRAGMA key = '\(key)'")
        }
        // Touch the schema so a wrong key fails here rather than on the first real query.
        try query("SELECT count(*) FROM sqlite_master") { _ in }
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    /// Runs a single statement with `?` placeholders bound to `values`.
    func execute(_ sql: String, _ values: [Value]) throws {
        try query(sql, values) { _ in }
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func query(_ sql: String, _ values: [Value] = [], row: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result = switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case .int(let int): sqlite3_bind_int64(statement, position, Int64(int))
            }
            guard result == SQLITE_OK else { throw lastError() }
        }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw lastError()
            }
        }
    }

    /// Tells SQLite to copy bound strings, since Swift's temporary C strings don't outlive the call.
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func lastError() -> Error {
        Error(message: String(cString: sqlite3_errmsg(handle)))
    }

    struct Row {
        fileprivate let statement: OpaquePointer?

        func string(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(statement, column))
        }
    }
}
