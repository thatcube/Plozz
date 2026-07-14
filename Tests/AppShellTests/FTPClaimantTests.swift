#if canImport(SwiftUI)
import Foundation
@testable import AppShell
import XCTest

/// Unit coverage for `FTPClaimant` (decisive routes for `ftp://`/`ftps://` and
/// port 21). The claimant is active in the shipping detector; routing through
/// the shipping detector is covered in `MediaShareRouteDetectorTests`, while
/// these tests exercise the claimant in isolation.
final class FTPClaimantTests: XCTestCase {
    private func address(
        _ raw: String,
        scheme: String? = nil,
        host: String,
        port: Int? = nil,
        path: String = ""
    ) -> ParsedShareAddress {
        ParsedShareAddress(raw: raw, scheme: scheme, host: host, port: port, path: path)
    }

    func testClaimsExplicitFTPScheme() {
        let route = FTPClaimant().decisiveRoute(for: address(
            "ftp://nas.local/pub", scheme: "ftp", host: "nas.local", path: "/pub"
        ))
        XCTAssertEqual(route, .ftp(baseURL: URL(string: "ftp://nas.local/pub")!, insecure: true))
    }

    func testClaimsExplicitFTPSSchemeAsSecure() {
        let route = FTPClaimant().decisiveRoute(for: address(
            "ftps://nas.local/pub", scheme: "ftps", host: "nas.local", path: "/pub"
        ))
        XCTAssertEqual(route, .ftp(baseURL: URL(string: "ftps://nas.local/pub")!, insecure: false))
    }

    func testClaimsWellKnownPort21WhenNoScheme() {
        let route = FTPClaimant().decisiveRoute(for: address(
            "nas.local:21", host: "nas.local", port: 21
        ))
        XCTAssertEqual(route, .ftp(baseURL: URL(string: "ftp://nas.local:21")!, insecure: true))
    }

    func testIgnoresBareHostAndOtherSchemes() {
        XCTAssertNil(FTPClaimant().decisiveRoute(for: address("nas.local", host: "nas.local")))
        XCTAssertNil(FTPClaimant().decisiveRoute(for: address(
            "smb://nas.local", scheme: "smb", host: "nas.local"
        )))
        XCTAssertNil(FTPClaimant().decisiveRoute(for: address(
            "nas.local:445", host: "nas.local", port: 445
        )))
    }

    func testDetectorBuiltWithFTPClaimantRoutesFTP() async {
        let detector = MediaShareRouteDetector(
            claimants: [FTPClaimant()],
            fallback: { .smb(host: $0.host, port: $0.port) }
        )
        let route = try? await detector.detect(address: "ftp://nas.local/pub").get()
        XCTAssertEqual(route, .ftp(baseURL: URL(string: "ftp://nas.local/pub")!, insecure: true))
    }
}
#endif
