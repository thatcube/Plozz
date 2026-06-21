import XCTest
import CoreModels
@testable import FeatureDiscovery

final class JellyfinDiscoveryParserTests: XCTestCase {
    func testParsesValidAnnouncement() {
        let json = """
        {"Address":"http://192.168.1.20:8096","Id":"abc123","Name":"Living Room","EndpointAddress":null}
        """
        let server = JellyfinDiscoveryParser.parse(Data(json.utf8))
        XCTAssertEqual(server?.id, "abc123")
        XCTAssertEqual(server?.name, "Living Room")
        XCTAssertEqual(server?.baseURL.absoluteString, "http://192.168.1.20:8096")
        XCTAssertEqual(server?.provider, .jellyfin)
    }

    func testStripsTrailingSlash() {
        let json = #"{"Address":"http://10.0.0.5:8096/","Id":"x","Name":"S"}"#
        let server = JellyfinDiscoveryParser.parse(Data(json.utf8))
        XCTAssertEqual(server?.baseURL.absoluteString, "http://10.0.0.5:8096")
    }

    func testRejectsGarbage() {
        XCTAssertNil(JellyfinDiscoveryParser.parse(Data("not json".utf8)))
    }

    func testRejectsMissingAddress() {
        let json = #"{"Id":"x","Name":"S"}"#
        XCTAssertNil(JellyfinDiscoveryParser.parse(Data(json.utf8)))
    }

    func testProbeConstants() {
        XCTAssertEqual(JellyfinDiscoveryParser.probeMessage, "Who is JellyfinServer?")
        XCTAssertEqual(JellyfinDiscoveryParser.discoveryPort, 7359)
    }
}

final class ServerValidatorTests: XCTestCase {
    func testValidatesJellyfinServer() async throws {
        let stub = StubHTTPClient()
        stub.stub(path: "/System/Info/Public", json: #"{"Id":"srv1","ServerName":"My Server","Version":"10.9.0"}"#)
        let validator = ServerValidator(http: stub)

        let server = try await validator.validate(rawURL: "192.168.1.10")
        XCTAssertEqual(server.id, "srv1")
        XCTAssertEqual(server.name, "My Server")
        XCTAssertEqual(server.version, "10.9.0")
        XCTAssertEqual(server.baseURL.absoluteString, "http://192.168.1.10:8096")
    }

    func testRejectsNonJellyfinResponse() async {
        let stub = StubHTTPClient()
        stub.stub(path: "/System/Info/Public", json: #"{"unrelated":"json"}"#)
        let validator = ServerValidator(http: stub)

        await assertThrows(AppError.invalidResponse) {
            _ = try await validator.validate(rawURL: "example.com")
        }
    }

    func testInvalidURLThrows() async {
        let validator = ServerValidator(http: StubHTTPClient())
        await assertThrows(AppError.invalidResponse) {
            _ = try await validator.validate(rawURL: "   ")
        }
    }

    private func assertThrows(_ expected: AppError, _ block: () async throws -> Void) async {
        do {
            try await block()
            XCTFail("Expected to throw \(expected)")
        } catch let error as AppError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }
}
