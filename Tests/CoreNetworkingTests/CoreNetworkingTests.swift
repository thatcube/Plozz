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

    func testSecretQueryItemsRedacted() {
        let url = URL(string: "http://h/QuickConnect/Connect?secret=abc&Limit=5")!
        let result = PlozzLog.redact(url: url)
        XCTAssertFalse(result.contains("abc"))
        XCTAssertTrue(result.contains("Limit=5"))
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
