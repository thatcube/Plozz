import CoreModels
import Foundation
import MediaTransportCore
@testable import AppShell
import XCTest

/// Coverage for the transport-neutral routing helper that replaced the two
/// duplicated `baseURL.scheme == "smb"` checks. The endpoint's
/// `transportIdentifier` must be the account's real scheme so the resolver
/// registry routes SMB and WebDAV (http/https) to the right adapter.
final class MediaShareTransportDispatchTests: XCTestCase {
    private func server(_ urlString: String) -> MediaServer {
        MediaServer(
            id: "id",
            name: "share",
            baseURL: URL(string: urlString)!,
            provider: .mediaShare
        )
    }

    func testEndpointUsesSMBSchemeAsTransportIdentifier() throws {
        let endpoint = try MediaShareTransportDispatch.endpoint(for: server("smb://nas.local/Media/Library"))
        XCTAssertEqual(endpoint.transportIdentifier, "smb")
        XCTAssertEqual(endpoint.host, "nas.local")
        XCTAssertEqual(endpoint.rootPath, "/Media/Library")
    }

    func testEndpointUsesHTTPSchemeAsTransportIdentifier() throws {
        let endpoint = try MediaShareTransportDispatch.endpoint(for: server("http://nas.local:8080/dav/movies"))
        XCTAssertEqual(endpoint.transportIdentifier, "http")
        XCTAssertEqual(endpoint.host, "nas.local")
        XCTAssertEqual(endpoint.port, 8080)
        XCTAssertEqual(endpoint.rootPath, "/dav/movies")
    }

    func testEndpointUsesHTTPSSchemeAsTransportIdentifier() throws {
        let endpoint = try MediaShareTransportDispatch.endpoint(for: server("https://nas.example.com/dav"))
        XCTAssertEqual(endpoint.transportIdentifier, "https")
        XCTAssertEqual(endpoint.host, "nas.example.com")
        XCTAssertNil(endpoint.port)
        XCTAssertEqual(endpoint.rootPath, "/dav")
    }

    func testEndpointPreservesPercentEncodedWebDAVPath() throws {
        // A folder literally named `a%20b` is stored URL-encoded as `a%2520b`.
        // Using the decoded URL.path would double-decode it to `a b` and browse
        // the wrong directory; the endpoint must carry the percent-encoded form.
        let endpoint = try MediaShareTransportDispatch.endpoint(
            for: server("https://nas.example.com/dav/a%2520b")
        )
        XCTAssertEqual(endpoint.rootPath, "/dav/a%2520b")
    }

    func testEndpointKeepsSMBPathDecodedLiteral() throws {
        // SMB share names are literal; a space stays a space (not %20).
        let endpoint = try MediaShareTransportDispatch.endpoint(
            for: server("smb://nas.local/My%20Share")
        )
        XCTAssertEqual(endpoint.rootPath, "/My Share")
    }
}
