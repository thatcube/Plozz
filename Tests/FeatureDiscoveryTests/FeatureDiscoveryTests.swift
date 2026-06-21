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

    func testNormalizesBareIPAddress() {
        // Some Jellyfin builds announce a scheme-less host in `Address`.
        let json = #"{"Address":"192.168.1.50","Id":"x","Name":"Den"}"#
        let server = JellyfinDiscoveryParser.parse(Data(json.utf8))
        XCTAssertEqual(server?.baseURL.absoluteString, "http://192.168.1.50:8096")
    }

    func testFallsBackToEndpointAddress() {
        // When `Address` is empty/missing, use `EndpointAddress`.
        let json = #"{"Address":"","Id":"x","Name":"S","EndpointAddress":"http://10.0.0.9:8096"}"#
        let server = JellyfinDiscoveryParser.parse(Data(json.utf8))
        XCTAssertEqual(server?.baseURL.absoluteString, "http://10.0.0.9:8096")
    }

    func testParsesReverseProxyHTTPSAddress() {
        let json = #"{"Address":"https://jelly.example.com","Id":"x","Name":"S"}"#
        let server = JellyfinDiscoveryParser.parse(Data(json.utf8))
        XCTAssertEqual(server?.baseURL.absoluteString, "https://jelly.example.com")
    }

    func testParsesBasePathAddress() {
        let json = #"{"Address":"http://10.0.0.5:8096/jellyfin/","Id":"x","Name":"S"}"#
        let server = JellyfinDiscoveryParser.parse(Data(json.utf8))
        XCTAssertEqual(server?.baseURL.absoluteString, "http://10.0.0.5:8096/jellyfin")
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
    var lastServer: MediaServer?
    init(lastServer: MediaServer?) { self.lastServer = lastServer }
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
}
