import XCTest
@testable import MediaTransportHTTP

final class TransportOriginTests: XCTestCase {
    func testOriginEqualityIgnoresCaseAndDefaultPort() {
        let a = TransportOrigin(url: URL(string: "https://Example.com/a")!)
        let b = TransportOrigin(url: URL(string: "https://example.com:443/b")!)
        XCTAssertEqual(a, b)
    }

    func testOriginDiffersOnScheme() {
        let http = TransportOrigin(url: URL(string: "http://example.com/a")!)
        let https = TransportOrigin(url: URL(string: "https://example.com/a")!)
        XCTAssertNotEqual(http, https)
    }

    func testOriginDiffersOnHost() {
        let a = TransportOrigin(url: URL(string: "https://a.example.com/x")!)
        let b = TransportOrigin(url: URL(string: "https://b.example.com/x")!)
        XCTAssertNotEqual(a, b)
    }

    func testOriginDiffersOnPort() {
        let a = TransportOrigin(url: URL(string: "https://example.com:8443/x")!)
        let b = TransportOrigin(url: URL(string: "https://example.com:9443/x")!)
        XCTAssertNotEqual(a, b)
    }

    func testOriginRejectsNonHTTPScheme() {
        XCTAssertNil(TransportOrigin(url: URL(string: "ftp://example.com/x")!))
    }

    func testOriginRejectsHostless() {
        XCTAssertNil(TransportOrigin(url: URL(string: "file:///etc/passwd")!))
    }

    func testOriginRejectsEmbeddedUserinfo() {
        XCTAssertNil(TransportOrigin(url: URL(string: "https://user:password@nas.example.com/dav")!))
    }

    // MARK: - Redirect policy

    func testRedirectSameOriginRetainsAuthorizationHeader() {
        var original = URLRequest(url: URL(string: "https://example.com/a")!)
        original.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let newRequest = URLRequest(url: URL(string: "https://example.com/b")!)

        guard case .follow(let sanitized) = RedirectPolicy.evaluate(original: original, newRequest: newRequest) else {
            return XCTFail("expected same-origin redirect to be followed")
        }
        XCTAssertEqual(sanitized.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testRedirectCrossHostRejected() {
        let original = URLRequest(url: URL(string: "https://example.com/a")!)
        let newRequest = URLRequest(url: URL(string: "https://evil.example.net/a")!)

        guard case .reject(let error) = RedirectPolicy.evaluate(original: original, newRequest: newRequest) else {
            return XCTFail("expected cross-host redirect to be rejected")
        }
        XCTAssertEqual(error, .crossOriginRedirectRejected(from: "https://example.com:443", to: "https://evil.example.net:443"))
    }

    func testRedirectCrossPortRejected() {
        let original = URLRequest(url: URL(string: "https://example.com:8443/a")!)
        let newRequest = URLRequest(url: URL(string: "https://example.com:9443/a")!)

        guard case .reject(let error) = RedirectPolicy.evaluate(original: original, newRequest: newRequest) else {
            return XCTFail("expected cross-port redirect to be rejected")
        }
        XCTAssertEqual(error, .crossOriginRedirectRejected(from: "https://example.com:8443", to: "https://example.com:9443"))
    }

    func testRedirectHTTPSToHTTPDowngradeRejected() {
        let original = URLRequest(url: URL(string: "https://example.com/a")!)
        let newRequest = URLRequest(url: URL(string: "http://example.com/a")!)

        guard case .reject(let error) = RedirectPolicy.evaluate(original: original, newRequest: newRequest) else {
            return XCTFail("expected downgrade redirect to be rejected")
        }
        XCTAssertEqual(error, .insecureRedirectDowngradeRejected(from: "https://example.com:443", to: "http://example.com:80"))
    }

    func testRedirectHTTPToHTTPSCrossOriginStillRejectedButNotDowngrade() {
        // Upgrading isn't "downgrade", but it's still a different origin —
        // this module requires exact-origin match to retain auth, so it's
        // still rejected, just classified as a plain cross-origin rejection.
        let original = URLRequest(url: URL(string: "http://example.com/a")!)
        let newRequest = URLRequest(url: URL(string: "https://example.com/a")!)

        guard case .reject(let error) = RedirectPolicy.evaluate(original: original, newRequest: newRequest) else {
            return XCTFail("expected scheme-changing redirect to be rejected")
        }
        XCTAssertEqual(error, .crossOriginRedirectRejected(from: "http://example.com:80", to: "https://example.com:443"))
    }

    func testRedactedURLDescriptionStripsUserinfoAndQuery() {
        let url = URL(string: "https://user:sekret@example.com/path?token=abc123&x=1")!
        let redacted = redactedURLDescription(url)
        XCTAssertFalse(redacted.contains("sekret"))
        XCTAssertFalse(redacted.contains("token"))
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertTrue(redacted.contains("example.com"))
        XCTAssertTrue(redacted.contains("/path"))
    }

    func testRedactedURLDescriptionStripsFragment() {
        let url = URL(string: "https://example.com/path#access_token=fragment-secret")!
        let redacted = redactedURLDescription(url)
        XCTAssertFalse(redacted.contains("access_token"))
        XCTAssertFalse(redacted.contains("fragment-secret"))
    }
}
