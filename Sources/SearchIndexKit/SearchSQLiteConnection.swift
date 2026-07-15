import Foundation
import SQLite3

public enum SearchIndexSQLiteFailure: Error, Equatable, Sendable {
    case busy(String)
    case locked(String)
    case constraint(String)
    case corrupt(String)
    case notDatabase(String)
    case io(String)
    case other(code: Int32, message: String)

    var isCorruption: Bool {
        switch self {
        case .corrupt, .notDatabase: true
        default: false
        }
    }
}

final class SearchSQLiteConnection: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? url.lastPathComponent
            if let opened { sqlite3_close(opened) }
            throw SearchIndexStoreError.sqlite(Self.failure(code: result, message: message))
        }
        handle = opened
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func close() {
        guard let handle else { return }
        sqlite3_close(handle)
        self.handle = nil
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    func execute(
        _ sql: String,
        bind: (OpaquePointer?) -> Void = { _ in }
    ) throws -> Int {
        guard let handle else {
            throw SearchIndexStoreError.sqlite(.other(
                code: SQLITE_MISUSE,
                message: "database unavailable"
            ))
        }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK else { throw error(code: prepare) }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else { throw error(code: step) }
        return Int(sqlite3_changes(handle))
    }

    func query(
        _ sql: String,
        bind: (OpaquePointer?) -> Void = { _ in },
        row: (OpaquePointer?) throws -> Void
    ) throws {
        guard let handle else {
            throw SearchIndexStoreError.sqlite(.other(
                code: SQLITE_MISUSE,
                message: "database unavailable"
            ))
        }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK else { throw error(code: prepare) }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while true {
            let step = sqlite3_step(statement)
            switch step {
            case SQLITE_ROW:
                try row(statement)
            case SQLITE_DONE:
                return
            default:
                throw error(code: step)
            }
        }
    }

    func exec(_ sql: String) throws {
        guard let handle else {
            throw SearchIndexStoreError.sqlite(.other(
                code: SQLITE_MISUSE,
                message: "database unavailable"
            ))
        }
        var messagePointer: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(handle, sql, nil, nil, &messagePointer)
        guard result == SQLITE_OK else {
            let message = messagePointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(messagePointer)
            throw SearchIndexStoreError.sqlite(Self.failure(code: result, message: message))
        }
    }

    func scalarInt(_ sql: String) throws -> Int {
        var value = 0
        try query(sql) { statement in
            value = Int(sqlite3_column_int64(statement, 0))
        }
        return value
    }

    func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    func bindOptionalText(
        _ value: String?,
        to statement: OpaquePointer?,
        index: Int32
    ) {
        if let value {
            bindText(value, to: statement, index: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bindBlob(_ value: Data, to statement: OpaquePointer?, index: Int32) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                Self.transient
            )
        }
    }

    func bindOptionalBlob(
        _ value: Data?,
        to statement: OpaquePointer?,
        index: Int32
    ) {
        if let value {
            bindBlob(value, to: statement, index: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bindOptionalDate(
        _ value: Date?,
        to statement: OpaquePointer?,
        index: Int32
    ) {
        if let value {
            sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    func columnBlob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    private func error(code: Int32) -> SearchIndexStoreError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) }
            ?? "database unavailable"
        return .sqlite(Self.failure(code: code, message: message))
    }

    static func failure(code: Int32, message: String) -> SearchIndexSQLiteFailure {
        switch code & 0xFF {
        case SQLITE_BUSY: .busy(message)
        case SQLITE_LOCKED: .locked(message)
        case SQLITE_CONSTRAINT: .constraint(message)
        case SQLITE_CORRUPT: .corrupt(message)
        case SQLITE_NOTADB: .notDatabase(message)
        case SQLITE_IOERR, SQLITE_FULL, SQLITE_CANTOPEN: .io(message)
        default: .other(code: code, message: message)
        }
    }
}
