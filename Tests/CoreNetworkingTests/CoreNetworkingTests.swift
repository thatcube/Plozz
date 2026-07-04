import XCTest
import CoreModels
@testable import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ServerURLNormalizerTests: XCTestCase {
    func testBareIPGetsHttpAndDefaultPort() {
        let url = ServerURLNormalizer.normalize("192.168.1.5")
        XCTAssertEqual(url?.absoluteString, "http://192.168.1.5:8096")
    }

    func testBareHostGetsDefaultPort() {
        let url = ServerURLNormalizer.normalize("jelly.example.com")
        XCTAssertEqual(url?.absoluteString, "http://jelly.example.com:8096")
    }

    func testHttpsURLIsPreservedAndTrailingSlashStripped() {
        let url = ServerURLNormalizer.normalize("https://media.example.com/jf/")
        XCTAssertEqual(url?.absoluteString, "https://media.example.com/jf")
    }

    func testExplicitPortPreserved() {
        let url = ServerURLNormalizer.normalize("http://10.0.0.2:1234")
        XCTAssertEqual(url?.absoluteString, "http://10.0.0.2:1234")
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(ServerURLNormalizer.normalize("   "))
    }

    func testCustomDefaultPortForNonJellyfinServices() {
        // Overseerr/Jellyseerr's default port (5055), used by SeerConfig.
        let url = ServerURLNormalizer.normalize("192.168.68.71", defaultPort: 5055)
        XCTAssertEqual(url?.absoluteString, "http://192.168.68.71:5055")
    }

    func testNilDefaultPortLeavesBareHostPortless() {
        let url = ServerURLNormalizer.normalize("jelly.example.com", defaultPort: nil)
        XCTAssertEqual(url?.absoluteString, "http://jelly.example.com")
    }
}

final class PlozzLogRedactionTests: XCTestCase {
    func testSensitiveHeadersRedacted() {
        let redacted = PlozzLog.redact(headers: [
            "Authorization": "MediaBrowser Token=\"secret\"",
            "Accept": "application/json"
        ])
        XCTAssertEqual(redacted["Authorization"], "<redacted>")
        XCTAssertEqual(redacted["Accept"], "application/json")
    }

    func testAllProviderSensitiveHeadersRedacted() {
        // Every header that may carry a backend access token must be redacted —
        // covers Jellyfin (X-Emby-Authorization / X-MediaBrowser-Token), Plex
        // (X-Plex-Token), and the generic `Authorization` bearer, including
        // case-insensitive variants.
        let redacted = PlozzLog.redact(headers: [
            "authorization": "Bearer xyz",
            "X-Emby-Authorization": "MediaBrowser Token=\"s\"",
            "x-mediabrowser-token": "tok",
            "X-Plex-Token": "plextok",
            "Accept-Language": "en"
        ])
        XCTAssertEqual(redacted["authorization"], "<redacted>")
        XCTAssertEqual(redacted["X-Emby-Authorization"], "<redacted>")
        XCTAssertEqual(redacted["x-mediabrowser-token"], "<redacted>")
        XCTAssertEqual(redacted["X-Plex-Token"], "<redacted>")
        XCTAssertEqual(redacted["Accept-Language"], "en")
    }

    func testSecretQueryItemsRedacted() {
        let url = URL(string: "http://h/QuickConnect/Connect?secret=abc&Limit=5")!
        let result = PlozzLog.redact(url: url)
        XCTAssertFalse(result.contains("abc"))
        XCTAssertTrue(result.contains("Limit=5"))
    }

    func testAllSensitiveQueryParametersRedacted() {
        // Each provider has its own conventional name for a per-request token /
        // key in the query string. Each must be stripped to <redacted> in logs.
        let url = URL(string: "http://h/x?secret=A&api_key=B&apikey=C&token=D&X-Plex-Token=E&keep=ok")!
        let result = PlozzLog.redact(url: url)
        for leak in ["A", "B", "C", "D", "E"] {
            XCTAssertFalse(result.contains("=\(leak)"), "Expected secret value '\(leak)' to be redacted, got: \(result)")
        }
        XCTAssertTrue(result.contains("keep=ok"))
    }
}

final class EndpointRequestTests: XCTestCase {
    func testMakeRequestJoinsPathAndQueryAndHeaders() throws {
        let endpoint = Endpoint(
            method: .post,
            path: "/Users/AuthenticateWithQuickConnect",
            queryItems: [URLQueryItem(name: "UserId", value: "u1")],
            headers: ["Authorization": "token"]
        )
        let request = try URLSessionHTTPClient.makeRequest(endpoint, baseURL: URL(string: "http://host:8096/base")!)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://host:8096/base/Users/AuthenticateWithQuickConnect?UserId=u1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token")
    }

    func testJSONBodyEncodesAndSetsContentType() throws {
        struct Payload: Encodable { let Secret: String }
        let endpoint = try Endpoint(method: .post, path: "/x").jsonBody(Payload(Secret: "s"))
        XCTAssertEqual(endpoint.headers["Content-Type"], "application/json")
        XCTAssertNotNil(endpoint.body)
    }
}

final class URLErrorMappingTests: XCTestCase {
    func testTimeoutMapsToServerUnreachable() {
        XCTAssertEqual(URLSessionHTTPClient.map(URLError(.timedOut)), .serverUnreachable)
    }

    func testCancelledMapsToCancelled() {
        XCTAssertEqual(URLSessionHTTPClient.map(URLError(.cancelled)), .cancelled)
    }

    func testNotConnectedMapsToServerUnreachable() {
        XCTAssertEqual(URLSessionHTTPClient.map(URLError(.notConnectedToInternet)), .serverUnreachable)
    }
}

final class LocalSubnetScannerTests: XCTestCase {
    private func ip(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
        (a << 24) | (b << 16) | (c << 8) | d
    }

    func testSlash24SweepsAllHostsExcludingNetworkAndBroadcast() {
        let hosts = LocalSubnetScanner.hostAddresses(
            address: ip(192, 168, 1, 42),
            netmask: ip(255, 255, 255, 0)
        )
        XCTAssertEqual(hosts.count, 254)
        XCTAssertEqual(hosts.first, "192.168.1.1")
        XCTAssertEqual(hosts.last, "192.168.1.254")
        XCTAssertFalse(hosts.contains("192.168.1.0"))
        XCTAssertFalse(hosts.contains("192.168.1.255"))
    }

    func testSmallerSubnetSweepsFully() {
        // /28 = 16 addresses, 14 usable hosts (.17 - .30).
        let hosts = LocalSubnetScanner.hostAddresses(
            address: ip(192, 168, 1, 20),
            netmask: ip(255, 255, 255, 240)
        )
        XCTAssertEqual(hosts.count, 14)
        XCTAssertEqual(hosts.first, "192.168.1.17")
        XCTAssertEqual(hosts.last, "192.168.1.30")
    }

    func testLargeSubnetFallsBackToLocalSlash24() {
        // A /16 is far too large to sweep host-by-host over HTTP; falls back
        // to just the local /24 around our own address.
        let hosts = LocalSubnetScanner.hostAddresses(
            address: ip(10, 20, 30, 40),
            netmask: ip(255, 255, 0, 0),
            maxSweepHosts: 256
        )
        XCTAssertEqual(hosts.count, 254)
        XCTAssertEqual(hosts.first, "10.20.30.1")
        XCTAssertEqual(hosts.last, "10.20.30.254")
    }

    func testDefaultMaxSweepHostsIncludesExactSlash24() {
        // span for a /24 is 255 (broadcast - network); the default ceiling
        // must be >= that so a /24 always gets the full, not fallback, sweep.
        let hosts = LocalSubnetScanner.hostAddresses(
            address: ip(172, 16, 5, 5),
            netmask: ip(255, 255, 255, 0),
            maxSweepHosts: LocalSubnetScanner.defaultMaxSweepHosts
        )
        XCTAssertEqual(hosts.count, 254)
    }

    func testZeroNetmaskReturnsEmpty() {
        XCTAssertTrue(LocalSubnetScanner.hostAddresses(address: ip(1, 2, 3, 4), netmask: 0).isEmpty)
    }

    func testHostOnlyNetmaskReturnsEmpty() {
        // /32 — a single host, no sweepable range at all.
        XCTAssertTrue(LocalSubnetScanner.hostAddresses(address: ip(1, 2, 3, 4), netmask: 0xFFFF_FFFF).isEmpty)
    }
}
