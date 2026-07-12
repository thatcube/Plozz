import CoreModels
import Foundation
@testable import MediaTransportCore

final class FakeByteSource: MediaTransportByteSource, @unchecked Sendable {
    private let lock = NSLock()
    private var shutdownCountStorage = 0
    let data: Data

    init(data: Data) {
        self.data = data
    }

    var byteSize: Int64 { Int64(data.count) }
    var shutdownCount: Int { lock.withLock { shutdownCountStorage } }

    func read(at offset: Int64, length: Int) async throws -> Data {
        guard offset < data.count else { return Data() }
        let end = min(Int(offset) + length, data.count)
        return data.subdata(in: Int(offset)..<end)
    }

    func shutdown() async {
        lock.withLock { shutdownCountStorage += 1 }
    }
}

final class FakeFileSystem: MediaTransportFileSystem, @unchecked Sendable {
    func validate() async throws {}

    func probe() async throws -> MediaTransportProbe {
        MediaTransportProbe(
            capabilities: try MediaTransportCapabilities(
                supportsList: true,
                supportsStat: true,
                supportsBoundedWholeFileRead: true,
                byteRangeBehavior: .randomAccess,
                maximumBoundedWholeFileReadBytes: 1_024,
                consistency: .representationBound
            )
        )
    }

    func list(relativePath: String) async throws -> [RemoteFileEntry] { [] }

    func stat(relativePath: String) async throws -> RemoteFileEntry {
        try RemoteFileEntry(relativePath: relativePath, kind: .file, size: 0)
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        Data()
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        MediaTransportSourceLease(source: FakeByteSource(data: Data()))
    }
}

final class FakeSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem = FakeFileSystem()
    private let lock = NSLock()
    private var shutdownCountStorage = 0

    init(key: MediaTransportSessionKey) {
        self.key = key
    }

    var shutdownCount: Int { lock.withLock { shutdownCountStorage } }

    func shutdown() async {
        lock.withLock { shutdownCountStorage += 1 }
    }
}

final class FakeAdapter: MediaTransportAdapter, @unchecked Sendable {
    let transportIdentifier: String
    let session: FakeSession
    private let lock = NSLock()
    private var connectCountStorage = 0

    init(transportIdentifier: String, session: FakeSession) {
        self.transportIdentifier = transportIdentifier
        self.session = session
    }

    var connectCount: Int { lock.withLock { connectCountStorage } }

    func connect(for key: MediaTransportSessionKey) async throws -> any MediaTransportSession {
        lock.withLock { connectCountStorage += 1 }
        guard key == session.key else {
            throw MediaTransportError.protocolViolation(reason: "unexpected key")
        }
        return session
    }
}

final class FakeScannerResource: MediaIOScannerResource, @unchecked Sendable {
    enum FakeError: Error { case closeFailed }

    private let lock = NSLock()
    private var cancelCountStorage = 0
    private var forceCloseCountStorage = 0
    var forceCloseFails = false

    var cancelCount: Int { lock.withLock { cancelCountStorage } }
    var forceCloseCount: Int { lock.withLock { forceCloseCountStorage } }
    var isDrained: Bool { true }

    func cancel() async {
        lock.withLock { cancelCountStorage += 1 }
    }

    func forceClose() async throws {
        let fails = lock.withLock {
            forceCloseCountStorage += 1
            return forceCloseFails
        }
        if fails { throw FakeError.closeFailed }
    }
}

struct FakeDrainDeadline: MediaIODrainDeadline {
    let drains: Bool

    func waitForDrain(
        of resource: any MediaIOScannerResource,
        timeout: Duration
    ) async -> Bool {
        drains
    }
}

func makeEndpoint(
    host: String = "nas.example.com",
    root: String = "/media"
) throws -> MediaTransportEndpointIdentity {
    try MediaTransportEndpointIdentity(
        transportIdentifier: "webdav",
        host: host,
        port: 443,
        rootPath: root
    )
}

func makeSessionKey(
    accountID: String = "account",
    credentialRevision: CredentialRevision = CredentialRevision(),
    endpoint: MediaTransportEndpointIdentity? = nil,
    trustRevision: UUID = UUID(),
    role: MediaTransportRole = .scanner
) throws -> MediaTransportSessionKey {
    MediaTransportSessionKey(
        accountID: accountID,
        credentialRevision: credentialRevision,
        endpoint: try endpoint ?? makeEndpoint(),
        trustRevision: trustRevision,
        role: role
    )
}

func waitUntil(
    iterations: Int = 1_000,
    _ predicate: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<iterations {
        if predicate() { return true }
        await Task.yield()
    }
    return predicate()
}
