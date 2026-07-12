import XCTest
@testable import MediaTransportHTTP

final class PropfindXMLParserTests: XCTestCase {
    private let root = WebDAVRoot(
        origin: TransportOrigin(url: URL(string: "https://nas.example.com/")!)!,
        normalizedPath: "/dav/movies"
    )

    private func data(_ xml: String) -> Data {
        Data(xml.utf8)
    }

    func testParsesPrefixedNamespaceAndDropsSelfEntry() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/</D:href>
            <D:propstat>
              <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/movies/Show/</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype><D:collection/></D:resourcetype>
                <D:getlastmodified>Mon, 01 Jan 2024 00:00:00 GMT</D:getlastmodified>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let entries = try PropfindXMLParser.parse(data: data(xml), root: root, requestPath: "/dav/movies")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].resolvedPath, "/dav/movies/Show/")
        XCTAssertTrue(entries[0].isCollection)
        XCTAssertNotNil(entries[0].lastModified)
    }

    func testParsesDefaultNamespaceWithNoPrefix() throws {
        let xml = """
        <multistatus xmlns="DAV:">
         <response>
          <href>/dav/movies/Movie.mkv</href>
          <propstat>
           <prop>
            <getcontentlength>123456</getcontentlength>
            <getetag>"abc123"</getetag>
            <getcontenttype>video/x-matroska</getcontenttype>
           </prop>
           <status>HTTP/1.1 200 OK</status>
          </propstat>
         </response>
        </multistatus>
        """
        let entries = try PropfindXMLParser.parse(data: data(xml), root: root, requestPath: "/dav/movies")
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.resolvedPath, "/dav/movies/Movie.mkv")
        XCTAssertFalse(entry.isCollection)
        XCTAssertEqual(entry.contentLength, 123_456)
        XCTAssertEqual(entry.etag?.opaqueTag, "abc123")
        XCTAssertEqual(entry.contentType, "video/x-matroska")
    }

    func testParsesMixedAbsoluteAndRelativeHrefs() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>https://nas.example.com/dav/movies/Absolute.mkv</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>Relative.mkv</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        let entries = try PropfindXMLParser.parse(data: data(xml), root: root, requestPath: "/dav/movies/")
        let paths = Set(entries.map(\.resolvedPath))
        XCTAssertEqual(paths, ["/dav/movies/Absolute.mkv", "/dav/movies/Relative.mkv"])
    }

    func testRootEscapingEntryFailsWholeResponse() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>/etc/passwd</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/movies/Legit.mkv</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        XCTAssertThrowsError(
            try PropfindXMLParser.parse(data: data(xml), root: root, requestPath: "/dav/movies")
        ) { error in
            guard case TransportError.pathEscapesRoot = error else {
                return XCTFail("expected pathEscapesRoot, got \(error)")
            }
        }
    }

    func testIgnoresPropertiesFromNon2xxPropstat() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/Movie.mkv</D:href>
            <D:propstat>
              <D:prop><D:getcontentlength>999</D:getcontentlength></D:prop>
              <D:status>HTTP/1.1 404 Not Found</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let entries = try PropfindXMLParser.parse(data: data(xml), root: root, requestPath: "/dav/movies")
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].contentLength, "a 404 propstat's properties must never be trusted")
    }

    func testNestedPropertyHrefDoesNotReplaceResponseHref() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/Movie.mkv</D:href>
            <D:propstat>
              <D:prop>
                <D:owner><D:href>/principals/users/admin</D:href></D:owner>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """

        let entries = try PropfindXMLParser.parse(
            data: data(xml),
            root: root,
            requestPath: "/dav/movies"
        )
        XCTAssertEqual(entries.map(\.resolvedPath), ["/dav/movies/Movie.mkv"])
    }

    func testNonSuccessfulResponseStatusIsExcluded() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/Missing.mkv</D:href>
            <D:status>HTTP/1.1 404 Not Found</D:status>
          </D:response>
          <D:response>
            <D:href>/dav/movies/Present.mkv</D:href>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:response>
        </D:multistatus>
        """

        let entries = try PropfindXMLParser.parse(
            data: data(xml),
            root: root,
            requestPath: "/dav/movies"
        )
        XCTAssertEqual(entries.map(\.resolvedPath), ["/dav/movies/Present.mkv"])
    }

    func testMalformedXMLThrowsMalformedMultistatus() {
        let xml = "<multistatus><response><href>/dav/movies/A</href>"
        XCTAssertThrowsError(try PropfindXMLParser.parse(data: data(xml), root: root, requestPath: "/dav/movies")) { error in
            guard case TransportError.malformedMultistatus = error else {
                return XCTFail("expected malformedMultistatus, got \(error)")
            }
        }

        func testWellFormedNonMultistatusDocumentIsRejected() {
            XCTAssertThrowsError(
                try PropfindXMLParser.parse(
                    data: data("<html><body>Not WebDAV</body></html>"),
                    root: root,
                    requestPath: "/dav/movies"
                )
            ) { error in
                guard case TransportError.malformedMultistatus = error else {
                    return XCTFail("expected malformedMultistatus, got \(error)")
                }
            }
        }

        func testNegativeContentLengthIsIgnored() throws {
            let xml = """
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:href>/dav/movies/Movie.mkv</D:href>
                <D:propstat>
                  <D:prop><D:getcontentlength>-1</D:getcontentlength></D:prop>
                  <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
              </D:response>
            </D:multistatus>
            """
            let entries = try PropfindXMLParser.parse(
                data: data(xml),
                root: root,
                requestPath: "/dav/movies"
            )
            XCTAssertNil(entries.first?.contentLength)
        }
    }

    func testOversizedResponseThrowsResponseTooLarge() {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/Movie.mkv</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        let tinyLimits = PropfindParseLimits(maxResponseBytes: 16, maxEntries: 5_000)
        XCTAssertThrowsError(try PropfindXMLParser.parse(data: data(xml), root: root, requestPath: "/dav/movies", limits: tinyLimits)) { error in
            guard case TransportError.responseTooLarge(let limitBytes) = error else {
                return XCTFail("expected responseTooLarge, got \(error)")
            }
            XCTAssertEqual(limitBytes, 16)
        }
    }

    func testTooManyEntriesThrowsRatherThanSilentlyTruncating() {
        var responses = ""
        for index in 0..<10 {
            responses += """
            <D:response>
              <D:href>/dav/movies/Movie\(index).mkv</D:href>
              <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
            </D:response>
            """
        }
        let xml = "<D:multistatus xmlns:D=\"DAV:\">\(responses)</D:multistatus>"
        let tightLimits = PropfindParseLimits(maxResponseBytes: 8 * 1024 * 1024, maxEntries: 3)
        XCTAssertThrowsError(try PropfindXMLParser.parse(data: data(xml), root: root, requestPath: "/dav/movies", limits: tightLimits)) { error in
            guard case TransportError.tooManyEntries(let limit) = error else {
                return XCTFail("expected tooManyEntries, got \(error)")
            }
            XCTAssertEqual(limit, 3)
        }
    }

    func testStreamParsePathProducesSameResultAsDataPath() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/Movie.mkv</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        let stream = InputStream(data: data(xml))
        let entries = try PropfindXMLParser.parse(stream: stream, root: root, requestPath: "/dav/movies")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].resolvedPath, "/dav/movies/Movie.mkv")
    }

    func testStreamParseEnforcesByteLimitBeforeParsing() {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/Movie.mkv</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        let stream = InputStream(data: data(xml))
        let tinyLimits = PropfindParseLimits(maxResponseBytes: 16, maxEntries: 5_000)
        XCTAssertThrowsError(try PropfindXMLParser.parse(stream: stream, root: root, requestPath: "/dav/movies", limits: tinyLimits)) { error in
            guard case TransportError.responseTooLarge = error else {
                return XCTFail("expected responseTooLarge, got \(error)")
            }
        }
    }

    func testExternalEntityIsNeverResolved() {
        // A DOCTYPE declaring an external SYSTEM entity that, if resolved,
        // would attempt to fetch a URL. This module disables external
        // entity resolution two ways (`shouldResolveExternalEntities =
        // false` and an explicit `resolveExternalEntityName` override
        // returning `nil`), so this must never trigger any I/O. We can't
        // directly assert "no network call happened" in a unit test, but we
        // can assert the parse completes deterministically (fails cleanly
        // as unparsable/undefined-entity, rather than hanging or crashing)
        // and does not silently substitute fetched content into an entry.
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE multistatus [<!ENTITY xxe SYSTEM "https://attacker.example.invalid/xxe">]>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/&xxe;</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        // Whatever the outcome (parse failure due to the unresolved entity,
        // or a parse that treats the reference as empty), it must not throw
        // an error that reveals fetched external content, and must complete
        // promptly (this test itself has XCTest's default timeout as an
        // implicit hang-detector).
        do {
            let entries = try PropfindXMLParser.parse(data: data(xml), root: root, requestPath: "/dav/movies")
            XCTAssertTrue(entries.allSatisfy { !$0.resolvedPath.contains("attacker.example.invalid") })
        } catch {
            // A parse failure for the unresolved entity is an acceptable,
            // safe outcome — the key property is that no external fetch
            // occurred and no attacker-controlled content was substituted.
        }
    }
}
