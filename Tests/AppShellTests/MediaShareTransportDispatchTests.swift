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

    func testEndpointDefaultsEmptyPathToRoot() throws {
        let endpoint = try MediaShareTransportDispatch.endpoint(for: server("https://nas.example.com"))
        XCTAssertEqual(endpoint.rootPath, "/")
    }
}
