import CoreModels
import Foundation
import XCTest
@testable import MediaTransportCore

private actor OrderedConnectionGate {
    private var nextConnection = 0
    private var released: Set<Int> = []
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var registrationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func register() -> Int {
        nextConnection += 1
        let ready = registrationWaiters.filter { nextConnection >= $0.count }
        registrationWaiters.removeAll { nextConnection >= $0.count }
        ready.forEach { $0.continuation.resume() }
        return nextConnection
    }

    func waitUntilRegistered(_ count: Int) async {
        guard nextConnection < count else { return }
        await withCheckedContinuation { continuation in
            registrationWaiters.append((count, continuation))
        }
    }

    func waitForRelease(_ connection: Int) async {
        guard !released.contains(connection) else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters[connection] = continuation
        }
    }

    func release(_ connection: Int) {
        released.insert(connection)
        releaseWaiters.removeValue(forKey: connection)?.resume()
    }
}

private final class ShutdownGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        let waiters = lock.withLock {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            let isReleased = lock.withLock {
                guard !released else { return true }
                releaseWaiters.append(continuation)
                return false
            }
            if isReleased {
                continuation.resume()
            }
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let hasStarted = lock.withLock {
                guard !started else { return true }
                startWaiters.append(continuation)
                return false
            }
            if hasStarted {
                continuation.resume()
            }
        }
    }

    func release() {
        let waiters = lock.withLock {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }
}

private final class RacingSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem = FakeFileSystem()
    let shutdownGate: ShutdownGate?
    private let lock = NSLock()
    private var shutdownCountStorage = 0

    init(key: MediaTransportSessionKey, shutdownGate: ShutdownGate?) {
        self.key = key
        self.shutdownGate = shutdownGate
    }

    var shutdownCount: Int { lock.withLock { shutdownCountStorage } }

    func shutdown() async {
        lock.withLock { shutdownCountStorage += 1 }
        await shutdownGate?.wait()
    }
}

private final class RacingAdapter: MediaTransportAdapter, @unchecked Sendable {
    let transportIdentifier: String
    let gate = OrderedConnectionGate()
    private let lock = NSLock()
    private var sessions: [Int: RacingSession] = [:]

    init(transportIdentifier: String) {
        self.transportIdentifier = transportIdentifier
    }

    func session(_ connection: Int) -> RacingSession? {
        lock.withLock { sessions[connection] }
    }

    func connect(for key: MediaTransportSessionKey) async throws -> any MediaTransportSession {
        let connection = await gate.register()
        let session = RacingSession(
            key: key,
            shutdownGate: connection == 2 ? ShutdownGate() : nil
        )
        lock.withLock { sessions[connection] = session }
        await gate.waitForRelease(connection)
        return session
    }
}

final class ContractsAndResolverTests: XCTestCase {
    func testRemoteEntryNormalizesAndValidatesSecretSafeMetadata() throws {
        let diagnostic = try MediaTransportDiagnostic(code: "CACHE.HIT")
        let entry = try RemoteFileEntry(
            relativePath: "movies//Arrival.mkv",
            kind: .file,
            size: 42,
            stableFileID: "file-1",
            strongETag: "\"abc\"",
            changeToken: "revision-2",
            mimeType: " Video/Matroska ",
            diagnostics: [diagnostic]
        )

        XCTAssertEqual(entry.relativePath, "movies/Arrival.mkv")
        XCTAssertEqual(entry.name, "Arrival.mkv")
        XCTAssertEqual(entry.mimeType, "video/matroska")
        XCTAssertEqual(entry.diagnostics, [diagnostic])
        XCTAssertThrowsError(try RemoteFileEntry(relativePath: "../secret", kind: .file))
        XCTAssertThrowsError(
            try RemoteFileEntry(relativePath: "movie.mkv", kind: .file, strongETag: "W/\"weak\"")
        )
        XCTAssertThrowsError(try MediaTransportDiagnostic(code: "https://user:pass@host"))
    }

    func testCapabilitiesRejectDishonestBoundedReadLimit() {
        XCTAssertThrowsError(
            try MediaTransportCapabilities(
                supportsList: true,
                supportsStat: true,
                supportsBoundedWholeFileRead: true,
                byteRangeBehavior: .bounded,
                maximumBoundedWholeFileReadBytes: 0,
                consistency: .changeDetecting
            )
        )
        XCTAssertThrowsError(
            try MediaTransportCapabilities(
                supportsList: true,
                supportsStat: true,
                supportsBoundedWholeFileRead: false,
                byteRangeBehavior: .randomAccess,
                consistency: .changeDetecting
            )
        )
    }

    func testSessionKeyIsolatesEveryOwnershipDimension() throws {
        let credential = CredentialRevision()
        let trust = UUID()
        let endpoint = try makeEndpoint()
        let base = try makeSessionKey(
            credentialRevision: credential,
            endpoint: endpoint,
            trustRevision: trust
        )
        let keys: Set<MediaTransportSessionKey> = [
            base,
            try makeSessionKey(
                accountID: "other",
                credentialRevision: credential,
                endpoint: endpoint,
                trustRevision: trust
            ),
            try makeSessionKey(
                credentialRevision: CredentialRevision(),
                endpoint: endpoint,
                trustRevision: trust
            ),
            try makeSessionKey(
                credentialRevision: credential,
                endpoint: makeEndpoint(host: "other.example.com"),
                trustRevision: trust
            ),
            try makeSessionKey(
                credentialRevision: credential,
                endpoint: endpoint,
                trustRevision: UUID()
            ),
            try makeSessionKey(
                credentialRevision: credential,
                endpoint: endpoint,
                trustRevision: trust,
                role: .playback
            ),
        ]
        XCTAssertEqual(keys.count, 6)
    }

    func testErrorDescriptionsRedactAssociatedText() {
        let secret = "password=super-secret"
        let errors: [MediaTransportError] = [
            .invalidInput(reason: secret),
            .authentication(reason: secret),
            .trust(reason: secret),
            .protocolViolation(reason: secret),
            .sourceChanged(reason: secret),
            .transport(code: -1001),
        ]
        for error in errors {
            XCTAssertFalse(error.description.contains(secret))
            XCTAssertFalse(error.description.contains("super-secret"))
        }
        XCTAssertEqual(MediaTransportError.transport(code: -1001).description, "transport(code: -1001)")
    }

    func testRetirementPinsActiveLeaseAndOldAndNewRevisionsCoexist() async throws {
        let oldRevision = CredentialRevision()
        let newRevision = CredentialRevision()
        let endpoint = try makeEndpoint()
        let trust = UUID()
        let oldKey = try makeSessionKey(
            credentialRevision: oldRevision,
            endpoint: endpoint,
            trustRevision: trust
        )
        let newKey = try makeSessionKey(
            credentialRevision: newRevision,
            endpoint: endpoint,
            trustRevision: trust
        )
        let oldSession = FakeSession(key: oldKey)
        let newSession = FakeSession(key: newKey)
        let registry = MediaTransportResolverRegistry()
        try await registry.register(session: oldSession)
        try await registry.register(session: newSession)

        let oldLease = try await registry.lease(for: oldKey)
        let newLease = try await registry.lease(for: newKey)
        await registry.retire(accountID: oldKey.accountID, credentialRevision: oldRevision)

        XCTAssertEqual(oldSession.shutdownCount, 0)
        XCTAssertTrue(oldLease.session === oldSession)
        XCTAssertTrue(newLease.session === newSession)
        do {
            _ = try await registry.lease(for: oldKey)
            XCTFail("retired revision accepted a new lease")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }

        oldLease.release()
        let oldFinalized = await waitUntil { oldSession.shutdownCount == 1 }
        XCTAssertTrue(oldFinalized)
        XCTAssertEqual(newSession.shutdownCount, 0)
        let liveSessionCount = await registry.liveSessionCount
        XCTAssertEqual(liveSessionCount, 1)
        newLease.release()
    }

    func testFinalizerRunsExactlyOnceAfterFinalLeaseDrains() async throws {
        let revision = CredentialRevision()
        let key = try makeSessionKey(credentialRevision: revision)
        let session = FakeSession(key: key)
        let registry = MediaTransportResolverRegistry()
        try await registry.register(session: session)
        let first = try await registry.lease(for: key)
        let second = try await registry.lease(for: key)

        await registry.retire(accountID: key.accountID, credentialRevision: revision)
        first.release()
        first.release()
        XCTAssertEqual(session.shutdownCount, 0)
        second.release()
        let finalized = await waitUntil { session.shutdownCount == 1 }
        XCTAssertTrue(finalized)
        await registry.retire(accountID: key.accountID, credentialRevision: revision)
        XCTAssertEqual(session.shutdownCount, 1)
    }

    func testRegisteredAdapterCreatesAndReusesOwnedSession() async throws {
        let revision = CredentialRevision()
        let key = try makeSessionKey(credentialRevision: revision)
        let session = FakeSession(key: key)
        let adapter = FakeAdapter(
            transportIdentifier: key.endpoint.transportIdentifier,
            session: session
        )
        let registry = MediaTransportResolverRegistry()
        try await registry.register(adapter: adapter)

        let first = try await registry.lease(for: key)
        let second = try await registry.lease(for: key)
        XCTAssertTrue(first.session === session)
        XCTAssertTrue(second.session === session)
        XCTAssertEqual(adapter.connectCount, 1)

        await registry.retire(accountID: key.accountID, credentialRevision: revision)
        first.release()
        second.release()
        let finalized = await waitUntil { session.shutdownCount == 1 }
        XCTAssertTrue(finalized)
    }

    func testRacedConnectionCannotResurrectRetiredSession() async throws {
        let revision = CredentialRevision()
        let key = try makeSessionKey(credentialRevision: revision)
        let adapter = RacingAdapter(transportIdentifier: key.endpoint.transportIdentifier)
        let registry = MediaTransportResolverRegistry()
        try await registry.register(adapter: adapter)

        let firstRequest = Task { try await registry.lease(for: key) }
        await adapter.gate.waitUntilRegistered(1)
        let secondRequest = Task { try await registry.lease(for: key) }
        await adapter.gate.waitUntilRegistered(2)

        await adapter.gate.release(1)
        let firstLease = try await firstRequest.value
        await adapter.gate.release(2)
        let redundantSession = try XCTUnwrap(adapter.session(2))
        let shutdownGate = try XCTUnwrap(redundantSession.shutdownGate)
        await shutdownGate.waitUntilStarted()

        await registry.retire(accountID: key.accountID, credentialRevision: revision)
        firstLease.release()
        shutdownGate.release()

        do {
            _ = try await secondRequest.value
            XCTFail("raced connection resurrected a retired session")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }
        let drained = await waitUntil {
            adapter.session(1)?.shutdownCount == 1 && redundantSession.shutdownCount == 1
        }
        XCTAssertTrue(drained)
        let liveSessionCount = await registry.liveSessionCount
        XCTAssertEqual(liveSessionCount, 0)
    }
}
