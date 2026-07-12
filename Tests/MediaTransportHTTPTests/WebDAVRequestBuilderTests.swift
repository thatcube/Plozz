import XCTest
@testable import MediaTransportHTTP

final class WebDAVRequestBuilderTests: XCTestCase {
    func testOptionsRequestUsesOptionsMethod() {
        let request = WebDAVRequestBuilder.options(url: URL(string: "https://nas.example.com/dav/")!)
        XCTAssertEqual(request.httpMethod, "OPTIONS")
    }

    func testPropfindDepthZeroHeader() {
        let request = WebDAVRequestBuilder.propfind(url: URL(string: "https://nas.example.com/dav/")!, depth: .zero)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "0")
        XCTAssertEqual(request.httpMethod, "PROPFIND")
    }

    func testPropfindDepthOneHeader() {
        let request = WebDAVRequestBuilder.propfind(url: URL(string: "https://nas.example.com/dav/")!, depth: .one)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
    }

    func testPropfindNeverEncodesDepthInfinity() {
        // `PropfindDepth` only has `.zero`/`.one` cases — this is a
        // compile-time guarantee, not a runtime one, but assert the two
        // known cases produce exactly "0"/"1" and nothing else sneaks in.
        XCTAssertEqual(PropfindDepth.zero.rawValue, "0")
        XCTAssertEqual(PropfindDepth.one.rawValue, "1")
    }

    func testPropfindSendsAcceptEncodingIdentity() {
        let request = WebDAVRequestBuilder.propfind(url: URL(string: "https://nas.example.com/dav/")!, depth: .one)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    }

    func testPropfindBodyRequestsAllProp() {
        let request = WebDAVRequestBuilder.propfind(url: URL(string: "https://nas.example.com/dav/")!, depth: .one)
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("allprop"))
        XCTAssertTrue(body.contains("DAV:"))
    }
}

final class WebDAVPathPolicyTests: XCTestCase {
    func testNormalizedPathCollapsesDoubleSlashes() {
        XCTAssertEqual(WebDAVPathPolicy.normalizedPath("/dav//movies///Show"), "/dav/movies/Show")
    }

    func testNormalizedPathPreservesTrailingSlashForCollections() {
        XCTAssertEqual(WebDAVPathPolicy.normalizedPath("/dav/movies/"), "/dav/movies/")
    }

    func testNormalizedPathSkipsDotSegments() {
        XCTAssertEqual(WebDAVPathPolicy.normalizedPath("/dav/./movies/./Show"), "/dav/movies/Show")
    }

    func testNormalizedPathRejectsLiteralDotDotSegment() {
        XCTAssertNil(WebDAVPathPolicy.normalizedPath("/dav/../etc/passwd"))
    }

    func testNormalizedPathRejectsPercentEncodedDotDotSegment() {
        // "%2e%2e" decodes to ".." — must be caught post-decode, not
        // bypassable by encoding the traversal segment.
        XCTAssertNil(WebDAVPathPolicy.normalizedPath("/dav/%2e%2e/etc/passwd"))
    }

    func testNormalizedPathRejectsEncodedSeparatorTraversal() {
        XCTAssertNil(WebDAVPathPolicy.normalizedPath("/dav/movies/..%2Fsecret"))
        XCTAssertNil(WebDAVPathPolicy.normalizedPath("/dav/movies/..%5Csecret"))
    }

    func testNormalizedPathEmptyBecomesRoot() {
        XCTAssertEqual(WebDAVPathPolicy.normalizedPath(""), "/")
        XCTAssertEqual(WebDAVPathPolicy.normalizedPath("/"), "/")
    }

    func testNormalizedPathDecodesPercentExactlyOnce() {
        XCTAssertEqual(WebDAVPathPolicy.normalizedPath("/dav/100%25.mkv"), "/dav/100%.mkv")
        XCTAssertEqual(WebDAVPathPolicy.normalizedPath("/dav/What%3F.mkv"), "/dav/What?.mkv")
        XCTAssertEqual(WebDAVPathPolicy.normalizedPath("/dav/Hash%23.mkv"), "/dav/Hash#.mkv")
    }

    // MARK: - resolve(href:root:requestPath:)

    private let root = WebDAVRoot(
        origin: TransportOrigin(url: URL(string: "https://nas.example.com/")!)!,
        normalizedPath: "/dav/movies"
    )

    func testResolveAbsoluteHrefSameOrigin() {
        let resolved = try? WebDAVPathPolicy.resolve(
            href: "https://nas.example.com/dav/movies/Show/",
            root: root,
            requestPath: "/dav/movies"
        )
        XCTAssertEqual(resolved, "/dav/movies/Show/")
    }

    func testResolveAbsoluteHrefCrossOriginRejected() {
        XCTAssertThrowsError(
            try WebDAVPathPolicy.resolve(
                href: "https://evil.example.net/dav/movies/Show/",
                root: root,
                requestPath: "/dav/movies"
            )
        )
    }

    func testResolveNetworkPathHrefCrossOriginRejected() {
        XCTAssertThrowsError(
            try WebDAVPathPolicy.resolve(
                href: "//evil.example.net/dav/movies/Show/",
                root: root,
                requestPath: "/dav/movies"
            )
        )
    }

    func testResolveRootRelativeHref() {
        let resolved = try? WebDAVPathPolicy.resolve(href: "/dav/movies/Show/", root: root, requestPath: "/dav/movies")
        XCTAssertEqual(resolved, "/dav/movies/Show/")
    }

    func testResolveRelativeHref() {
        let resolved = try? WebDAVPathPolicy.resolve(href: "Show/", root: root, requestPath: "/dav/movies/")
        XCTAssertEqual(resolved, "/dav/movies/Show/")
    }

    func testResolvePercentEncodedNamesWithoutDoubleDecoding() {
        let percent = try? WebDAVPathPolicy.resolve(
            href: "100%25.mkv",
            root: root,
            requestPath: "/dav/movies/"
        )
        let question = try? WebDAVPathPolicy.resolve(
            href: "What%3F.mkv",
            root: root,
            requestPath: "/dav/movies/"
        )
        XCTAssertEqual(percent, "/dav/movies/100%.mkv")
        XCTAssertEqual(question, "/dav/movies/What?.mkv")
    }

    func testResolveRootEscapeViaAbsolutePathRejected() {
        // Same origin, but the absolute-path href points *above* the
        // configured root — must be rejected, not silently clamped.
        XCTAssertThrowsError(try WebDAVPathPolicy.resolve(href: "/etc/passwd", root: root, requestPath: "/dav/movies"))
    }

    func testResolveRootEscapeViaRelativeTraversalRejected() {
        XCTAssertThrowsError(
            try WebDAVPathPolicy.resolve(
                href: "../../etc/passwd",
                root: root,
                requestPath: "/dav/movies/Show/"
            )
        )
    }

    func testResolveSiblingOutsideRootRejected() {
        // "/dav/tv" is a real, well-formed path, but it's not under
        // "/dav/movies" — must be rejected as escaping the configured root.
        XCTAssertThrowsError(
            try WebDAVPathPolicy.resolve(
                href: "/dav/tv/Show/",
                root: root,
                requestPath: "/dav/movies"
            )
        )
    }

    func testIsSelfEntryMatchesRequestedCollection() {
        XCTAssertTrue(WebDAVPathPolicy.isSelfEntry(resolvedPath: "/dav/movies/", requestPath: "/dav/movies"))
        XCTAssertTrue(WebDAVPathPolicy.isSelfEntry(resolvedPath: "/dav/movies", requestPath: "/dav/movies/"))
    }

    func testIsSelfEntryFalseForAChild() {
        XCTAssertFalse(WebDAVPathPolicy.isSelfEntry(resolvedPath: "/dav/movies/Show/", requestPath: "/dav/movies"))
    }
}
