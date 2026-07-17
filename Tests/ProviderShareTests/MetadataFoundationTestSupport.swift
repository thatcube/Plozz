import CoreModels
import Foundation
import MediaTransportCore
import SQLite3
@testable import ProviderShare

final class MetadataAsyncTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var opened = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        let waiters = lock.withLock {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !opened else { return true }
                openWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !entered else { return true }
                entryWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func open() {
        let waiters = lock.withLock {
            opened = true
            let waiters = openWaiters
            openWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }
}

actor MetadataDependencyRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

actor MetadataResolverSpy: ShareMetadataResolving {
    private(set) var requests: [ShareEnrichRequest] = []
    private(set) var cancellationCrossings = 0
    private let response: ShareCatalogStore.EnrichmentRecord
    private let gate: MetadataAsyncTestGate?

    init(
        response: ShareCatalogStore.EnrichmentRecord = .init(),
        gate: MetadataAsyncTestGate? = nil
    ) {
        self.response = response
        self.gate = gate
    }

    func resolve(_ request: ShareEnrichRequest) async -> ShareCatalogStore.EnrichmentRecord {
        requests.append(request)
        if let gate { await gate.wait() }
        if Task.isCancelled { cancellationCrossings += 1 }
        return response
    }
}

final class MetadataResolverFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private let resolver: any ShareMetadataResolving
    private var makeCountStorage = 0
    private var identitiesStorage: [ObjectIdentifier] = []

    init(resolver: any ShareMetadataResolving) {
        self.resolver = resolver
    }

    var makeCount: Int { lock.withLock { makeCountStorage } }
    var identities: [ObjectIdentifier] { lock.withLock { identitiesStorage } }

    func make() -> any ShareMetadataResolving {
        lock.withLock {
            makeCountStorage += 1
            identitiesStorage.append(ObjectIdentifier(resolver as AnyObject))
        }
        return resolver
    }
}

final class MetadataFileSystemSpy: MediaTransportFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var readCountStorage = 0
    private var cancellationCrossingsStorage = 0
    let readGate: MetadataAsyncTestGate?

    init(files: [String: Data] = [:], readGate: MetadataAsyncTestGate? = nil) {
        self.files = files
        self.readGate = readGate
    }

    var readCount: Int { lock.withLock { readCountStorage } }
    var cancellationCrossings: Int { lock.withLock { cancellationCrossingsStorage } }

    func setFile(_ data: Data?, at path: String) {
        lock.withLock { files[path] = data }
    }

    func validate() async throws {}

    func probe() async throws -> MediaTransportProbe {
        MediaTransportProbe(
            capabilities: try MediaTransportCapabilities(
                supportsList: true,
                supportsStat: true,
                supportsBoundedWholeFileRead: true,
                byteRangeBehavior: .randomAccess,
                maximumBoundedWholeFileReadBytes: ShareNFOParser.maxBytes,
                consistency: .changeDetecting
            )
        )
    }

    func list(relativePath: String) async throws -> [RemoteFileEntry] { [] }

    func stat(relativePath: String) async throws -> RemoteFileEntry {
        let size = lock.withLock { Int64(files[relativePath]?.count ?? 0) }
        return try RemoteFileEntry(relativePath: relativePath, kind: .file, size: size)
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        let data = lock.withLock {
            readCountStorage += 1
            return files[relativePath]
        }
        if let readGate { await readGate.wait() }
        if Task.isCancelled {
            lock.withLock { cancellationCrossingsStorage += 1 }
            throw CancellationError()
        }
        guard let data else {
            throw MediaTransportError.protocolViolation(
                reason: "no metadata fixture for requested path"
            )
        }
        return Data(data.prefix(maximumBytes))
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        throw MediaTransportError.unsupportedCapability("metadata fixture has no byte source")
    }
}

final class MetadataTestSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem
    private let lock = NSLock()
    private var shutdownCountStorage = 0

    init(
        fileSystem: any MediaTransportFileSystem = MetadataFileSystemSpy(),
        credentialRevision: CredentialRevision = CredentialRevision(),
        role: MediaTransportRole = .metadata
    ) {
        self.key = try! MediaTransportSessionKey(
            accountID: "metadata-test-account",
            credentialRevision: credentialRevision,
            endpoint: try! MediaTransportEndpointIdentity(
                transportIdentifier: "smb",
                host: "fixture.invalid",
                rootPath: "/fixture"
            ),
            trustRevision: UUID(),
            role: role
        )
        self.fileSystem = fileSystem
    }

    var shutdownCount: Int { lock.withLock { shutdownCountStorage } }

    func shutdown() async {
        lock.withLock { shutdownCountStorage += 1 }
    }
}

final class ShareCatalogSQLiteFixture {
    let accountKey: String
    let directory: URL
    let catalogURL: URL

    init(accountKey: String = "foundation-\(UUID().uuidString)") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-foundation-\(UUID().uuidString)", isDirectory: true)
        self.accountKey = accountKey
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.catalogURL = Self.catalogURL(accountKey: accountKey, directory: directory)
    }

    func makeStore() -> ShareCatalogStore {
        ShareCatalogStore(accountKey: accountKey, directory: directory)
    }

    func execute(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(catalogURL.path, &db) == SQLITE_OK, let db else {
            throw error(code: 1, db: db)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw error(code: 2, db: db)
        }
    }

    func integer(_ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(catalogURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw error(code: 3, db: db)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error(code: 4, db: db)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw error(code: 5, db: db)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func text(_ sql: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(catalogURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw error(code: 6, db: db)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error(code: 7, db: db)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: value)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func error(code: Int, db: OpaquePointer?) -> NSError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed"
        return NSError(
            domain: "ShareCatalogSQLiteFixture",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func catalogURL(accountKey: String, directory: URL) -> URL {
        let allowed = CharacterSet.alphanumerics
        let mapped = String(accountKey.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        })
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in accountKey.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return directory.appendingPathComponent(
            "share-catalog-\(mapped.prefix(80))-\(String(hash, radix: 16)).sqlite"
        )
    }
}
