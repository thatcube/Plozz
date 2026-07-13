import CoreModels
import Foundation
import MediaTransportCore
@testable import MediaTransportHTTP
@testable import MediaTransportWebDAV
import XCTest

/// Hermetic coverage for the WebDAV media-transport adapter, driving the full
/// request/response path through a stub `URLProtocol` (no real network). Trust
/// pinning against a live TLS handshake is covered at the primitive level
/// (`TransportTrustTests`, `TransportSessionDelegateTests`); here we exercise
/// the adapter's composition, mapping, path handling, and ETag revalidation.
final class WebDAVMediaTransportTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeAdapter(
        scheme: WebDAVScheme = .https,
        credential: WebDAVCredential = .anonymous,
        trustPolicy: TrustPolicy = .system
    ) -> WebDAVMediaTransportAdapter {
        WebDAVMediaTransportAdapter(
            scheme: scheme,
            configurationProvider: { _, _ in
                WebDAVMediaTransportConfiguration(credential: credential, trustPolicy: trustPolicy)
            },
            registryFactory: { TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self]) }
        )
    }

    private func makeKey(
        scheme: String = "https",
        host: String = "nas.example.com",
        rootPath: String = "/dav/movies",
        revision: CredentialRevision = CredentialRevision(),
        trustRevision: UUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
        role: MediaTransportRole = .scanner
    ) throws -> MediaTransportSessionKey {
        MediaTransportSessionKey(
            accountID: "account",
            credentialRevision: revision,
            endpoint: try MediaTransportEndpointIdentity(
                transportIdentifier: scheme,
                host: host,
                rootPath: rootPath
            ),
            trustRevision: trustRevision,
            role: role
        )
    }

    // MARK: - connect guard

    func testConnectRejectsMismatchedTransportIdentifier() async throws {
        let adapter = makeAdapter(scheme: .https)
        do {
            _ = try await adapter.connect(for: try makeKey(scheme: "smb", host: "nas.local", rootPath: "/Media"))
            XCTFail("expected unsupportedCapability")
        } catch let error as MediaTransportError {
            guard case .unsupportedCapability = error else {
                return XCTFail("expected unsupportedCapability, got \(error)")
            }
        }
    }

    // MARK: - validate

    func testValidateSucceedsWhenServerAdvertisesDAV() async throws {
        StubURLProtocol.queue(
            StubResponse(statusCode: 200, headers: ["DAV": "1,2"]),
            for: URL(string: "https://nas.example.com/dav/movies")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        try await session.fileSystem.validate()
    }

    func testValidateFailsClosedWithoutDAVHeader() async throws {
        StubURLProtocol.queue(
            StubResponse(statusCode: 200, headers: ["Allow": "GET"]),
            for: URL(string: "https://nas.example.com/dav/movies")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        do {
            try await session.fileSystem.validate()
            XCTFail("expected protocolViolation")
        } catch let error as MediaTransportError {
            guard case .protocolViolation = error else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
    }

    // MARK: - list

    func testListMapsChildrenToRootRelativeEntries() async throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/movies/Show/</D:href>
            <D:propstat>
              <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/movies/Movie.mkv</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>2048</D:getcontentlength>
                <D:getetag>"strong-1"</D:getetag>
                <D:getcontenttype>video/x-matroska</D:getcontenttype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        StubURLProtocol.queue(
            StubResponse(statusCode: 207, body: Data(xml.utf8)),
            for: URL(string: "https://nas.example.com/dav/movies")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        let entries = try await session.fileSystem.list(relativePath: "")

        XCTAssertEqual(entries.map(\.relativePath), ["Show", "Movie.mkv"])
        XCTAssertEqual(entries.map(\.kind), [.directory, .file])
        let file = try XCTUnwrap(entries.first { $0.kind == .file })
        XCTAssertEqual(file.size, 2048)
        XCTAssertEqual(file.strongETag, "\"strong-1\"")
        XCTAssertEqual(file.mimeType, "video/x-matroska")
    }

    func testListDropsWeakETagButStillListsFile() async throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/Weak.mkv</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>10</D:getcontentlength>
                <D:getetag>W/"weak-1"</D:getetag>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        StubURLProtocol.queue(
            StubResponse(statusCode: 207, body: Data(xml.utf8)),
            for: URL(string: "https://nas.example.com/dav/movies")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        let entries = try await session.fileSystem.list(relativePath: "")
        XCTAssertEqual(entries.map(\.relativePath), ["Weak.mkv"])
        XCTAssertNil(entries.first?.strongETag, "a weak ETag must not be stored as a strong validator")
    }

    // MARK: - stat

    func testStatReturnsFileEntry() async throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/Movie.mkv</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>4096</D:getcontentlength>
                <D:getetag>"strong-2"</D:getetag>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        StubURLProtocol.queue(
            StubResponse(statusCode: 207, body: Data(xml.utf8)),
            for: URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        let entry = try await session.fileSystem.stat(relativePath: "Movie.mkv")
        XCTAssertEqual(entry.relativePath, "Movie.mkv")
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.size, 4096)
        XCTAssertEqual(entry.strongETag, "\"strong-2\"")
    }

    // MARK: - readSmallFile

    func testReadSmallFileReturnsBoundedBody() async throws {
        let payload = Data("<movie/>".utf8)
        StubURLProtocol.queue(
            StubResponse(statusCode: 200, headers: ["Content-Length": "\(payload.count)"], body: payload),
            for: URL(string: "https://nas.example.com/dav/movies/movie.nfo")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        let data = try await session.fileSystem.readSmallFile(relativePath: "movie.nfo", maximumBytes: 4096)
        XCTAssertEqual(data, payload)
    }

    // MARK: - openSource

    private func strongETagLocator(
        relativePath: String = "Movie.mkv",
        etag: String = "\"strong-1\"",
        size: Int64 = 1000,
        revision: CredentialRevision
    ) throws -> NetworkFileLocator {
        try NetworkFileLocator(
            accountID: "account",
            sourceID: "account",
            credentialRevision: revision,
            relativePath: relativePath,
            representation: try RemoteFileRepresentation(
                size: size,
                identity: try RemoteFileIdentity(kind: .strongETag, value: etag),
                consistency: .changeDetecting
            )
        )
    }

    func testOpenSourceRejectsNonStrongETagRepresentation() async throws {
        let revision = CredentialRevision()
        let session = try await makeAdapter().connect(for: try makeKey(revision: revision, role: .playback))
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "account",
            credentialRevision: revision,
            relativePath: "Movie.mkv",
            representation: try RemoteFileRepresentation(
                size: 10,
                identity: try RemoteFileIdentity(kind: .modificationTime, modifiedAt: Date(timeIntervalSince1970: 1)),
                consistency: .changeDetecting
            )
        )
        do {
            _ = try await session.fileSystem.openSource(for: locator)
            XCTFail("expected unsupportedRange")
        } catch let error as MediaTransportError {
            guard case .unsupportedRange = error else {
                return XCTFail("expected unsupportedRange, got \(error)")
            }
        }
    }

    func testOpenSourceProbesThenReadsWithIfMatchRevalidation() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let observedIfMatch = LockedValue<String?>(nil)
        // 1) range probe: 206 + strong ETag + Content-Range 0-0/1000, 1-byte body.
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-0/1000"],
                body: Data([0x00])
            ),
            for: url
        )
        // 2) bounded read: 206 + Content-Range 0-3/1000 + matching ETag, 4-byte body.
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-3/1000"],
                body: Data([1, 2, 3, 4]),
                onRequest: { observedIfMatch.set($0.value(forHTTPHeaderField: "If-Match")) }
            ),
            for: url
        )

        let session = try await makeAdapter().connect(for: try makeKey(revision: revision, role: .playback))
        let lease = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
        XCTAssertEqual(lease.byteSize, 1000)
        let cursor = try XCTUnwrap(lease.makeCursor())
        let bytes = try await cursor.read(at: 0, length: 4)
        XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
        XCTAssertEqual(observedIfMatch.get(), "\"strong-1\"", "every read must revalidate the probed strong ETag")
    }

    func testOpenSourceDetectsETagDrift() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        // Probe succeeds but returns a DIFFERENT strong ETag than the locator's.
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"changed\"", "Content-Range": "bytes 0-0/1000"],
                body: Data([0x00])
            ),
            for: url
        )
        let session = try await makeAdapter().connect(for: try makeKey(revision: revision, role: .playback))
        do {
            _ = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
            XCTFail("expected sourceChanged")
        } catch let error as MediaTransportError {
            guard case .sourceChanged = error else {
                return XCTFail("expected sourceChanged, got \(error)")
            }
        }
    }

    func testByteSourceReturnsEmptyAtEOF() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-0/1000"],
                body: Data([0x00])
            ),
            for: url
        )
        let session = try await makeAdapter().connect(for: try makeKey(revision: revision, role: .playback))
        let lease = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
        let cursor = try XCTUnwrap(lease.makeCursor())
        let atEOF = try await cursor.read(at: 1000, length: 16)
        XCTAssertEqual(atEOF, Data(), "a read at/after EOF returns empty rather than requesting an unsatisfiable range")
    }

    func testOpenSourceRejectsLocatorFromAnotherRevision() async throws {
        let revision = CredentialRevision()
        let session = try await makeAdapter().connect(for: try makeKey(revision: revision, role: .playback))
        let locator = try strongETagLocator(revision: CredentialRevision())
        do {
            _ = try await session.fileSystem.openSource(for: locator)
            XCTFail("expected invalidInput")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .invalidInput(reason: "locator session mismatch"))
        }
    }

    // MARK: - trust-revision threading

    func testTrustRevisionMismatchFailsClosed() async throws {
        // A pinned-leaf trust policy whose revision disagrees with the key's
        // trustRevision must be rejected by the session registry before any
        // request — proving the adapter threads the trust revision, not that
        // it silently ignores a mismatch.
        let keyTrustRevision = UUID()
        let adapter = WebDAVMediaTransportAdapter(
            scheme: .https,
            configurationProvider: { _, _ in
                WebDAVMediaTransportConfiguration(
                    credential: .anonymous,
                    trustPolicy: .pinnedLeaf(sha256: Data(repeating: 0xAB, count: 32), revision: UUID())
                )
            },
            registryFactory: { TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self]) }
        )
        StubURLProtocol.queue(
            StubResponse(statusCode: 200, headers: ["DAV": "1"]),
            for: URL(string: "https://nas.example.com/dav/movies")!
        )
        let session = try await adapter.connect(for: try makeKey(trustRevision: keyTrustRevision))
        do {
            try await session.fileSystem.validate()
            XCTFail("expected a session-configuration mismatch")
        } catch let error as MediaTransportError {
            guard case .protocolViolation = error else {
                return XCTFail("expected protocolViolation (sessionConfigurationMismatch), got \(error)")
            }
        }
    }
}
