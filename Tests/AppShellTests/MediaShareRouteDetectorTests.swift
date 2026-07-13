#if canImport(SwiftUI)
import Foundation
@testable import AppShell
import XCTest

final class MediaShareRouteDetectorTests: XCTestCase {
    /// `webDAVAt` = URLs whose probe returns `.webDAV`; `httpAt` = URLs that
    /// answer but are not WebDAV (`.notWebDAV`); everything else `.unreachable`.
    private func detect(
        _ address: String,
        webDAVAt: Set<String> = [],
        httpAt: Set<String> = []
    ) async -> Result<MediaShareRoute, MediaShareRouteError> {
        let probe = StubProbe(webDAVAt: webDAVAt, httpAt: httpAt)
        return await MediaShareRouteDetector(probe: probe).detect(address: address)
    }

    // MARK: - Explicit scheme

    func testExplicitSMBScheme() async {
        let route = try? await detect("smb://nas.local/Media").get()
        XCTAssertEqual(route, .smb(host: "nas.local", port: nil))
    }

    func testExplicitHTTPSSchemeRoutesToWebDAV() async {
        let route = try? await detect("https://nas.local/dav").get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "https://nas.local/dav")!, insecureHTTP: false))
    }

    func testExplicitHTTPSchemeRoutesToWebDAVInsecure() async {
        let route = try? await detect("http://nas.local/dav").get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "http://nas.local/dav")!, insecureHTTP: true))
    }

    // MARK: - Port 445 -> SMB

    func testExplicit445PortRoutesToSMB() async {
        let route = try? await detect("nas.local:445").get()
        XCTAssertEqual(route, .smb(host: "nas.local", port: 445))
    }

    // MARK: - Probe-based detection (the real fix)

    func testBareHostWithNonStandardPortDetectsWebDAV() async {
        // Brandon's case: http://192.168.68.71:8384/ typed WITHOUT a scheme and
        // WITHOUT a path must still detect WebDAV via the probe.
        let route = try? await detect(
            "192.168.68.71:8384",
            webDAVAt: ["http://192.168.68.71:8384"]
        ).get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "http://192.168.68.71:8384")!, insecureHTTP: true))
    }

    func testBareHostPrefersHTTPSWebDAV() async {
        let route = try? await detect(
            "nas.local",
            webDAVAt: ["https://nas.local", "http://nas.local"]
        ).get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "https://nas.local")!, insecureHTTP: false))
    }

    func testBareHostWithPathDetectsWebDAV() async {
        let route = try? await detect(
            "nas.local/dav",
            webDAVAt: ["https://nas.local/dav"]
        ).get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "https://nas.local/dav")!, insecureHTTP: false))
    }

    func testBareHostThatIsNotWebDAVFallsBackToSMB() async {
        // A NAS whose port 80 serves a web admin page (answers, but no DAV
        // header) must NOT be mistaken for WebDAV -> falls back to SMB.
        let route = try? await detect(
            "192.168.2.1",
            httpAt: ["http://192.168.2.1", "https://192.168.2.1"]
        ).get()
        XCTAssertEqual(route, .smb(host: "192.168.2.1", port: nil))
    }

    func testBareHostUnreachableFallsBackToSMB() async {
        let route = try? await detect("192.168.2.1").get()
        XCTAssertEqual(route, .smb(host: "192.168.2.1", port: nil))
    }

    // MARK: - Invalid

    func testEmptyAddressIsInvalid() async {
        let result = await detect("   ")
        XCTAssertEqual(result, .failure(.invalidAddress))
    }

    // MARK: - Parsing

    func testSplitHandlesIPv6WithPortAndPath() {
        let (host, port, path) = MediaShareRouteDetector.split("[::1]:8443/dav", droppingScheme: nil)
        XCTAssertEqual(host, "[::1]")
        XCTAssertEqual(port, 8443)
        XCTAssertEqual(path, "/dav")
    }
}

private struct StubProbe: WebDAVReachabilityProbing {
    let webDAVAt: Set<String>
    let httpAt: Set<String>
    func probe(url: URL) async -> WebDAVProbeResult {
        let s = url.absoluteString
        if webDAVAt.contains(s) { return .webDAV }
        if httpAt.contains(s) { return .notWebDAV }
        return .unreachable
    }
}
#endif
