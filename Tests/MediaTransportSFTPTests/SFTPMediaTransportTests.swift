import CoreModels
import Foundation
import MediaTransportCore
import XCTest

@testable import MediaTransportSFTP

/// Hermetic coverage of the SFTP adapter / session / filesystem / byte-source
/// against an in-memory ``SFTPTransportBackend`` — no SSH, no network — exactly
/// how `MediaTransportSMBTests` stubs its backend.
final class SFTPMediaTransportTests: XCTestCase {
    func testConnectResolvesRootScopesListingAndPassesCredentialAndPin() async throws {
        let revision = CredentialRevision()
        let backend = FakeSFTPBackend()
        backend.realPathMapping["/media"] = "/media"
        backend.childrenByDir["/media"] = [
            entry(name: "Movies", kind: .directory),
            entry(name: "movie.mkv", kind: .file, size: 42, modifiedAt: Date(timeIntervalSince1970: 100)),
            entry(name: ".", kind: .directory),
            entry(name: "..", kind: .directory),
        ]
        let pin = Array(repeating: UInt8(7), count: 32)

        let adapter = SFTPMediaTransportAdapter(
            configurationProvider: { accountID, requestedRevision in
                XCTAssertEqual(accountID, "account")
                XCTAssertEqual(requestedRevision, revision)
                return SFTPMediaTransportConfiguration(
                    credential: .password(username: "viewer", password: "secret"),
                    hostKeyPolicy: .pinned(sha256: pin)
                )
            },
            backendFactory: { backend }
        )

        let session = try await adapter.connect(for: makeKey(revision: revision))
        let entries = try await session.fileSystem.list(relativePath: "")

        XCTAssertEqual(backend.connectedHost, "nas.local")
        XCTAssertEqual(backend.connectedPort, 22)
        XCTAssertEqual(backend.connectedCredential, .password(username: "viewer", password: "secret"))
        XCTAssertEqual(backend.connectedHostKeyPolicy, .pinned(sha256: pin))
        XCTAssertEqual(backend.listedPaths, ["/media"])
        XCTAssertEqual(entries.map(\.relativePath), ["Movies", "movie.mkv"])
        XCTAssertEqual(entries.map(\.kind), [.directory, .file])
        XCTAssertEqual(entries.first(where: { $0.kind == .file })?.size, 42)
    }

    func testListSubdirectoryJoinsRelativePaths() async throws {
        let backend = FakeSFTPBackend()
        backend.childrenByDir["/media/Genre"] = [entry(name: "clip.mp4", kind: .file, size: 1)]
        let session = try await connect(backend: backend)

        let entries = try await session.fileSystem.list(relativePath: "Genre")
        XCTAssertEqual(backend.listedPaths, ["/media/Genre"])
        XCTAssertEqual(entries.map(\.relativePath), ["Genre/clip.mp4"])
    }

    func testStatReturnsEntry() async throws {
        let backend = FakeSFTPBackend()
        backend.entriesByPath["/media/movie.mkv"] =
            entry(name: "movie.mkv", kind: .file, size: 9, modifiedAt: Date(timeIntervalSince1970: 5))
        let session = try await connect(backend: backend)

        let stat = try await session.fileSystem.stat(relativePath: "movie.mkv")
        XCTAssertEqual(stat.relativePath, "movie.mkv")
        XCTAssertEqual(stat.kind, .file)
        XCTAssertEqual(stat.size, 9)
        XCTAssertEqual(stat.modifiedAt, Date(timeIntervalSince1970: 5))
    }

    func testReadSmallFile() async throws {
        let backend = FakeSFTPBackend()
        let data = Data([1, 2, 3, 4, 5])
        backend.entriesByPath["/media/small.nfo"] = entry(name: "small.nfo", kind: .file, size: 5)
        backend.dataByPath["/media/small.nfo"] = data
        let session = try await connect(backend: backend)

        let read = try await session.fileSystem.readSmallFile(relativePath: "small.nfo", maximumBytes: 16)
        XCTAssertEqual(read, data)
    }

    func testOpenSourceValidatesRepresentationProvesSeekabilityAndReads() async throws {
        let revision = CredentialRevision()
        let backend = FakeSFTPBackend()
        let bytes = Data(0..<10)
        let modifiedAt = Date(timeIntervalSince1970: 100)
        backend.entriesByPath["/media/movie.mkv"] =
            entry(name: "movie.mkv", kind: .file, size: 10, modifiedAt: modifiedAt)
        backend.dataByPath["/media/movie.mkv"] = bytes
        let session = try await connect(backend: backend, revision: revision)

        let locator = try makeLocator(revision: revision, size: 10, modifiedAt: modifiedAt)
        let lease = try await session.fileSystem.openSource(for: locator)
        XCTAssertEqual(lease.byteSize, 10)

        // The seekability proof reads one byte at the last offset.
        XCTAssertTrue(backend.reads.contains(where: { $0.offset == 9 && $0.length == 1 }))

        let cursor = try XCTUnwrap(lease.makeCursor())
        let mid = try await cursor.read(at: 2, length: 4)
        XCTAssertEqual(mid, Data(bytes[2..<6]))

        let atEOF = try await cursor.read(at: 10, length: 4)
        XCTAssertEqual(atEOF, Data())

        let clamped = try await cursor.read(at: 8, length: 100)
        XCTAssertEqual(clamped, Data(bytes[8..<10]))

        cursor.close()
        await lease.waitForFinalShutdown()
        XCTAssertEqual(backend.closedHandles, 1)
    }

    func testOpenSourceRejectsSizeDrift() async throws {
        let revision = CredentialRevision()
        let backend = FakeSFTPBackend()
        let modifiedAt = Date(timeIntervalSince1970: 100)
        backend.entriesByPath["/media/movie.mkv"] =
            entry(name: "movie.mkv", kind: .file, size: 11, modifiedAt: modifiedAt) // drifted
        backend.dataByPath["/media/movie.mkv"] = Data(0..<11)
        let session = try await connect(backend: backend, revision: revision)

        let locator = try makeLocator(revision: revision, size: 10, modifiedAt: modifiedAt)
        await XCTAssertThrowsErrorAsync(try await session.fileSystem.openSource(for: locator)) { error in
            XCTAssertEqual(error as? MediaTransportError, .sourceChanged(reason: "SFTP representation changed"))
        }
        XCTAssertEqual(backend.closedHandles, 1, "a handle opened for a drifted file is closed")
    }

    func testOpenSourceRejectsModificationTimeDrift() async throws {
        let revision = CredentialRevision()
        let backend = FakeSFTPBackend()
        backend.entriesByPath["/media/movie.mkv"] =
            entry(name: "movie.mkv", kind: .file, size: 10, modifiedAt: Date(timeIntervalSince1970: 999))
        backend.dataByPath["/media/movie.mkv"] = Data(0..<10)
        let session = try await connect(backend: backend, revision: revision)

        let locator = try makeLocator(revision: revision, size: 10, modifiedAt: Date(timeIntervalSince1970: 100))
        await XCTAssertThrowsErrorAsync(try await session.fileSystem.openSource(for: locator)) { error in
            XCTAssertEqual(error as? MediaTransportError, .sourceChanged(reason: "SFTP representation changed"))
        }
    }

    func testOpenSourceRejectsNonModificationTimeIdentity() async throws {
        let revision = CredentialRevision()
        let backend = FakeSFTPBackend()
        backend.entriesByPath["/media/movie.mkv"] =
            entry(name: "movie.mkv", kind: .file, size: 10, modifiedAt: Date(timeIntervalSince1970: 100))
        let session = try await connect(backend: backend, revision: revision)

        let representation = try RemoteFileRepresentation(
            size: 10,
            identity: RemoteFileIdentity(kind: .fileIdentifier, value: "inode-1"),
            consistency: .changeDetecting
        )
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "source",
            credentialRevision: revision,
            relativePath: "movie.mkv",
            representation: representation
        )
        await XCTAssertThrowsErrorAsync(try await session.fileSystem.openSource(for: locator)) { error in
            XCTAssertEqual(
                error as? MediaTransportError,
                .unsupportedRange(reason: "SFTP playback requires a modification-time representation")
            )
        }
        XCTAssertEqual(backend.openedFiles, 0, "a non-seekable representation never opens a handle")
    }

    func testOpenSourceRejectsLocatorFromAnotherRevision() async throws {
        let backend = FakeSFTPBackend()
        let session = try await connect(backend: backend, revision: CredentialRevision())
        let locator = try makeLocator(
            revision: CredentialRevision(),
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        await XCTAssertThrowsErrorAsync(try await session.fileSystem.openSource(for: locator)) { error in
            XCTAssertEqual(error as? MediaTransportError, .invalidInput(reason: "locator session mismatch"))
        }
    }

    func testConnectFailureShutsDownBackend() async throws {
        let backend = FakeSFTPBackend()
        backend.connectError = MediaTransportError.authentication(reason: "rejected")
        let adapter = SFTPMediaTransportAdapter(
            configurationProvider: { _, _ in
                SFTPMediaTransportConfiguration(
                    credential: .password(username: "u", password: "p"),
                    hostKeyPolicy: .pinned(sha256: Array(repeating: 0, count: 32))
                )
            },
            backendFactory: { backend }
        )
        await XCTAssertThrowsErrorAsync(try await adapter.connect(for: makeKey())) { error in
            XCTAssertEqual(error as? MediaTransportError, .authentication(reason: "rejected"))
        }
        XCTAssertEqual(backend.shutdownCount, 1)
    }

    func testAdapterRejectsForeignTransportEndpoint() async throws {
        let backend = FakeSFTPBackend()
        let adapter = SFTPMediaTransportAdapter(
            configurationProvider: { _, _ in
                SFTPMediaTransportConfiguration(
                    credential: .password(username: "u", password: "p"),
                    hostKeyPolicy: .pinned(sha256: Array(repeating: 0, count: 32))
                )
            },
            backendFactory: { backend }
        )
        let key = MediaTransportSessionKey(
            accountID: "account",
            credentialRevision: CredentialRevision(),
            endpoint: try MediaTransportEndpointIdentity(
                transportIdentifier: "smb",
                host: "nas.local",
                rootPath: "/media"
            ),
            trustRevision: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            role: .scanner
        )
        await XCTAssertThrowsErrorAsync(try await adapter.connect(for: key)) { error in
            XCTAssertEqual(error as? MediaTransportError, .unsupportedCapability("transport"))
        }
    }

    func testTraversalAboveRootIsRejectedWithoutIO() async throws {
        let backend = FakeSFTPBackend()
        let session = try await connect(backend: backend)
        await XCTAssertThrowsErrorAsync(try await session.fileSystem.list(relativePath: "../outside")) { error in
            XCTAssertEqual(error as? MediaTransportError, .invalidInput(reason: "SFTP path traversal"))
        }
        XCTAssertTrue(backend.listedPaths.isEmpty)
    }

    func testProbeAdvertisesRandomAccessAndChangeDetection() async throws {
        let backend = FakeSFTPBackend()
        let session = try await connect(backend: backend)
        let probe = try await session.fileSystem.probe()
        XCTAssertEqual(probe.capabilities.byteRangeBehavior, .randomAccess)
        XCTAssertEqual(probe.capabilities.consistency, .changeDetecting)
        XCTAssertTrue(probe.capabilities.supportsList)
        XCTAssertTrue(probe.capabilities.supportsStat)
    }

    // MARK: - Helpers

    private func connect(
        backend: FakeSFTPBackend,
        revision: CredentialRevision = CredentialRevision()
    ) async throws -> any MediaTransportSession {
        let adapter = SFTPMediaTransportAdapter(
            configurationProvider: { _, _ in
                SFTPMediaTransportConfiguration(
                    credential: .password(username: "u", password: "p"),
                    hostKeyPolicy: .pinned(sha256: Array(repeating: 1, count: 32))
                )
            },
            backendFactory: { backend }
        )
        return try await adapter.connect(for: makeKey(revision: revision))
    }

    private func makeKey(
        revision: CredentialRevision = CredentialRevision()
    ) throws -> MediaTransportSessionKey {
        MediaTransportSessionKey(
            accountID: "account",
            credentialRevision: revision,
            endpoint: try MediaTransportEndpointIdentity(
                transportIdentifier: "sftp",
                host: "nas.local",
                rootPath: "/media"
            ),
            trustRevision: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            role: .scanner
        )
    }

    private func makeLocator(
        revision: CredentialRevision,
        size: Int64,
        modifiedAt: Date
    ) throws -> NetworkFileLocator {
        let representation = try RemoteFileRepresentation(
            size: size,
            identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: modifiedAt),
            consistency: .changeDetecting
        )
        return try NetworkFileLocator(
            accountID: "account",
            sourceID: "source",
            credentialRevision: revision,
            relativePath: "movie.mkv",
            representation: representation
        )
    }

    private func entry(
        name: String,
        kind: RemoteFileEntryKind,
        size: Int64? = nil,
        modifiedAt: Date? = nil
    ) -> SFTPBackendEntry {
        SFTPBackendEntry(name: name, kind: kind, size: kind == .directory ? nil : size, modifiedAt: modifiedAt)
    }
}

// MARK: - Fake backend

final class FakeSFTPBackend: SFTPTransportBackend, @unchecked Sendable {
    struct RecordedRead: Equatable {
        let offset: Int64
        let length: Int
    }

    private let lock = NSLock()

    // Configuration (set by tests before use).
    var connectError: Error?
    var realPathMapping: [String: String] = [:]
    var childrenByDir: [String: [SFTPBackendEntry]] = [:]
    var entriesByPath: [String: SFTPBackendEntry] = [:]
    var dataByPath: [String: Data] = [:]

    // Recorded interactions.
    private(set) var connectedHost: String?
    private(set) var connectedPort: Int?
    private(set) var connectedCredential: SFTPMediaTransportCredential?
    private(set) var connectedHostKeyPolicy: SFTPHostKeyPolicy?
    private(set) var listedPaths: [String] = []
    private(set) var reads: [RecordedRead] = []
    private(set) var shutdownCount = 0
    private(set) var closedHandles = 0
    private(set) var openedFiles = 0

    private var handleToPath: [[UInt8]: String] = [:]
    private var handleCounter: UInt8 = 0

    func connect(
        host: String,
        port: Int,
        credential: SFTPMediaTransportCredential,
        hostKeyPolicy: SFTPHostKeyPolicy
    ) async throws {
        try lock.withLock {
            if let connectError { throw connectError }
            connectedHost = host
            connectedPort = port
            connectedCredential = credential
            connectedHostKeyPolicy = hostKeyPolicy
        }
    }

    func realPath(_ path: String) async throws -> String {
        lock.withLock { realPathMapping[path] ?? path }
    }

    func list(path: String) async throws -> [SFTPBackendEntry] {
        try lock.withLock {
            listedPaths.append(path)
            guard let entries = childrenByDir[path] else {
                throw SFTPStatusError(code: .noSuchFile)
            }
            return entries
        }
    }

    func stat(path: String) async throws -> SFTPBackendEntry {
        try lock.withLock {
            guard let entry = entriesByPath[path] else {
                throw SFTPStatusError(code: .noSuchFile)
            }
            return entry
        }
    }

    func readSmallFile(path: String, maximumBytes: Int) async throws -> Data {
        try lock.withLock {
            guard let data = dataByPath[path] else {
                throw SFTPStatusError(code: .noSuchFile)
            }
            guard data.count <= maximumBytes else {
                throw MediaTransportError.invalidInput(reason: "small-file bound exceeded")
            }
            return data
        }
    }

    func openFile(path: String) async throws -> (handle: SFTPFileHandle, entry: SFTPBackendEntry) {
        try lock.withLock {
            guard let entry = entriesByPath[path] else {
                throw SFTPStatusError(code: .noSuchFile)
            }
            handleCounter &+= 1
            let raw = [handleCounter]
            handleToPath[raw] = path
            openedFiles += 1
            return (SFTPFileHandle(rawValue: raw), entry)
        }
    }

    func read(handle: SFTPFileHandle, offset: Int64, length: Int) async throws -> Data {
        try lock.withLock {
            reads.append(RecordedRead(offset: offset, length: length))
            guard let path = handleToPath[handle.rawValue], let data = dataByPath[path] else {
                throw SFTPStatusError(code: .noSuchFile)
            }
            guard offset < Int64(data.count) else { return Data() }
            let start = Int(offset)
            let end = min(start + length, data.count)
            return data.subdata(in: start..<end)
        }
    }

    func closeFile(handle: SFTPFileHandle) async {
        lock.withLock {
            if handleToPath.removeValue(forKey: handle.rawValue) != nil {
                closedHandles += 1
            }
        }
    }

    func shutdown() async {
        lock.withLock { shutdownCount += 1 }
    }
}

// MARK: - Async assertion helper

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
