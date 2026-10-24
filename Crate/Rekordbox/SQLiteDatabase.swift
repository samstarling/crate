import Foundation
import SQLCipher

/// A minimal read-only wrapper around an (optionally SQLCipher-encrypted) SQLite database.
nonisolated final class SQLiteDatabase {
    struct Error: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var handle: OpaquePointer?

    init(url: URL, key: String? = nil) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
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

    func query(_ sql: String, row: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw lastError()
            }
        }
    }

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
