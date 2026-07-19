import XCTest
import CoreModels
@testable import FeatureDiscoveryCore

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

    func testNormalizesBareIPAddress() {
        // Some Jellyfin builds announce a scheme-less host in `Address`; with no
        // source IP the advertised address is all we have to surface.
        let json = #"{"Address":"192.168.1.50","Id":"x","Name":"Den"}"#
        let announcement = JellyfinDiscoveryParser.parse(Data(json.utf8))
        XCTAssertEqual(announcement?.candidateURLs.first?.absoluteString, "http://192.168.1.50:8096")
    }

    func testFallsBackToEndpointAddress() {
        // When `Address` is empty/missing, use `EndpointAddress`.
        let json = #"{"Address":"","Id":"x","Name":"S","EndpointAddress":"http://10.0.0.9:8096"}"#
        let announcement = JellyfinDiscoveryParser.parse(Data(json.utf8))
        XCTAssertEqual(announcement?.candidateURLs.first?.absoluteString, "http://10.0.0.9:8096")
    }

    func testParsesReverseProxyHTTPSAddress() {
        let json = #"{"Address":"https://jelly.example.com","Id":"x","Name":"S"}"#
        let announcement = JellyfinDiscoveryParser.parse(Data(json.utf8))
        XCTAssertEqual(announcement?.candidateURLs.first?.absoluteString, "https://jelly.example.com")
    }

    func testParsesBasePathAddress() {
        let json = #"{"Address":"http://10.0.0.5:8096/jellyfin/","Id":"x","Name":"S"}"#
        let announcement = JellyfinDiscoveryParser.parse(Data(json.utf8))
        XCTAssertEqual(announcement?.candidateURLs.first?.absoluteString, "http://10.0.0.5:8096/jellyfin")
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
        XCTAssertEqual(JellyfinDiscoveryParser.probeMessage(for: .emby), "Who is EmbyServer?")
        XCTAssertEqual(JellyfinDiscoveryParser.discoveryPort, 7359)
    }

    func testParsesEmbyAnnouncementWithEmbyIdentity() {
        let json = #"{"Address":"http://192.168.1.30:8096","Id":"emby1","Name":"Emby Home"}"#
        let announcement = JellyfinDiscoveryParser.parse(Data(json.utf8), provider: .emby)

        XCTAssertEqual(announcement?.provider, .emby)
        XCTAssertEqual(announcement?.primaryServer?.provider, .emby)
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

    func testValidatesEmbyServerWithEmbyIdentity() async throws {
        let stub = StubHTTPClient()
        stub.stub(path: "/System/Info/Public", json: #"{"Id":"emby1","ServerName":"Emby Home","ProductName":"Emby Server"}"#)
        let validator = ServerValidator(provider: .emby, http: stub)

        let server = try await validator.validate(rawURL: "192.168.1.30")

        XCTAssertEqual(server.provider, .emby)
        XCTAssertEqual(server.name, "Emby Home")
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

// MARK: - View-model behavior

private final class StubDiscovery: ServerDiscovering, @unchecked Sendable {
    let servers: [MediaServer]
    init(servers: [MediaServer]) { self.servers = servers }
    func discover(timeout: TimeInterval) -> AsyncStream<MediaServer> {
        AsyncStream { continuation in
            for server in servers { continuation.yield(server) }
            continuation.finish()
        }
    }
}

private final class StubLastServerStore: LastServerStoring, @unchecked Sendable {
    var recentServers: [MediaServer]
    init(lastServer: MediaServer?) { self.recentServers = lastServer.map { [$0] } ?? [] }
}

final class ServerPickerViewModelTests: XCTestCase {
    private func server(_ id: String, _ urlString: String, _ name: String = "S") -> MediaServer {
        MediaServer(id: id, name: name, baseURL: URL(string: urlString)!, provider: .jellyfin)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async {
        let start = Date()
        while !condition() && Date().timeIntervalSince(start) < timeout {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    func testDeduplicatesDiscoveredLastServerAndMarksReachable() async {
        let last = server("srv1", "http://10.0.0.5:8096", "Den")
        let store = StubLastServerStore(lastServer: last)
        let discovery = StubDiscovery(servers: [
            server("srv1", "http://10.0.0.5:8096", "Den"),
            server("srv2", "http://10.0.0.6:8096", "Attic"),
        ])
        let stub = StubHTTPClient()
        stub.stub(path: "/System/Info/Public", json: #"{"Id":"srv1","ServerName":"Den"}"#)
        let vm = ServerPickerViewModel(
            discovery: discovery,
            validator: ServerValidator(http: stub),
            store: store
        )

        vm.startScan(timeout: 1)
        await waitUntil { vm.phase == .idle }

        XCTAssertEqual(vm.discoveredServers.map(\.id), ["srv2"], "Saved server must not be listed twice")
        XCTAssertEqual(vm.lastServerReachable, true)
    }

    @MainActor
    func testMarksSavedServerOfflineWhenUnreachableAndUndiscovered() async {
        let last = server("srv1", "http://10.0.0.5:8096", "Den")
        let store = StubLastServerStore(lastServer: last)
        let discovery = StubDiscovery(servers: [])
        let stub = StubHTTPClient()
        stub.error = .serverUnreachable
        let vm = ServerPickerViewModel(
            discovery: discovery,
            validator: ServerValidator(http: stub),
            store: store
        )

        vm.startScan(timeout: 1)
        await waitUntil { vm.lastServerReachable != nil && vm.phase == .idle }

        XCTAssertEqual(vm.lastServerReachable, false)
        XCTAssertTrue(vm.discoveredServers.isEmpty)
    }

    @MainActor
    func testDedupesServersSharingAHostWithoutIds() async {
        let store = StubLastServerStore(lastServer: nil)
        let discovery = StubDiscovery(servers: [
            server("", "http://10.0.0.7:8096"),
            server("", "http://10.0.0.7:8096"),
        ])
        let vm = ServerPickerViewModel(
            discovery: discovery,
            validator: ServerValidator(http: StubHTTPClient()),
            store: store
        )

        vm.startScan(timeout: 1)
        await waitUntil { vm.phase == .idle }

        XCTAssertEqual(vm.discoveredServers.count, 1)
    }

    @MainActor
    func testSignedInServersAreExcludedFromDiscoveredAndRecents() async {
        // A server we already have an account on should surface only in the
        // signed-in group — never duplicated under recents or discovered.
        let known = server("srv1", "http://10.0.0.5:8096", "Den")
        let store = StubLastServerStore(lastServer: known)
        let discovery = StubDiscovery(servers: [
            server("srv1", "http://10.0.0.5:8096", "Den"),
            server("srv2", "http://10.0.0.6:8096", "Attic"),
        ])
        let vm = ServerPickerViewModel(
            discovery: discovery,
            validator: ServerValidator(http: StubHTTPClient()),
            store: store
        )
        vm.setSignedInServers([SignedInServer(server: known, userNames: ["Alice", "Bob"])])

        vm.startScan(timeout: 1)
        await waitUntil { vm.phase == .idle }

        XCTAssertEqual(vm.discoveredServers.map(\.id), ["srv2"], "Signed-in server must not be listed under discovered")
        XCTAssertTrue(vm.recentServers.isEmpty, "Signed-in server must be filtered out of recents")
        XCTAssertEqual(vm.signedInServers.map(\.server.id), ["srv1"])
        XCTAssertEqual(vm.signedInServers.first?.userNames, ["Alice", "Bob"])
    }
}
