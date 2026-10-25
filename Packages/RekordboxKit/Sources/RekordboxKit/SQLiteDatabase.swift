import Foundation
import SQLCipher

/// A minimal wrapper around an (optionally SQLCipher-encrypted) SQLite database.
final class SQLiteDatabase {
    struct Error: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var handle: OpaquePointer?

    /// A value in any of SQLite's storage classes, so rows can be recorded and restored exactly.
    enum Value: Hashable, Sendable {
        case text(String)
        case int(Int)
        case real(Double)
        case blob(Data)
        case null
    }

    enum Access {
        case readOnly, readWrite
        /// Read-write, creating the file if it doesn't exist.
        case create
    }

    init(url: URL, key: String? = nil, access: Access = .readOnly) throws {
        let flags = switch access {
        case .readOnly: SQLITE_OPEN_READONLY
        case .readWrite: SQLITE_OPEN_READWRITE
        case .create: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
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
            case .real(let real): sqlite3_bind_double(statement, position, real)
            case .blob(let data) where data.isEmpty:
                // An empty Data has no bytes to point at, and binding a nil pointer would store NULL.
                sqlite3_bind_zeroblob(statement, position, 0)
            case .blob(let data): data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) }
            case .null: sqlite3_bind_null(statement, position)
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

        func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, column) == SQLITE_NULL
        }

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(statement, column))
        }

        /// The column's value, in whichever storage class it has.
        func value(_ column: Int32) -> Value {
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER: .int(int(column))
            case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
            case SQLITE_TEXT: .text(string(column) ?? "")
            case SQLITE_BLOB:
                // SQLite returns a nil pointer for an empty blob.
                if let bytes = sqlite3_column_blob(statement, column) {
                    .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))))
                } else {
                    .blob(Data())
                }
            default: .null
            }
        }

        /// Every column, by name.
        func values() -> [String: Value] {
            Dictionary(uniqueKeysWithValues: (0..<sqlite3_column_count(statement)).map { column in
                (String(cString: sqlite3_column_name(statement, column)), value(column))
            })
        }
    }
}
