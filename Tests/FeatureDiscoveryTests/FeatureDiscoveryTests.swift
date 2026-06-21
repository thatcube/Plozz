import XCTest
import CoreModels
@testable import FeatureDiscovery

final class JellyfinDiscoveryParserTests: XCTestCase {
    func testParsesValidAnnouncement() {
        let json = """
        {"Address":"http://192.168.1.20:8096","Id":"abc123","Name":"Living Room","EndpointAddress":null}
        """
        let announcement = JellyfinDiscoveryParser.parse(Data(json.utf8))
        XCTAssertEqual(announcement?.id, "abc123")
        XCTAssertEqual(announcement?.name, "Living Room")
        XCTAssertEqual(announcement?.candidateURLs.first?.absoluteString, "http://192.168.1.20:8096")
        XCTAssertEqual(announcement?.primaryServer?.provider, .jellyfin)
    }

    func testStripsTrailingSlash() {
        let json = #"{"Address":"http://10.0.0.5:8096/","Id":"x","Name":"S"}"#
        let announcement = JellyfinDiscoveryParser.parse(Data(json.utf8))
        XCTAssertEqual(announcement?.candidateURLs.first?.absoluteString, "http://10.0.0.5:8096")
    }

    func testRejectsGarbage() {
        XCTAssertNil(JellyfinDiscoveryParser.parse(Data("not json".utf8)))
    }

    func testRejectsMissingAddressWithoutSource() {
        // No payload address and no source IP → nothing reachable to surface.
        let json = #"{"Id":"x","Name":"S"}"#
        XCTAssertNil(JellyfinDiscoveryParser.parse(Data(json.utf8)))
    }

    func testPrefersSourceIPOverReportedAddress() {
        // Real-world misconfig: the reply arrives from a reachable LAN address
        // but the server advertises an address on a foreign subnet with no
        // scheme. We must prefer (and list first) the source IP.
        let json = #"{"Address":"192.168.0.5","Id":"srv","Name":"Brandon's Jellyfin"}"#
        let announcement = JellyfinDiscoveryParser.parse(Data(json.utf8), sourceIP: "192.168.68.71")
        XCTAssertEqual(announcement?.id, "srv")
        XCTAssertEqual(announcement?.name, "Brandon's Jellyfin")
        XCTAssertEqual(announcement?.candidateURLs.first?.absoluteString, "http://192.168.68.71:8096")
        XCTAssertEqual(announcement?.primaryServer?.baseURL.absoluteString, "http://192.168.68.71:8096")
        // The reported (foreign) address is still kept as a lower-priority fallback.
        XCTAssertTrue(announcement?.candidateURLs.contains(where: { $0.absoluteString == "http://192.168.0.5:8096" }) ?? false)
    }

    func testNormalizesSchemelessSourceIP() {
        let json = #"{"Id":"y","Name":"Den"}"#
        let announcement = JellyfinDiscoveryParser.parse(Data(json.utf8), sourceIP: "10.0.0.42")
        XCTAssertEqual(announcement?.candidateURLs.first?.absoluteString, "http://10.0.0.42:8096")
    }

    func testHostSwapsReportedSchemeAndPortOntoSourceIP() {
        // Server advertises https on a custom port at a foreign address. The best
        // candidate aims that scheme/port at the reachable source IP, so reverse
        // proxies / non-default ports / TLS all keep working over the LAN.
        let json = #"{"Address":"https://10.0.0.5:8920","Id":"srv","Name":"Proxy"}"#
        let announcement = JellyfinDiscoveryParser.parse(Data(json.utf8), sourceIP: "192.168.68.71")
        XCTAssertEqual(announcement?.candidateURLs.first?.absoluteString, "https://192.168.68.71:8920")
        // Default-port http on the reachable host is kept as a fallback…
        XCTAssertTrue(announcement?.candidateURLs.contains { $0.absoluteString == "http://192.168.68.71:8096" } ?? false)
        // …and the server's own advertised URL remains a last resort.
        XCTAssertTrue(announcement?.candidateURLs.contains { $0.absoluteString == "https://10.0.0.5:8920" } ?? false)
    }

    func testHostSwapsReportedPathOntoSourceIP() {
        // Reverse-proxy style published path is preserved on the reachable host.
        let json = #"{"Address":"http://media.example.com:443/jellyfin","Id":"rp","Name":"RP"}"#
        let announcement = JellyfinDiscoveryParser.parse(Data(json.utf8), sourceIP: "192.168.1.50")
        XCTAssertEqual(announcement?.candidateURLs.first?.absoluteString, "http://192.168.1.50:443/jellyfin")
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
