#if canImport(SwiftUI)
import Foundation
@testable import AppShell
import XCTest

final class MediaShareRouteDetectorTests: XCTestCase {
    /// `httpServersAt` = URLs where an HTTP server answers (any status, incl.
    /// a 401 auth challenge) — these route to WebDAV. Everything else is
    /// unreachable over HTTP and falls back to SMB.
    private func detect(
        _ address: String,
        httpServersAt: Set<String> = []
    ) async -> Result<MediaShareRoute, MediaShareRouteError> {
        let probe = StubProbe(httpServersAt: httpServersAt)
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
        // Brandon's case: an auth-gated Apache mod_dav server on a non-standard
        // port, typed WITHOUT a scheme and WITHOUT a path. Its unauthenticated
        // OPTIONS returns 401 (no DAV header) — still an HTTP server, so it must
        // route to WebDAV.
        let route = try? await detect(
            "192.168.68.71:8384",
            httpServersAt: ["http://192.168.68.71:8384"]
        ).get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "http://192.168.68.71:8384")!, insecureHTTP: true))
    }

    func testBareHostPrefersHTTPSWebDAV() async {
        let route = try? await detect(
            "nas.local",
            httpServersAt: ["https://nas.local", "http://nas.local"]
        ).get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "https://nas.local")!, insecureHTTP: false))
    }

    func testBareHostFallsBackToHTTPWhenNoHTTPS() async {
        let route = try? await detect(
            "nas.local",
            httpServersAt: ["http://nas.local"]
        ).get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "http://nas.local")!, insecureHTTP: true))
    }

    func testBareHostWithPathDetectsWebDAV() async {
        let route = try? await detect(
            "nas.local/dav",
            httpServersAt: ["https://nas.local/dav"]
        ).get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "https://nas.local/dav")!, insecureHTTP: false))
    }

    func testSMBOnlyHostFallsBackToSMB() async {
        // Nothing answers over HTTP (SMB-only NAS) -> SMB.
        let route = try? await detect("192.168.2.5").get()
        XCTAssertEqual(route, .smb(host: "192.168.2.5", port: nil))
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
    let httpServersAt: Set<String>
    func probe(url: URL) async -> WebDAVProbeResult {
        httpServersAt.contains(url.absoluteString) ? .httpServer : .unreachable
    }
}
#endif
