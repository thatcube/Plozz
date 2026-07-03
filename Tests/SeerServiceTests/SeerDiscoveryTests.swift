import XCTest
import CoreModels
import CoreNetworking
@testable import SeerService

/// Fake `HTTPClient` that branches by request **host**, not just path —
/// `SeerRecordingHTTPClient` (used by the rest of `SeerServiceTests`) matches
/// on path suffix only, which can't tell two discovery candidates apart.
private final class HostRoutedHTTPClient: HTTPClient, @unchecked Sendable {
    indirect enum Behavior {
        case json(String, status: Int = 200)
        case error(AppError)
        /// Sleeps before responding — used to prove `discover(timeout:)`
        /// actually cuts a slow/hung probe off instead of waiting on it.
        case delay(TimeInterval, then: Behavior)
    }

    private let lock = NSLock()
    private var behaviors: [String: Behavior] = [:]
    private var probes: [String] = []
    private let defaultBehavior: Behavior

    init(default defaultBehavior: Behavior = .error(.serverUnreachable)) {
        self.defaultBehavior = defaultBehavior
    }

    func stub(host: String, _ behavior: Behavior) {
        lock.lock(); defer { lock.unlock() }
        behaviors[host] = behavior
    }

    func probeCount(forHost host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return probes.filter { $0 == host }.count
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let host = baseURL.host ?? ""
        lock.lock()
        probes.append(host)
        let behavior = behaviors[host] ?? defaultBehavior
        lock.unlock()

        return try await respond(baseURL: baseURL, behavior: behavior)
    }

    private func respond(baseURL: URL, behavior: Behavior) async throws -> (Data, HTTPURLResponse) {
        switch behavior {
        case let .json(json, status):
            return (Data(json.utf8), HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case let .error(appError):
            throw appError
        case let .delay(seconds, then):
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return try await respond(baseURL: baseURL, behavior: then)
        }
    }
}

final class SeerDiscoveryTests: XCTestCase {
    /// All these tests inject `subnetHosts: { [] }` so results come only from
    /// `hostHints` — fully hermetic, no dependency on the test machine's real
    /// network interfaces.
    private func makeDiscovery(_ http: HostRoutedHTTPClient) -> SeerDiscovery {
        SeerDiscovery(http: http, port: 5055, concurrency: 4, subnetHosts: { [] })
    }

    private func collect(_ stream: AsyncStream<DiscoveredSeerServer>) async -> [DiscoveredSeerServer] {
        var results: [DiscoveredSeerServer] = []
        for await server in stream { results.append(server) }
        return results
    }

    func testValidStatusResponseYieldsServer() async {
        let http = HostRoutedHTTPClient()
        http.stub(host: "192.168.1.50", .json(#"{"version":"1.33.2"}"#))
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(hostHints: ["192.168.1.50"], timeout: 2))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.baseURL.absoluteString, "http://192.168.1.50:5055")
        XCTAssertEqual(results.first?.version, "1.33.2")
    }

    func testUnreachableHostsYieldNothing() async {
        let http = HostRoutedHTTPClient(default: .error(.serverUnreachable))
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(hostHints: ["10.0.0.1", "10.0.0.2"], timeout: 2))

        XCTAssertTrue(results.isEmpty)
    }

    func testResponseWithoutVersionIsRejected() async {
        // Guards against an unrelated device answering 200 with arbitrary
        // JSON on port 5055 — must not be mistaken for a Seerr server.
        let http = HostRoutedHTTPClient()
        http.stub(host: "10.0.0.5", .json(#"{"unrelated":true}"#))
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(hostHints: ["10.0.0.5"], timeout: 2))

        XCTAssertTrue(results.isEmpty)
    }

    func testEmptyVersionStringIsRejected() async {
        let http = HostRoutedHTTPClient()
        http.stub(host: "10.0.0.6", .json(#"{"version":""}"#))
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(hostHints: ["10.0.0.6"], timeout: 2))

        XCTAssertTrue(results.isEmpty)
    }

    func testDuplicateHintsProbedOnlyOnce() async {
        let http = HostRoutedHTTPClient()
        http.stub(host: "192.168.1.9", .json(#"{"version":"1.0.0"}"#))
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(hostHints: ["192.168.1.9", "192.168.1.9"], timeout: 2))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(http.probeCount(forHost: "192.168.1.9"), 1)
    }

    func testMixOfValidAndInvalidHintsOnlyYieldsValidOnes() async {
        let http = HostRoutedHTTPClient()
        http.stub(host: "192.168.1.10", .json(#"{"version":"1.33.2","commitTag":"abc"}"#))
        http.stub(host: "192.168.1.11", .error(.serverUnreachable))
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(hostHints: ["192.168.1.10", "192.168.1.11"], timeout: 2))

        XCTAssertEqual(results.map { $0.baseURL.host }, ["192.168.1.10"])
    }

    func testSubnetSweepCandidatesAreAlsoProbed() async {
        // hostHints is empty here — the only candidate comes from the
        // injected `subnetHosts` closure, confirming the sweep path (not just
        // hints) feeds the same probe/yield pipeline.
        let http = HostRoutedHTTPClient()
        http.stub(host: "192.168.1.77", .json(#"{"version":"1.20.0"}"#))
        let discovery = SeerDiscovery(http: http, port: 5055, concurrency: 4, subnetHosts: { ["192.168.1.77"] })

        let results = await collect(discovery.discover(timeout: 2))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.baseURL.absoluteString, "http://192.168.1.77:5055")
    }

    func testHintsDedupedAgainstSubnetSweep() async {
        let http = HostRoutedHTTPClient()
        http.stub(host: "192.168.1.9", .json(#"{"version":"1.0.0"}"#))
        let discovery = SeerDiscovery(http: http, port: 5055, concurrency: 4, subnetHosts: { ["192.168.1.9"] })

        let results = await collect(discovery.discover(hostHints: ["192.168.1.9"], timeout: 2))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(http.probeCount(forHost: "192.168.1.9"), 1)
    }

    func testNoCandidatesFinishesImmediatelyWithNoResults() async {
        let http = HostRoutedHTTPClient()
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(timeout: 2))

        XCTAssertTrue(results.isEmpty)
    }

    func testTimeoutCutsOffSlowProbes() async {
        // A host that never answers within the timeout must not be waited
        // on — `discover` should finish at `timeout`, not at the probe's own
        // (much longer) delay.
        let http = HostRoutedHTTPClient()
        http.stub(host: "10.0.0.9", .delay(5, then: .json(#"{"version":"1.0.0"}"#)))
        let discovery = makeDiscovery(http)

        let start = Date()
        let results = await collect(discovery.discover(hostHints: ["10.0.0.9"], timeout: 0.2))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(results.isEmpty)
        XCTAssertLessThan(elapsed, 2, "discover(timeout:) should cut off long before the probe's own 5s delay")
    }
}
