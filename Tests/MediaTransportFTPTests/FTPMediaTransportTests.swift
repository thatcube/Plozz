import CoreModels
import Foundation
import MediaTransportCore
@testable import MediaTransportFTP
import XCTest

/// Hermetic coverage for the FTP adapter/filesystem/byte-source composition,
/// driven through an in-memory ``FakeFTPServer`` (no socket) — the FTP analogue
/// of the WebDAV stub-URLProtocol and SMB fake-backend tests. The real
/// `NWConnection` engine is exercised separately (integration), like SMB's.
final class FTPMediaTransportTests: XCTestCase {
    private let revision = CredentialRevision()

    // MARK: - Helpers

    private func makeKey(
        scheme: String = "ftp",
        host: String = "nas.example.com",
        rootPath: String = "/media"
    ) throws -> MediaTransportSessionKey {
        MediaTransportSessionKey(
            accountID: "account",
            credentialRevision: revision,
            endpoint: try MediaTransportEndpointIdentity(
                transportIdentifier: scheme,
                host: host,
                port: 21,
                rootPath: rootPath
            ),
            trustRevision: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            role: .scanner
        )
    }

    private func makeAdapter(
        scheme: FTPScheme = .ftp,
        server: FakeFTPServer,
        security: FTPSecurity = .plaintext
    ) -> FTPMediaTransportAdapter {
        FTPMediaTransportAdapter(
            scheme: scheme,
            configurationProvider: { _, _ in
                FTPMediaTransportConfiguration(credential: .anonymous, security: security)
            },
            backendMaker: { _, _ in FakeFTPBackend(server: server) }
        )
    }

    private func locator(
        relativePath: String,
        size: Int64,
        modifiedAt: Date
    ) throws -> NetworkFileLocator {
        let identity = try RemoteFileIdentity(kind: .modificationTime, modifiedAt: modifiedAt)
        let representation = try RemoteFileRepresentation(
            size: size,
            identity: identity,
            consistency: .changeDetecting
        )
        return try NetworkFileLocator(
            accountID: "account",
            sourceID: "account",
            credentialRevision: revision,
            relativePath: relativePath,
            representation: representation
        )
    }

    // MARK: - connect guard

    func testConnectRejectsMismatchedTransportIdentifier() async throws {
        let adapter = makeAdapter(server: FakeFTPServer())
        let key = try makeKey(scheme: "ftps")
        do {
            _ = try await adapter.connect(for: key)
            XCTFail("expected mismatch rejection")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .unsupportedCapability("transport"))
        }
    }

    func testExplicitTLSRejectedByNetworkBackend() async throws {
        // The real backend rejects explicit FTPS before opening any socket, so
        // this is hermetic (no network).
        let endpoint = try MediaTransportEndpointIdentity(
            transportIdentifier: "ftps",
            host: "nas.example.com",
            port: 21,
            rootPath: "/media"
        )
        let target = try FTPConnectionTarget(endpoint: endpoint, security: .explicitTLS)
        let backend = FTPNetworkBackend(
            target: target,
            configuration: FTPMediaTransportConfiguration(credential: .anonymous, security: .explicitTLS)
        )
        do {
            try await backend.connect()
            XCTFail("expected explicit-TLS rejection")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .unsupportedCapability("FTP explicit TLS (AUTH TLS) is unavailable on tvOS"))
        }
    }

    // MARK: - Browse

    func testListMapsChildren() async throws {
        let server = FakeFTPServer()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        server.addDirectory(path: "/media")
        server.addDirectory(path: "/media/Season 1", mtime: now)
        server.addFile(path: "/media/Episode.mkv", data: Data(count: 2048), mtime: now)
        let adapter = makeAdapter(server: server)
        let session = try await adapter.connect(for: try makeKey())

        let entries = try await session.fileSystem.list(relativePath: "")
        XCTAssertEqual(Set(entries.map(\.relativePath)), ["Season 1", "Episode.mkv"])
        let file = entries.first { $0.kind == .file }
        XCTAssertEqual(file?.size, 2048)
        XCTAssertEqual(file?.modifiedAt, now)
    }

    func testStatReturnsFile() async throws {
        let server = FakeFTPServer()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        server.addDirectory(path: "/media")
        server.addFile(path: "/media/movie.mkv", data: Data(count: 4096), mtime: now)
        let adapter = makeAdapter(server: server)
        let session = try await adapter.connect(for: try makeKey())

        let entry = try await session.fileSystem.stat(relativePath: "movie.mkv")
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.size, 4096)
        XCTAssertEqual(entry.relativePath, "movie.mkv")
    }

    func testReadSmallFile() async throws {
        let server = FakeFTPServer()
        let payload = Data("<nfo>hello</nfo>".utf8)
        server.addDirectory(path: "/media")
        server.addFile(path: "/media/movie.nfo", data: payload, mtime: Date())
        let adapter = makeAdapter(server: server)
        let session = try await adapter.connect(for: try makeKey())

        let data = try await session.fileSystem.readSmallFile(relativePath: "movie.nfo", maximumBytes: 1024)
        XCTAssertEqual(data, payload)
    }

    func testReadSmallFileRejectsOverBound() async throws {
        let server = FakeFTPServer()
        server.addDirectory(path: "/media")
        server.addFile(path: "/media/big.bin", data: Data(count: 4096), mtime: Date())
        let adapter = makeAdapter(server: server)
        let session = try await adapter.connect(for: try makeKey())

        do {
            _ = try await session.fileSystem.readSmallFile(relativePath: "big.bin", maximumBytes: 1024)
            XCTFail("expected over-bound rejection")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .invalidInput(reason: "FTP file exceeds bound"))
        }
    }

    // MARK: - Playback source

    func testOpenSourceRangedRead() async throws {
        let server = FakeFTPServer()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = Data((0..<1000).map { UInt8($0 % 256) })
        server.addDirectory(path: "/media")
        server.addFile(path: "/media/movie.mkv", data: payload, mtime: now)
        let adapter = makeAdapter(server: server)
        let session = try await adapter.connect(for: try makeKey())

        let lease = try await session.fileSystem.openSource(
            for: try locator(relativePath: "movie.mkv", size: 1000, modifiedAt: now)
        )
        XCTAssertEqual(lease.byteSize, 1000)
        let cursor = try XCTUnwrap(lease.makeCursor())

        let head = try await cursor.read(at: 0, length: 10)
        XCTAssertEqual(head, payload.subdata(in: 0..<10))
        let mid = try await cursor.read(at: 500, length: 20)
        XCTAssertEqual(mid, payload.subdata(in: 500..<520))
        // Read past EOF returns empty (normal AVIO end-of-stream probe).
        let tail = try await cursor.read(at: 1000, length: 16)
        XCTAssertTrue(tail.isEmpty)
        cursor.close()
    }

    func testOpenSourceRejectsChangedRepresentation() async throws {
        let server = FakeFTPServer()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        server.addDirectory(path: "/media")
        server.addFile(path: "/media/movie.mkv", data: Data(count: 1000), mtime: now)
        let adapter = makeAdapter(server: server)
        let session = try await adapter.connect(for: try makeKey())

        do {
            // Locator claims a different size than the server currently reports.
            _ = try await session.fileSystem.openSource(
                for: try locator(relativePath: "movie.mkv", size: 999, modifiedAt: now)
            )
            XCTFail("expected sourceChanged")
        } catch let error as MediaTransportError {
            guard case .sourceChanged = error else {
                return XCTFail("expected sourceChanged, got \(error)")
            }
        }
    }

    func testOpenSourceRejectsLocatorSessionMismatch() async throws {
        let server = FakeFTPServer()
        server.addDirectory(path: "/media")
        server.addFile(path: "/media/movie.mkv", data: Data(count: 10), mtime: Date())
        let adapter = makeAdapter(server: server)
        let session = try await adapter.connect(for: try makeKey())

        let identity = try RemoteFileIdentity(kind: .modificationTime, modifiedAt: Date())
        let representation = try RemoteFileRepresentation(size: 10, identity: identity, consistency: .changeDetecting)
        let mismatched = try NetworkFileLocator(
            accountID: "someone-else",
            sourceID: "someone-else",
            credentialRevision: revision,
            relativePath: "movie.mkv",
            representation: representation
        )
        do {
            _ = try await session.fileSystem.openSource(for: mismatched)
            XCTFail("expected mismatch rejection")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .invalidInput(reason: "locator session mismatch"))
        }
    }

    func testProbeAdvertisesRandomAccessWhenRestartSupported() async throws {
        let server = FakeFTPServer()
        server.addDirectory(path: "/media")
        let adapter = makeAdapter(server: server)
        let session = try await adapter.connect(for: try makeKey())

        let probe = try await session.fileSystem.probe()
        XCTAssertEqual(probe.capabilities.byteRangeBehavior, .randomAccess)
        XCTAssertTrue(probe.capabilities.supportsList)
        XCTAssertEqual(probe.capabilities.consistency, .changeDetecting)
    }

    func testProbeAdvertisesBoundedWhenRestartUnsupported() async throws {
        let server = FakeFTPServer()
        server.restartSupported = false
        server.addDirectory(path: "/media")
        let adapter = makeAdapter(server: server)
        let session = try await adapter.connect(for: try makeKey())

        // Honest capability: no REST → list-but-not-seekable (fail-closed).
        let probe = try await session.fileSystem.probe()
        XCTAssertEqual(probe.capabilities.byteRangeBehavior, .bounded)
    }

    func testOpenSourceFailsClosedWithoutRestart() async throws {
        let server = FakeFTPServer()
        server.restartSupported = false
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        server.addDirectory(path: "/media")
        server.addFile(path: "/media/movie.mkv", data: Data(count: 1000), mtime: now)
        let adapter = makeAdapter(server: server)
        let session = try await adapter.connect(for: try makeKey())

        do {
            _ = try await session.fileSystem.openSource(
                for: try locator(relativePath: "movie.mkv", size: 1000, modifiedAt: now)
            )
            XCTFail("expected unsupportedRange for a non-REST server")
        } catch let error as MediaTransportError {
            guard case .unsupportedRange = error else {
                return XCTFail("expected unsupportedRange, got \(error)")
            }
        }
    }
}
