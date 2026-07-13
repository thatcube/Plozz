import XCTest
@testable import MediaTransportHTTP

/// Coverage for the `stat` (Depth:0, self-entry-preserving) and bounded
/// whole-file `GET` surface added for the WebDAV media-transport adapter, plus
/// a regression test asserting the exact `Authorization` value a bearer
/// credential sends (locks the real header, which is redacted in tooling
/// displays and could otherwise silently regress to a literal mask).
final class WebDAVClientStatAndGetTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeKey(
        origin: TransportOrigin,
        accountID: String = "test-account",
        role: TransportRole = .scanner
    ) throws -> TransportSessionKey {
        try TransportSessionKey(
            accountID: accountID,
            credentialRevision: UUID(),
            origin: origin,
            trustRevision: UUID(),
            role: role
        )
    }

    private func makeClient() -> WebDAVClient {
        WebDAVClient(registry: TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self]))
    }

    private func makeRoot(origin: TransportOrigin, path: String = "/dav") -> WebDAVRoot {
        WebDAVRoot(origin: origin, rawPath: path)!
    }

    // MARK: - stat (Depth:0)

    func testPropertiesReturnsSelfEntryForFile() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let root = WebDAVRoot(origin: origin, normalizedPath: "/dav/movies")
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/Movie.mkv</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>1048576</D:getcontentlength>
                <D:getetag>"abc123"</D:getetag>
                <D:getcontenttype>video/x-matroska</D:getcontenttype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let observedDepth = LockedValue<String?>(nil)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 207,
                body: Data(xml.utf8),
                onRequest: { observedDepth.set($0.value(forHTTPHeaderField: "Depth")) }
            ),
            for: url
        )

        let entry = try await makeClient().properties(
            root: root,
            path: "/dav/movies/Movie.mkv",
            sessionKey: try makeKey(origin: origin),
            credential: .anonymous,
            trustPolicy: .system
        )

        XCTAssertEqual(observedDepth.get(), "0")
        XCTAssertEqual(entry.resolvedPath, "/dav/movies/Movie.mkv")
        XCTAssertFalse(entry.isCollection)
        XCTAssertEqual(entry.contentLength, 1_048_576)
        XCTAssertEqual(entry.etag?.rawValue, "\"abc123\"")
    }

    func testPropertiesThrowsWhenServerReturnsNoEntry() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let root = WebDAVRoot(origin: origin, normalizedPath: "/dav")
        let url = URL(string: "https://nas.example.com/dav/missing.mkv")!
        // A multistatus whose only response is a 404 propstat → no usable entry.
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/other.mkv</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        StubURLProtocol.queue(StubResponse(statusCode: 207, body: Data(xml.utf8)), for: url)

        do {
            _ = try await makeClient().properties(
                root: root,
                path: "/dav/missing.mkv",
                sessionKey: try makeKey(origin: origin),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected malformedMultistatus")
        } catch let error as TransportError {
            guard case .malformedMultistatus = error else {
                return XCTFail("expected malformedMultistatus, got \(error)")
            }
        }
    }

    // MARK: - bounded GET

    func testGetBoundedReturnsBodyUnderCap() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let url = URL(string: "https://nas.example.com/dav/movie.nfo")!
        let payload = Data("<movie><title>x</title></movie>".utf8)
        StubURLProtocol.queue(
            StubResponse(statusCode: 200, headers: ["Content-Length": "\(payload.count)"], body: payload),
            for: url
        )

        let data = try await makeClient().getBounded(
            root: makeRoot(origin: origin),
            url: url,
            maxBytes: 4096,
            sessionKey: try makeKey(origin: origin),
            credential: .anonymous,
            trustPolicy: .system
        )
        XCTAssertEqual(data, payload)
    }

    func testGetBoundedRejectsOversizedBody() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let url = URL(string: "https://nas.example.com/dav/big.bin")!
        let payload = Data(repeating: 0x41, count: 4096)
        StubURLProtocol.queue(
            StubResponse(statusCode: 200, headers: ["Content-Length": "\(payload.count)"], body: payload),
            for: url
        )

        do {
            _ = try await makeClient().getBounded(
                root: makeRoot(origin: origin),
                url: url,
                maxBytes: 1024,
                sessionKey: try makeKey(origin: origin),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected responseTooLarge")
        } catch let error as TransportError {
            guard case .responseTooLarge = error else {
                return XCTFail("expected responseTooLarge, got \(error)")
            }
        }
    }

    func testGetBoundedRejectsNon200() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let url = URL(string: "https://nas.example.com/dav/nope.nfo")!
        StubURLProtocol.queue(StubResponse(statusCode: 500), for: url)

        do {
            _ = try await makeClient().getBounded(
                root: makeRoot(origin: origin),
                url: url,
                maxBytes: 4096,
                sessionKey: try makeKey(origin: origin),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected protocolError")
        } catch let error as TransportError {
            guard case .protocolError(let status, _) = error, status == 500 else {
                return XCTFail("expected protocolError(500), got \(error)")
            }
        }
    }

    // MARK: - bearer Authorization value (B1 regression lock)

    func testBearerCredentialSendsExactAuthorizationHeader() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let url = URL(string: "https://nas.example.com/dav/movie.nfo")!
        let token = "test-token-123"
        let observedAuth = LockedValue<String?>(nil)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 200,
                headers: ["Content-Length": "2"],
                body: Data("ok".utf8),
                onRequest: { observedAuth.set($0.value(forHTTPHeaderField: "Authorization")) }
            ),
            for: url
        )

        _ = try await makeClient().getBounded(
            root: makeRoot(origin: origin),
            url: url,
            maxBytes: 4096,
            sessionKey: try makeKey(origin: origin),
            credential: .bearerToken(token),
            trustPolicy: .system
        )
        XCTAssertEqual(observedAuth.get(), "Bearer \(token)")
    }

    // MARK: - transient status, forbidden, and off-root redirect (review fixes)

    func testProbeServerErrorSurfacesAsProtocolErrorNotRangeUnsupported() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let url = URL(string: "https://nas.example.com/dav/movie.mkv")!
        StubURLProtocol.queue(StubResponse(statusCode: 503), for: url)
        do {
            _ = try await makeClient().probeRange(
                root: makeRoot(origin: origin),
                url: url,
                sessionKey: try makeKey(origin: origin, role: .playback),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected protocolError")
        } catch let error as TransportError {
            // Must NOT be .rangeNotSupported — a transient 5xx has to stay
            // classifiable as a (reconnectable) server error.
            guard case .protocolError(let status, _) = error, status == 503 else {
                return XCTFail("expected protocolError(503), got \(error)")
            }
        }
    }

    func testForbiddenGetSurfacesAsProtocolErrorNotAuthFailure() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let url = URL(string: "https://nas.example.com/dav/forbidden.nfo")!
        StubURLProtocol.queue(StubResponse(statusCode: 403), for: url)
        do {
            _ = try await makeClient().getBounded(
                root: makeRoot(origin: origin),
                url: url,
                maxBytes: 4096,
                sessionKey: try makeKey(origin: origin),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected protocolError")
        } catch let error as TransportError {
            guard case .protocolError(let status, _) = error, status == 403 else {
                return XCTFail("expected protocolError(403), got \(error)")
            }
        }
    }

    func testProbeRejectsSameOriginRedirectOutsideRoot() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let inRoot = URL(string: "https://nas.example.com/dav/movie.mkv")!
        let offRoot = URL(string: "https://nas.example.com/other/movie.mkv")!
        StubURLProtocol.queue(redirect: StubRedirect(location: offRoot), for: inRoot)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-0/1000"],
                body: Data([0x00])
            ),
            for: offRoot
        )
        do {
            _ = try await makeClient().probeRange(
                root: makeRoot(origin: origin),
                url: inRoot,
                sessionKey: try makeKey(origin: origin, role: .playback),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected pathEscapesRoot")
        } catch let error as TransportError {
            guard case .pathEscapesRoot = error else {
                return XCTFail("expected pathEscapesRoot, got \(error)")
            }
        }
    }
}
