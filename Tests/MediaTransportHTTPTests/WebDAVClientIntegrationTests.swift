import XCTest
@testable import MediaTransportHTTP

final class WebDAVClientIntegrationTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeKey(
        origin: TransportOrigin,
        accountID: String = "test-account",
        role: TransportRole = .scanner
    ) -> TransportSessionKey {
        TransportSessionKey(
            accountID: accountID,
            credentialRevision: UUID(),
            origin: origin,
            trustRevision: UUID(),
            role: role
        )
    }

    // MARK: - PROPFIND depth/headers

    func testPropfindSendsExactDepthAndIdentityEncodingHeaders() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let root = WebDAVRoot(origin: origin, normalizedPath: "/dav/movies")
        let url = URL(string: "https://nas.example.com/dav/movies")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)

        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/movies/Show/</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """

        let observedDepth = LockedValue<String?>(nil)
        let observedEncoding = LockedValue<String?>(nil)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 207,
                headers: ["Content-Type": "application/xml"],
                body: Data(xml.utf8),
                onRequest: { request in
                    observedDepth.set(request.value(forHTTPHeaderField: "Depth"))
                    observedEncoding.set(request.value(forHTTPHeaderField: "Accept-Encoding"))
                }
            ),
            for: url
        )

        let entries = try await client.listChildren(
            root: root,
            path: "/dav/movies",
            depth: .one,
            sessionKey: makeKey(origin: origin),
            credential: .anonymous,
            trustPolicy: .system
        )

        XCTAssertEqual(observedDepth.get(), "1")
        XCTAssertEqual(observedEncoding.get(), "identity")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].resolvedPath, "/dav/movies/Show/")
    }

    func testPropfindBuildsBracketedIPv6URL() async throws {
        let origin = TransportOrigin(url: URL(string: "https://[::1]:8443/")!)!
        let root = WebDAVRoot(origin: origin, normalizedPath: "/dav")
        let url = URL(string: "https://[::1]:8443/dav")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/Movie.mkv</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        StubURLProtocol.queue(StubResponse(statusCode: 207, body: Data(xml.utf8)), for: url)

        let entries = try await client.listChildren(
            root: root,
            path: "/dav",
            depth: .one,
            sessionKey: makeKey(origin: origin),
            credential: .anonymous,
            trustPolicy: .system
        )
        XCTAssertEqual(entries.map(\.resolvedPath), ["/dav/Movie.mkv"])
        XCTAssertEqual(StubURLProtocol.requests(for: url).count, 1)
    }

    func testRelativeHrefsResolveAgainstFinalRedirectURL() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let root = WebDAVRoot(origin: origin, normalizedPath: "/dav/movies")
        let originalURL = URL(string: "https://nas.example.com/dav/movies")!
        let finalURL = URL(string: "https://nas.example.com/dav/movies/")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>Child.mkv</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        StubURLProtocol.queue(redirect: StubRedirect(location: finalURL), for: originalURL)
        StubURLProtocol.queue(StubResponse(statusCode: 207, body: Data(xml.utf8)), for: finalURL)

        let entries = try await client.listChildren(
            root: root,
            path: "/dav/movies",
            depth: .one,
            sessionKey: makeKey(origin: origin),
            credential: .anonymous,
            trustPolicy: .system
        )
        XCTAssertEqual(entries.map(\.resolvedPath), ["/dav/movies/Child.mkv"])
    }

    // MARK: - Cleartext credential rejection before any request is sent

    func testCleartextPasswordCredentialRejectedBeforeAnyRequestDispatched() async throws {
        let origin = TransportOrigin(url: URL(string: "http://nas.local:8080/")!)!
        let root = WebDAVRoot(origin: origin, normalizedPath: "/dav")
        let url = URL(string: "http://nas.local:8080/dav")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)

        // Deliberately no stub queued — if a request were dispatched it
        // would get the default 404 stub fallback, but we assert on the
        // request log directly to prove zero requests ever left this call.
        do {
            _ = try await client.listChildren(
                root: root,
                path: "/dav",
                depth: .one,
                sessionKey: makeKey(origin: origin),
                credential: .password(username: "u", password: "p", policy: .automatic),
                trustPolicy: .system
            )
            XCTFail("expected cleartextCredentialRejected to be thrown")
        } catch let error as TransportError {
            guard case .cleartextCredentialRejected = error else {
                return XCTFail("expected cleartextCredentialRejected, got \(error)")
            }
        }

        XCTAssertEqual(StubURLProtocol.requests(for: url).count, 0, "no request may be dispatched before credential preflight passes")
    }

    func testCleartextBearerCredentialRejectedBeforeAnyRequestDispatched() async throws {
        let origin = TransportOrigin(url: URL(string: "http://nas.local:8080/")!)!
        let url = URL(string: "http://nas.local:8080/dav")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)

        do {
            _ = try await client.capabilities(
                url: url,
                sessionKey: makeKey(origin: origin),
                credential: .bearerToken("must-not-leak"),
                trustPolicy: .system
            )
            XCTFail("expected cleartextCredentialRejected")
        } catch let error as TransportError {
            guard case .cleartextCredentialRejected = error else {
                return XCTFail("expected cleartextCredentialRejected, got \(error)")
            }
        }
        XCTAssertEqual(StubURLProtocol.requests(for: url).count, 0)
    }

    // MARK: - Anonymous over HTTPS success path

    func testAnonymousCapabilitiesRequestSucceedsOverHTTPS() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let url = URL(string: "https://nas.example.com/dav/")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)

        StubURLProtocol.queue(
            StubResponse(statusCode: 200, headers: ["DAV": "1, 2", "Allow": "OPTIONS, GET, PROPFIND"]),
            for: url
        )

        let headers = try await client.capabilities(
            url: url,
            sessionKey: makeKey(origin: origin),
            credential: .anonymous,
            trustPolicy: .system
        )
        XCTAssertEqual(headers["dav"], "1, 2")
    }

    func testCapabilitiesMapsUnauthorizedResponseToAuthenticationFailure() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let url = URL(string: "https://nas.example.com/dav/")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)
        StubURLProtocol.queue(StubResponse(statusCode: 401), for: url)

        do {
            _ = try await client.capabilities(
                url: url,
                sessionKey: makeKey(origin: origin),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected authenticationFailed")
        } catch let error as TransportError {
            guard case .authenticationFailed = error else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }
    }

    func testPropfindResponseIsBoundedWhileDownloading() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let root = WebDAVRoot(origin: origin, normalizedPath: "/dav")
        let url = URL(string: "https://nas.example.com/dav")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)
        StubURLProtocol.queue(StubResponse(statusCode: 207, body: Data(repeating: 0x41, count: 128)), for: url)

        do {
            _ = try await client.listChildren(
                root: root,
                path: "/dav",
                depth: .one,
                sessionKey: makeKey(origin: origin),
                credential: .anonymous,
                trustPolicy: .system,
                limits: PropfindParseLimits(maxResponseBytes: 32, maxEntries: 10)
            )
            XCTFail("expected responseTooLarge")
        } catch let error as TransportError {
            XCTAssertEqual(error, .responseTooLarge(limitBytes: 32))
        }
    }

    func testUnnormalizedBrowsePathIsRejectedBeforeDispatch() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let root = WebDAVRoot(origin: origin, normalizedPath: "/dav")
        let url = URL(string: "https://nas.example.com/dav/../outside")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)

        do {
            _ = try await client.listChildren(
                root: root,
                path: "/dav/../outside",
                depth: .one,
                sessionKey: makeKey(origin: origin),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected pathEscapesRoot")
        } catch let error as TransportError {
            XCTAssertEqual(error, .pathEscapesRoot)
        }
        XCTAssertEqual(StubURLProtocol.requests(for: url).count, 0)
    }

    // MARK: - Probe + read range flow

    func testProbeThenReadRangeSendsExactHeadersAndValidates() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let url = URL(string: "https://nas.example.com/dav/movies/Show.mkv")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)

        let probeRange = LockedValue<String?>(nil)
        let probeEncoding = LockedValue<String?>(nil)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-0/1000"],
                body: Data([0x00]),
                onRequest: { request in
                    probeRange.set(request.value(forHTTPHeaderField: "Range"))
                    probeEncoding.set(request.value(forHTTPHeaderField: "Accept-Encoding"))
                }
            ),
            for: url
        )

        let probeResult = try await client.probeRange(
            url: url,
            sessionKey: makeKey(origin: origin, role: .playback),
            credential: .anonymous,
            trustPolicy: .system
        )
        XCTAssertEqual(probeRange.get(), "bytes=0-0")
        XCTAssertEqual(probeEncoding.get(), "identity")
        XCTAssertEqual(probeResult.etag.opaqueTag, "strong-1")
        XCTAssertEqual(probeResult.totalLength, 1000)
        XCTAssertEqual(probeResult.resourceURL, url)

        let readRange = LockedValue<String?>(nil)
        let readIfMatch = LockedValue<String?>(nil)
        let expectedBody = Data(repeating: 0xAB, count: 100)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 100-199/1000"],
                body: expectedBody,
                onRequest: { request in
                    readRange.set(request.value(forHTTPHeaderField: "Range"))
                    readIfMatch.set(request.value(forHTTPHeaderField: "If-Match"))
                }
            ),
            for: url
        )

        let data = try await client.readRange(
            url: url,
            start: 100,
            end: 199,
            representation: probeResult,
            sessionKey: makeKey(origin: origin, role: .playback),
            credential: .anonymous,
            trustPolicy: .system
        )
        XCTAssertEqual(readRange.get(), "bytes=100-199")
        XCTAssertEqual(readIfMatch.get(), "\"strong-1\"")
        XCTAssertEqual(data, expectedBody)
    }

    func testRangeProbeBindsFinalRedirectURL() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let originalURL = URL(string: "https://nas.example.com/dav/original.mkv")!
        let finalURL = URL(string: "https://nas.example.com/dav/final.mkv")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)
        StubURLProtocol.queue(redirect: StubRedirect(location: finalURL), for: originalURL)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-0/100"],
                body: Data([0])
            ),
            for: finalURL
        )

        let result = try await client.probeRange(
            url: originalURL,
            sessionKey: makeKey(origin: origin, role: .playback),
            credential: .anonymous,
            trustPolicy: .system
        )
        XCTAssertEqual(result.resourceURL, finalURL)
    }

    func testRangeReadRejectsURLDifferentFromProbeBeforeDispatch() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let probedURL = URL(string: "https://nas.example.com/dav/probed.mkv")!
        let differentURL = URL(string: "https://nas.example.com/dav/different.mkv")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)
        let representation = RangeProbeResult(
            etag: ETag(headerValue: "\"shared-etag\"")!,
            totalLength: 100,
            resourceURL: probedURL
        )

        do {
            _ = try await client.readRange(
                url: differentURL,
                start: 0,
                end: 9,
                representation: representation,
                sessionKey: makeKey(origin: origin, role: .playback),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected sourceChanged")
        } catch let error as TransportError {
            guard case .sourceChanged = error else {
                return XCTFail("expected sourceChanged, got \(error)")
            }
        }
        XCTAssertEqual(StubURLProtocol.requests(for: differentURL).count, 0)
    }

    func testListMapsUnauthorizedResponseToAuthenticationFailure() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let root = WebDAVRoot(origin: origin, normalizedPath: "/dav")
        let url = URL(string: "https://nas.example.com/dav")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)
        StubURLProtocol.queue(StubResponse(statusCode: 401), for: url)

        do {
            _ = try await client.listChildren(
                root: root,
                path: "/dav",
                depth: .one,
                sessionKey: makeKey(origin: origin),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected authenticationFailed")
        } catch let error as TransportError {
            guard case .authenticationFailed = error else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }
    }

    func testRangeOperationsMapUnauthorizedResponsesToAuthenticationFailure() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let probeURL = URL(string: "https://nas.example.com/dav/probe.mkv")!
        let readURL = URL(string: "https://nas.example.com/dav/read.mkv")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)
        StubURLProtocol.queue(StubResponse(statusCode: 403), for: probeURL)
        StubURLProtocol.queue(StubResponse(statusCode: 401), for: readURL)

        do {
            _ = try await client.probeRange(
                url: probeURL,
                sessionKey: makeKey(origin: origin, role: .playback),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected authenticationFailed")
        } catch let error as TransportError {
            guard case .authenticationFailed = error else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }

        do {
            _ = try await client.readRange(
                url: readURL,
                start: 0,
                end: 9,
                representation: RangeProbeResult(
                    etag: ETag(headerValue: "\"strong-1\"")!,
                    totalLength: 100,
                    resourceURL: readURL
                ),
                sessionKey: makeKey(origin: origin, role: .playback),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected authenticationFailed")
        } catch let error as TransportError {
            guard case .authenticationFailed = error else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }
    }

    func test412DuringReadMapsToSourceChanged() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let url = URL(string: "https://nas.example.com/dav/movies/Show.mkv")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)

        StubURLProtocol.queue(StubResponse(statusCode: 412), for: url)

        do {
            _ = try await client.readRange(
                url: url,
                start: 0,
                end: 99,
                representation: RangeProbeResult(
                    etag: ETag(headerValue: "\"strong-1\"")!,
                    totalLength: 1_000,
                    resourceURL: url
                ),
                sessionKey: makeKey(origin: origin, role: .playback),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected sourceChanged to be thrown")
        } catch let error as TransportError {
            guard case .sourceChanged = error else {
                return XCTFail("expected sourceChanged, got \(error)")
            }
        }

    }

    func test412WithOversizedErrorBodyStillMapsToSourceChanged() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let url = URL(string: "https://nas.example.com/dav/movies/Show.mkv")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)
        StubURLProtocol.queue(
            StubResponse(statusCode: 412, body: Data(repeating: 0x41, count: 1_024)),
            for: url
        )

        do {
            _ = try await client.readRange(
                url: url,
                start: 0,
                end: 9,
                representation: RangeProbeResult(
                    etag: ETag(headerValue: "\"strong-1\"")!,
                    totalLength: 100,
                    resourceURL: url
                ),
                sessionKey: makeKey(origin: origin, role: .playback),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected sourceChanged")
        } catch let error as TransportError {
            guard case .sourceChanged = error else {
                return XCTFail("expected sourceChanged, got \(error)")
            }
        }
    }

    // MARK: - Redirects

    func testSameOriginRedirectRetainsBearerAuthorization() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let originalURL = URL(string: "https://nas.example.com/dav/old-path/")!
        let redirectedURL = URL(string: "https://nas.example.com/dav/new-path/")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)

        StubURLProtocol.queue(redirect: StubRedirect(statusCode: 302, location: redirectedURL), for: originalURL)

        StubURLProtocol.queue(
            StubResponse(
                statusCode: 200,
                headers: ["DAV": "1"]
            ),
            for: redirectedURL
        )

        _ = try await client.capabilities(
            url: originalURL,
            sessionKey: makeKey(origin: origin),
            credential: .bearerToken("integration-test-bearer-token"),
            trustPolicy: .system
        )

        let finalAuthorization = StubURLProtocol.requests(for: redirectedURL).last?
            .value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(finalAuthorization, "Bearer integration-test-bearer-token")
    }

    func testCrossOriginRedirectIsRejectedAndNeverReachesTheNewOrigin() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let originalURL = URL(string: "https://nas.example.com/dav/")!
        let crossOriginURL = URL(string: "https://evil.example.net/dav/")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)

        StubURLProtocol.queue(redirect: StubRedirect(statusCode: 302, location: crossOriginURL), for: originalURL)
        StubURLProtocol.queue(StubResponse(statusCode: 200), for: crossOriginURL)

        do {
            _ = try await client.capabilities(
                url: originalURL,
                sessionKey: makeKey(origin: origin),
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected cross-origin redirect to be rejected")
        } catch let error as TransportError {
            guard case .crossOriginRedirectRejected = error else {
                return XCTFail("expected crossOriginRedirectRejected, got \(error)")
            }
        }

        XCTAssertEqual(StubURLProtocol.requests(for: crossOriginURL).count, 0, "a rejected cross-origin redirect must never reach the new origin")
    }

    func testRedirectFailureDoesNotPoisonTheNextTaskOnSameSession() async throws {
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let url = URL(string: "https://nas.example.com/dav/")!
        let crossOriginURL = URL(string: "https://evil.example.net/dav/")!
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)
        let key = makeKey(origin: origin)

        StubURLProtocol.queue(redirect: StubRedirect(location: crossOriginURL), for: url)
        do {
            _ = try await client.capabilities(
                url: url,
                sessionKey: key,
                credential: .anonymous,
                trustPolicy: .system
            )
            XCTFail("expected cross-origin redirect rejection")
        } catch let error as TransportError {
            guard case .crossOriginRedirectRejected = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        StubURLProtocol.queue(StubResponse(statusCode: 200, headers: ["DAV": "1"]), for: url)
        let headers = try await client.capabilities(
            url: url,
            sessionKey: key,
            credential: .anonymous,
            trustPolicy: .system
        )
        XCTAssertEqual(headers["dav"], "1")
    }
}
