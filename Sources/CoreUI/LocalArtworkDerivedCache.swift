#if canImport(UIKit)
import Foundation
import ImageIO
import SQLite3
import UIKit

/// A bounded, best-effort cache of right-sized derivatives of direct-share
/// artwork. It never stores source bytes or source locations.
public actor LocalArtworkDerivedCache {
    public static let hardByteCap = 64 * 1024 * 1024
    public static let memoryWarningByteCap = 48 * 1024 * 1024
    public static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    private let directory: URL
    private let databaseURL: URL
    /// User-adjustable byte budget (Step 6). A `var` so `setByteCap(_:)` can change
    /// it at runtime and trim immediately; `store` continues to trim to it after
    /// each write.
    private var byteCap: Int
    private let warningByteCap: Int
    private let maximumEntryAge: TimeInterval
    private let now: @Sendable () -> Date
    private var db: OpaquePointer?
    private var preferredAccounts = Set<String>()
    private var preferenceRevision: UInt64 = 0

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("plozz-local-artwork-derived", isDirectory: true)
        self.directory = base
        self.databaseURL = base.appendingPathComponent("manifest.sqlite", isDirectory: false)
        self.byteCap = Self.hardByteCap
        self.warningByteCap = Self.memoryWarningByteCap
        self.maximumEntryAge = Self.maximumAge
        self.now = Date.init
    }

    init(
        directory: URL,
        byteCap: Int,
        warningByteCap: Int,
        maximumAge: TimeInterval,
        now: @escaping @Sendable () -> Date
    ) {
        self.directory = directory
        self.databaseURL = directory.appendingPathComponent("manifest.sqlite", isDirectory: false)
        self.byteCap = byteCap
        self.warningByteCap = warningByteCap
        self.maximumEntryAge = maximumAge
        self.now = now
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// A stale profile update cannot reverse a newer eviction preference.
    public func setPreferredAccounts(_ accounts: Set<String>, revision: UInt64) {
        guard revision >= preferenceRevision else { return }
        preferenceRevision = revision
        preferredAccounts = accounts
    }

    func preferredAccountsForTesting() -> Set<String> {
        preferredAccounts
    }

    public func data(
        for key: String,
        accountID: String,
        credentialRevision: String,
        sourceFingerprint: String,
        markUsed: Bool = true
    ) -> Data? {
        guard open(), let entry = entry(for: key),
              entry.accountID == accountID,
              entry.credentialRevision == credentialRevision,
              entry.sourceFingerprint == sourceFingerprint
        else { return nil }
        let url = directory.appendingPathComponent(entry.filename, isDirectory: false)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            delete(key: key)
            return nil
        }
        if markUsed { touch(key: key) }
        return data
    }

    public func store(
        _ image: UIImage,
        key: String,
        accountID: String,
        credentialRevision: String,
        sourceFingerprint: String,
        variant: ArtworkImageVariant
    ) {
        guard open(), let encoded = Self.encode(image: image, variant: variant) else { return }
        let filename = Self.digest(key) + (Self.hasAlpha(image) ? ".png" : ".jpg")
        let target = directory.appendingPathComponent(filename, isDirectory: false)
        let temporary = directory.appendingPathComponent("." + filename + ".writing", isDirectory: false)
        do {
            try encoded.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return
        }
        upsert(
            Entry(
                key: key,
                filename: filename,
                byteCount: encoded.count,
                lastUse: now().timeIntervalSince1970,
                accountID: accountID,
                credentialRevision: credentialRevision,
                sourceFingerprint: sourceFingerprint,
                variant: variant.rawValue
            )
        )
        trim(to: byteCap)
    }

    public func purge(accountID: String) {
        guard open() else { return }
        purge(where: "account_id=?", bind: { sqlite3_bind_text($0, 1, accountID, -1, SQLITE_TRANSIENT) })
    }

    public func purge(accountID: String, credentialRevision: String) {
        guard open() else { return }
        purge(where: "account_id=? AND credential_revision=?", bind: {
            sqlite3_bind_text($0, 1, accountID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text($0, 2, credentialRevision, -1, SQLITE_TRANSIENT)
        })
    }

    public func trimForMemoryWarning() {
        guard open() else { return }
        trim(to: warningByteCap)
    }

    public func usageBytes() -> Int {
        guard open() else { return 0 }
        return Int(queryInt64("SELECT COALESCE(SUM(byte_count), 0) FROM entries;"))
    }

    /// Current cache size in bytes (Step 6 diagnostics). Alias of ``usageBytes()``
    /// under the naming the diagnostics aggregator uses across both caches.
    public func currentByteSize() -> Int { usageBytes() }

    /// Applies a new user-chosen byte budget and immediately trims down to it
    /// (oldest / inactive-account entries first — idempotent). Subsequent `store`
    /// calls also trim to this value.
    public func setByteCap(_ bytes: Int) {
        byteCap = max(0, bytes)
        guard open() else { return }
        trim(to: byteCap)
    }

    /// Removes every cached derivative and its file (Step 6 "Clear cache now").
    /// Distinct from a budget change: it drops all data regardless of size.
    public func clear() {
        guard open() else { return }
        for entry in entries(ordering: "last_use ASC") { delete(key: entry.key) }
    }

    public func trim(to byteCap: Int) {
        guard open() else { return }
        let expired = now().addingTimeInterval(-maximumEntryAge).timeIntervalSince1970
        delete(where: "last_use < ?", bind: { sqlite3_bind_double($0, 1, expired) })
        var total = usageBytes()
        guard total > byteCap else { return }
        // Inactive accounts lose equal-age entries before active accounts. The
        // account identifier exists only in SQLite; filenames remain opaque.
        let inactive = entries(ordering: "CASE WHEN account_id IN (\(preferredPlaceholders)) THEN 1 ELSE 0 END, last_use ASC")
        for entry in inactive where total > byteCap {
            delete(key: entry.key)
            total -= entry.byteCount
        }
    }

    private var preferredPlaceholders: String {
        preferredAccounts.isEmpty ? "''" : preferredAccounts.map { _ in "?" }.joined(separator: ",")
    }

    private struct Entry {
        let key: String
        let filename: String
        let byteCount: Int
        let lastUse: TimeInterval
        let accountID: String
        let credentialRevision: String
        let sourceFingerprint: String
        let variant: String
    }

    private func open() -> Bool {
        if db != nil { return true }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return false }
        guard openManifest() || recreateManifest() else { return false }
        repairOrphans()
        return true
    }

    private func openManifest() -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        guard sqlite3_exec(handle, """
        CREATE TABLE IF NOT EXISTS entries(
          cache_key TEXT PRIMARY KEY,
          filename TEXT NOT NULL,
          byte_count INTEGER NOT NULL,
          last_use REAL NOT NULL,
          account_id TEXT NOT NULL,
          credential_revision TEXT NOT NULL,
          source_fingerprint TEXT NOT NULL,
          variant TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS entries_lru ON entries(last_use);
        """, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        db = handle
        return true
    }

    private func recreateManifest() -> Bool {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: databaseURL.path + suffix)
            )
        }
        return openManifest()
    }

    private func entry(for key: String) -> Entry? {
        var result: Entry?
        query("SELECT cache_key,filename,byte_count,last_use,account_id,credential_revision,source_fingerprint,variant FROM entries WHERE cache_key=?;", bind: {
            sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT)
        }) { statement in
            result = Self.entry(statement)
        }
        return result
    }

    private func entries(ordering: String) -> [Entry] {
        var values: [Entry] = []
        // Bind account IDs instead of interpolating them into SQL.
        query("SELECT cache_key,filename,byte_count,last_use,account_id,credential_revision,source_fingerprint,variant FROM entries ORDER BY \(ordering);", bind: {
            for (index, account) in preferredAccounts.sorted().enumerated() {
                sqlite3_bind_text($0, Int32(index + 1), account, -1, SQLITE_TRANSIENT)
            }
        }) { values.append(Self.entry($0)) }
        return values
    }

    private func upsert(_ entry: Entry) {
        execute("""
        INSERT OR REPLACE INTO entries(cache_key,filename,byte_count,last_use,account_id,credential_revision,source_fingerprint,variant)
        VALUES(?,?,?,?,?,?,?,?);
        """) {
            sqlite3_bind_text($0, 1, entry.key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text($0, 2, entry.filename, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64($0, 3, Int64(entry.byteCount))
            sqlite3_bind_double($0, 4, entry.lastUse)
            sqlite3_bind_text($0, 5, entry.accountID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text($0, 6, entry.credentialRevision, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text($0, 7, entry.sourceFingerprint, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text($0, 8, entry.variant, -1, SQLITE_TRANSIENT)
        }
    }

    private func touch(key: String) {
        execute("UPDATE entries SET last_use=? WHERE cache_key=?;") {
            sqlite3_bind_double($0, 1, now().timeIntervalSince1970)
            sqlite3_bind_text($0, 2, key, -1, SQLITE_TRANSIENT)
        }
    }

    private func delete(key: String) {
        guard let entry = entry(for: key) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.filename, isDirectory: false))
        execute("DELETE FROM entries WHERE cache_key=?;") {
            sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT)
        }
    }

    private func purge(where clause: String, bind: (OpaquePointer?) -> Void) {
        var keys: [String] = []
        query("SELECT cache_key FROM entries WHERE \(clause);", bind: bind) {
            if let value = sqlite3_column_text($0, 0) { keys.append(String(cString: value)) }
        }
        keys.forEach(delete)
    }

    private func delete(where clause: String, bind: (OpaquePointer?) -> Void) {
        var keys: [String] = []
        query("SELECT cache_key FROM entries WHERE \(clause);", bind: bind) {
            if let value = sqlite3_column_text($0, 0) { keys.append(String(cString: value)) }
        }
        keys.forEach(delete)
    }

    private func repairOrphans() {
        let known = Set(entries(ordering: "last_use ASC").map(\.filename))
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent != databaseURL.lastPathComponent && !known.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func queryInt64(_ sql: String) -> Int64 {
        var value: Int64 = 0
        query(sql, bind: { _ in }) { value = sqlite3_column_int64($0, 0) }
        return value
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void, row: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private func execute(_ sql: String, bind: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        _ = sqlite3_step(statement)
    }

    private static func entry(_ statement: OpaquePointer?) -> Entry {
        Entry(
            key: String(cString: sqlite3_column_text(statement, 0)),
            filename: String(cString: sqlite3_column_text(statement, 1)),
            byteCount: Int(sqlite3_column_int64(statement, 2)),
            lastUse: sqlite3_column_double(statement, 3),
            accountID: String(cString: sqlite3_column_text(statement, 4)),
            credentialRevision: String(cString: sqlite3_column_text(statement, 5)),
            sourceFingerprint: String(cString: sqlite3_column_text(statement, 6)),
            variant: String(cString: sqlite3_column_text(statement, 7))
        )
    }

    private static func hasAlpha(_ image: UIImage) -> Bool {
        guard let alpha = image.cgImage?.alphaInfo else { return false }
        return alpha == .first || alpha == .last || alpha == .premultipliedFirst || alpha == .premultipliedLast
    }

    private static func encode(image: UIImage, variant: ArtworkImageVariant) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        let type = hasAlpha(image) ? "public.png" as CFString : "public.jpeg" as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let options: [CFString: Any] = type == "public.jpeg" as CFString
            ? [kCGImageDestinationLossyCompressionQuality: 0.92]
            : [:]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A deterministic opaque filename component. It intentionally has no reversible
    /// path or endpoint data and is only used inside the private cache directory.
    private static func digest(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif
