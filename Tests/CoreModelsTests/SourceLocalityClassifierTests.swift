import XCTest
@testable import CoreModels

/// Tests for ``SourceLocalityClassifier`` — the provider-agnostic host → locality
/// classification that drives local-first cross-server playback selection.
///
/// The behaviour these lock in is the user's core complaint: a sister's server
/// reached over **Tailscale** must classify as `.remote` so a same-LAN copy of a
/// merged title always wins, and a genuine home-LAN box (IPv4 RFC1918 or IPv6
/// ULA/link-local) must classify as `.local`.
final class SourceLocalityClassifierTests: XCTestCase {

    // MARK: - IPv4

    func testLoopbackAndRFC1918AreLocal() {
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "localhost"), .local)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "127.0.0.1"), .local)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "192.168.1.50"), .local)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "10.0.0.9"), .local)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "172.20.3.4"), .local)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "169.254.4.4"), .local)
    }

    func testTailscaleCGNATv4IsRemote() {
        // 100.64.0.0/10 is Tailscale's CGNAT tunnel range — never LAN.
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "100.64.0.1"), .remote)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "100.100.100.100"), .remote)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "100.127.255.254"), .remote)
    }

    func testPublicIPv4IsRemote() {
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "8.8.8.8"), .remote)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "203.0.113.7"), .remote)
    }

    func testPlexDirectEmbeddedIPClassifiesByThatIP() {
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "192-168-1-5.abcdef.plex.direct"), .local)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "100-64-0-1.abcdef.plex.direct"), .remote)
    }

    // MARK: - Hostnames

    func testMDNSLocalSuffixIsLocal() {
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "media-box.local"), .local)
    }

    func testTailscaleMagicDNSIsRemote() {
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "sister-server.tail1234.ts.net"), .remote)
    }

    func testUnclassifiableHostnameIsUnknown() {
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "plex.example.com"), .unknown)
    }

    // MARK: - IPv6

    func testIPv6LoopbackIsLocal() {
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "::1"), .local)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "[::1]"), .local)
    }

    func testIPv6LinkLocalAndULAAreLocal() {
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "fe80::1"), .local)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "fe80::1%en0"), .local) // zone id
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "[fe80::1]"), .local)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "fd00::1234"), .local)  // ULA
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "fc00::abcd"), .local)  // ULA
    }

    func testTailscaleIPv6ULAIsRemote() {
        // Tailscale hands out addresses in fd7a:115c:a1e0::/48 — ULA-shaped but the
        // tunnel, so it must beat the generic ULA=local rule.
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "fd7a:115c:a1e0::1"), .remote)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "[fd7a:115c:a1e0:ab12::5]"), .remote)
    }

    func testGlobalIPv6IsRemote() {
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "2001:4860:4860::8888"), .remote)
        XCTAssertEqual(SourceLocalityClassifier.classify(host: "2606:4700:4700::1111"), .remote)
    }

    // MARK: - URL convenience

    func testClassifyURLUsesHost() {
        XCTAssertEqual(SourceLocalityClassifier.classify(url: URL(string: "https://192.168.1.5:8096")), .local)
        XCTAssertEqual(SourceLocalityClassifier.classify(url: URL(string: "https://100.72.1.9:8096")), .remote)
        XCTAssertEqual(SourceLocalityClassifier.classify(url: URL(string: "http://[fe80::1]:32400")), .local)
        XCTAssertEqual(SourceLocalityClassifier.classify(url: nil), .unknown)
    }
}
