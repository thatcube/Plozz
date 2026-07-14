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

    func testUnknownSchemeIsInvalid() async {
        // A scheme no claimant owns must not be silently probed/guessed.
        let result = await detect("gopher://nas.local/pub")
        XCTAssertEqual(result, .failure(.invalidAddress))
    }

    func testExplicitFTPSchemeRoutesToFTP() async {
        let route = try? await detect("ftp://nas.local/pub").get()
        XCTAssertEqual(route, .ftp(baseURL: URL(string: "ftp://nas.local/pub")!, insecure: true))
        let secure = try? await detect("ftps://nas.local/pub").get()
        XCTAssertEqual(secure, .ftp(baseURL: URL(string: "ftps://nas.local/pub")!, insecure: false))
    }

    func testUppercaseSchemesAreHonored() async {
        let smb = try? await detect("SMB://nas.local/Media").get()
        XCTAssertEqual(smb, .smb(host: "nas.local", port: nil))
        let dav = try? await detect("HTTPS://nas.local/dav").get()
        XCTAssertEqual(dav, .webDAV(baseURL: URL(string: "HTTPS://nas.local/dav")!, insecureHTTP: false))
    }

    func testExplicitHTTPSchemeWith445IsStillWebDAV() async {
        // Port 445 is only decisive for SMB when NO scheme was typed.
        let route = try? await detect("http://nas.local:445/dav").get()
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "http://nas.local:445/dav")!, insecureHTTP: true))
    }

    func testForeignSchemeWith445IsInvalidNotSMB() async {
        let result = await detect("gopher://nas.local:445")
        XCTAssertEqual(result, .failure(.invalidAddress))
    }

    func testFTPWellKnownPort21RoutesToFTP() async {
        // Port 21 with no scheme is decisive for FTP.
        let route = try? await detect("nas.local:21").get()
        XCTAssertEqual(route, .ftp(baseURL: URL(string: "ftp://nas.local:21")!, insecure: true))
    }

    func testSchemeWithEmptyHostIsInvalid() async {
        let smb = await detect("smb:///dav")
        XCTAssertEqual(smb, .failure(.invalidAddress))
        let http = await detect("http:///dav")
        XCTAssertEqual(http, .failure(.invalidAddress))
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

    func testParseExtractsSchemeHostPortPath() {
        let a = MediaShareRouteDetector.parse("https://[::1]:8443/dav")
        XCTAssertEqual(a.scheme, "https")
        XCTAssertEqual(a.host, "[::1]")
        XCTAssertEqual(a.port, 8443)
        XCTAssertEqual(a.path, "/dav")
    }

    func testParseNoSchemeKeepsHostPort() {
        let a = MediaShareRouteDetector.parse("nas.local:8384")
        XCTAssertNil(a.scheme)
        XCTAssertEqual(a.host, "nas.local")
        XCTAssertEqual(a.port, 8384)
        XCTAssertEqual(a.path, "")
    }

    // MARK: - Registry is additive

    /// Proves the detector is generic over claimants: a hypothetical new
    /// transport (here a fake "NFS" that decisively owns port 2049) routes with
    /// NO change to the detector — exactly how a real NFS transport would plug
    /// in. `.smb(host:port:)` is reused only as a stand-in output.
    func testCustomClaimantExtendsDetection() async {
        let detector = MediaShareRouteDetector(
            claimants: [FakePortClaimant(port: 2049), SMBClaimant()],
            fallback: { .smb(host: $0.host, port: $0.port) }
        )
        let route = try? await detector.detect(address: "nas.local:2049").get()
        // FakePortClaimant claims 2049 first, before SMB's fallback.
        XCTAssertEqual(route, .webDAV(baseURL: URL(string: "http://claimed")!, insecureHTTP: true))
    }

    func testSplitHandlesIPv6WithPortAndPath() {
        let (host, port) = MediaShareRouteDetector.splitAuthority("[::1]:8443")
        XCTAssertEqual(host, "[::1]")
        XCTAssertEqual(port, 8443)
    }
}

private struct StubProbe: WebDAVReachabilityProbing {
    let httpServersAt: Set<String>
    func probe(url: URL) async -> WebDAVProbeResult {
        httpServersAt.contains(url.absoluteString) ? .httpServer : .unreachable
    }
}

/// A stand-in claimant that decisively owns one well-known port, used to prove
/// the detector routes to a new transport with no detector changes.
private struct FakePortClaimant: TransportClaimant {
    let port: Int
    var transportName: String { "Fake" }
    func decisiveRoute(for address: ParsedShareAddress) -> MediaShareRoute? {
        (address.scheme == nil && address.port == port)
            ? .webDAV(baseURL: URL(string: "http://claimed")!, insecureHTTP: true)
            : nil
    }
    func probe(_ address: ParsedShareAddress) async -> MediaShareRoute? { nil }
}
#endif
