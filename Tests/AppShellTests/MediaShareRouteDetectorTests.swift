#if canImport(SwiftUI)
import Foundation
@testable import AppShell
import XCTest

final class MediaShareRouteDetectorTests: XCTestCase {
    private func detect(_ address: String, reachable: Set<String> = []) async -> Result<MediaShareRoute, MediaShareRouteError> {
        let probe = StubReachabilityProbe(reachable: reachable)
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

    // MARK: - Bare host → SMB

    func testBareHostRoutesToSMB() async {
        let route = try? await detect("192.168.2.1").get()
        XCTAssertEqual(route, .smb(host: "192.168.2.1", port: nil))
    }

    func testBareHostWithPortRoutesToSMB() async {
        let route = try? await detect("nas.local:1445").get()
        XCTAssertEqual(route, .smb(host: "nas.local", port: 1445))
    }

    // MARK: - Host + path → WebDAV, https preferred

    func testHostWithPathPrefersHTTPSWhenReachable() async {
        let route = try? await detect("nas.local/dav", reachable: ["https://nas.local/dav"]).get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "https://nas.local/dav")!, insecureHTTP: false))
    }

    func testHostWithPathFallsBackToHTTP() async {
        let route = try? await detect("nas.local/dav", reachable: ["http://nas.local/dav"]).get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "http://nas.local/dav")!, insecureHTTP: true))
    }

    func testHostWithPathUnreachableFails() async {
        let result = await detect("nas.local/dav", reachable: [])
        XCTAssertEqual(result, .failure(.unreachable))
    }

    func testHTTPSPreferredEvenWhenBothReachable() async {
        let route = try? await detect(
            "nas.local/dav",
            reachable: ["https://nas.local/dav", "http://nas.local/dav"]
        ).get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "https://nas.local/dav")!, insecureHTTP: false))
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

private struct StubReachabilityProbe: WebDAVReachabilityProbing {
    let reachable: Set<String>
    func reachability(of url: URL) async -> WebDAVReachability {
        reachable.contains(url.absoluteString) ? .reachable : .unreachable
    }
}
#endif
