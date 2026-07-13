import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

// MARK: - Pure logic

final class PlexPinFlowTests: XCTestCase {
    func testPendingWhenAuthTokenNil() {
        let pin = decodePin(#"{"id":1,"code":"abcd","authToken":null}"#)
        XCTAssertEqual(PlexPinFlow.evaluate(pin: pin), .pending)
    }

    func testPendingWhenAuthTokenEmptyOrWhitespace() {
        XCTAssertEqual(PlexPinFlow.evaluate(pin: decodePin(#"{"id":1,"code":"a","authToken":""}"#)), .pending)
        XCTAssertEqual(PlexPinFlow.evaluate(pin: decodePin(#"{"id":1,"code":"a","authToken":"   "}"#)), .pending)
    }

    func testClaimedWhenAuthTokenPresent() {
        let pin = decodePin(#"{"id":1,"code":"abcd","authToken":"TOKEN123"}"#)
        XCTAssertEqual(PlexPinFlow.evaluate(pin: pin), .claimed(authToken: "TOKEN123"))
    }

    private func decodePin(_ json: String) -> PlexPinDTO {
        try! JSONDecoder.plozz.decode(PlexPinDTO.self, from: Data(json.utf8))
    }
}

final class PlexConnectionSelectorTests: XCTestCase {
    private func connections(_ json: String) -> [PlexConnectionDTO] {
        try! JSONDecoder.plozz.decode([PlexConnectionDTO].self, from: Data(json.utf8))
    }

    func testPrefersLocalNonRelayOverRemoteAndRelay() {
        let conns = connections("""
        [
          {"protocol":"https","uri":"https://relay.plex.direct:443","local":false,"relay":true},
          {"protocol":"https","uri":"https://remote.plex.direct:32400","local":false,"relay":false},
          {"protocol":"https","uri":"https://local.plex.direct:32400","local":true,"relay":false}
        ]
        """)
        XCTAssertEqual(PlexConnectionSelector.best(from: conns)?.absoluteString, "https://local.plex.direct:32400")
    }

    func testPrefersRemoteDirectOverRelay() {
        let conns = connections("""
        [
          {"protocol":"https","uri":"https://relay.plex.direct:443","local":false,"relay":true},
          {"protocol":"https","uri":"https://remote.plex.direct:32400","local":false,"relay":false}
        ]
        """)
        XCTAssertEqual(PlexConnectionSelector.best(from: conns)?.absoluteString, "https://remote.plex.direct:32400")
    }

    func testRelayUsedAsLastResort() {
        let conns = connections(#"[{"protocol":"https","uri":"https://relay.plex.direct:443","local":false,"relay":true}]"#)
        XCTAssertEqual(PlexConnectionSelector.best(from: conns)?.absoluteString, "https://relay.plex.direct:443")
    }

    func testPrefersSecureWithinSameTier() {
        let conns = connections("""
        [
          {"protocol":"http","uri":"http://local.example:32400","local":true,"relay":false},
          {"protocol":"https","uri":"https://local.plex.direct:32400","local":true,"relay":false}
        ]
        """)
        XCTAssertEqual(PlexConnectionSelector.best(from: conns)?.absoluteString, "https://local.plex.direct:32400")
    }

    func testNilWhenNoUsableConnections() {
        XCTAssertNil(PlexConnectionSelector.best(from: connections("[]")))
    }

    func testRankedReturnsAllInPreferenceOrderDeduped() {
        let conns = connections("""
        [
          {"protocol":"https","uri":"https://relay.plex.direct:443","local":false,"relay":true},
          {"protocol":"https","uri":"https://remote.plex.direct:32400","local":false,"relay":false},
          {"protocol":"https","uri":"https://local.plex.direct:32400","local":true,"relay":false},
          {"protocol":"https","uri":"https://local.plex.direct:32400","local":true,"relay":false}
        ]
        """)
        XCTAssertEqual(PlexConnectionSelector.ranked(from: conns).map(\.absoluteString), [
            "https://local.plex.direct:32400",
            "https://remote.plex.direct:32400",
            "https://relay.plex.direct:443"
        ])
    }

    func testTailscaleConnectionFlaggedLocalIsDemotedBelowRealLAN() {
        // Plex marks EVERY bound interface local=1, including a Tailscale tunnel.
        // A positive .remote classification (CGNAT 100.64/10, *.ts.net) must
        // override the flag so the real LAN address wins even when the tunnel is
        // listed first. This is the user's sister-over-Tailscale complaint.
        let conns = connections("""
        [
          {"protocol":"https","uri":"https://100-72-0-9.abcdef.plex.direct:32400","local":true,"relay":false},
          {"protocol":"https","uri":"https://192-168-1-5.abcdef.plex.direct:32400","local":true,"relay":false}
        ]
        """)
        XCTAssertEqual(
            PlexConnectionSelector.ranked(from: conns).map(\.absoluteString),
            [
                "https://192-168-1-5.abcdef.plex.direct:32400",
                "https://100-72-0-9.abcdef.plex.direct:32400"
            ]
        )
    }

    func testTailscaleMagicDNSFlaggedLocalIsDemoted() {
        let conns = connections("""
        [
          {"protocol":"https","uri":"https://server.tail1234.ts.net:32400","local":true,"relay":false},
          {"protocol":"https","uri":"https://192-168-1-5.abcdef.plex.direct:32400","local":true,"relay":false}
        ]
        """)
        XCTAssertEqual(
            PlexConnectionSelector.best(from: conns)?.absoluteString,
            "https://192-168-1-5.abcdef.plex.direct:32400"
        )
    }
}

// MARK: - Reachability-aware server resolution

final class PlexServerReachabilityTests: XCTestCase {
    /// Probe double that answers only for hosts NOT containing `unreachableHostFragment`.
    private final class HostAwareProbe: HTTPClient, @unchecked Sendable {
        let unreachableHostFragment: String
        private(set) var probedHosts: [String] = []
        init(unreachableHostFragment: String) { self.unreachableHostFragment = unreachableHostFragment }

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            let host = baseURL.host ?? ""
            probedHosts.append(host)
            if host.contains(unreachableHostFragment) {
                throw AppError.serverUnreachable
            }
            return (Data("{}".utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let resourcesJSON = """
    [
      {
        "name":"Brandoland","clientIdentifier":"srv-1","provides":"server","owned":true,"accessToken":"SRVTOKEN",
        "connections":[
          {"protocol":"https","uri":"https://172-18-0-1.hash.plex.direct:32400","local":true,"relay":false},
          {"protocol":"https","uri":"https://remote.hash.plex.direct:32400","local":false,"relay":false},
          {"protocol":"https","uri":"https://relay.plex.direct:443","local":false,"relay":true}
        ]
      }
    ]
    """

    func testSkipsUnreachableLocalDockerConnection() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/api/v2/resources", json: resourcesJSON)
        let probe = HostAwareProbe(unreachableHostFragment: "172-18-0-1")
        let client = PlexAuthClient(
            deviceProfile: PlexDeviceProfile(clientIdentifier: "dev"),
            http: http,
            probeHTTP: probe
        )

        let servers = try await client.servers(authToken: "ACCT")
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.baseURL.absoluteString, "https://remote.hash.plex.direct:32400")
        XCTAssertEqual(servers.first?.accessToken, "SRVTOKEN")
    }

    func testFallsBackToTopRankedWhenNothingReachable() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/api/v2/resources", json: resourcesJSON)
        // Nothing answers: every probe fails.
        let probe = HostAwareProbe(unreachableHostFragment: ".plex.direct")
        let client = PlexAuthClient(
            deviceProfile: PlexDeviceProfile(clientIdentifier: "dev"),
            http: http,
            probeHTTP: probe
        )

        let servers = try await client.servers(authToken: "ACCT")
        // Server still surfaces (so the UI can show "unreachable"), pinned to the
        // most-preferred candidate.
        XCTAssertEqual(servers.first?.baseURL.absoluteString, "https://172-18-0-1.hash.plex.direct:32400")
    }
}

// MARK: - Connection resolver (runtime self-heal)

final class PlexConnectionResolverTests: XCTestCase {
    /// Probe whose reachable host set can change between calls, so tests can
    /// simulate a connection going down or a server moving networks.
    private final class MutableProbe: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var reachableHosts: Set<String>
        private(set) var probeCount = 0
        init(reachable: Set<String>) { self.reachableHosts = reachable }

        func setReachable(_ hosts: Set<String>) {
            lock.lock(); reachableHosts = hosts; lock.unlock()
        }

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            lock.lock(); probeCount += 1; let ok = reachableHosts.contains(baseURL.host ?? ""); lock.unlock()
            guard ok else { throw AppError.serverUnreachable }
            return (Data("{}".utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func url(_ s: String) -> URL { URL(string: s)! }
    private let profile = PlexDeviceProfile(clientIdentifier: "dev")

    func testSingleCandidateNoRefreshSkipsProbe() async {
        let probe = MutableProbe(reachable: [])
        let resolver = PlexConnectionResolver(
            candidates: [url("https://only.host:32400")],
            deviceProfile: profile, token: "T", probe: probe, refresh: nil
        )
        let resolved = await resolver.resolved()
        XCTAssertEqual(resolved.absoluteString, "https://only.host:32400")
        XCTAssertEqual(probe.probeCount, 0, "A fixed URL must not be probed")
    }

    func testPicksReachableAndSkipsDeadDockerCandidate() async {
        let probe = MutableProbe(reachable: ["remote.host"])
        let resolver = PlexConnectionResolver(
            candidates: [url("https://172-18-0-1.host:32400"), url("https://remote.host:32400")],
            deviceProfile: profile, token: "T", probe: probe, refresh: nil
        )
        let resolved = await resolver.resolved()
        XCTAssertEqual(resolved.absoluteString, "https://remote.host:32400")
        XCTAssertEqual(resolver.current.absoluteString, "https://remote.host:32400")
    }

    func testRefreshesFromPlexTVWhenAllKnownCandidatesDead() async {
        let probe = MutableProbe(reachable: ["moved.host"])
        let resolver = PlexConnectionResolver(
            candidates: [url("https://old-dead.host:32400")],
            deviceProfile: profile, token: "T", probe: probe,
            refresh: { [self] in [url("https://moved.host:32400")] }
        )
        let resolved = await resolver.resolved()
        XCTAssertEqual(resolved.absoluteString, "https://moved.host:32400")
    }

    func testReportFailureReProbesAndHeals() async {
        let probe = MutableProbe(reachable: ["a.host"])
        let resolver = PlexConnectionResolver(
            candidates: [url("https://a.host:32400"), url("https://b.host:32400")],
            deviceProfile: profile, token: "T", probe: probe, refresh: nil
        )
        let first = await resolver.resolved()
        XCTAssertEqual(first.absoluteString, "https://a.host:32400")

        // a.host goes down, b.host comes up; report the failure and re-resolve.
        probe.setReachable(["b.host"])
        resolver.reportFailure(first)
        let healed = await resolver.resolved()
        XCTAssertEqual(healed.absoluteString, "https://b.host:32400")
    }

    func testReportFailureInvalidatesConfirmedReachabilityUntilReProbe() async {
        // r8-stale-reachability-locality: a confirmed connection that later fails
        // must revert `hasConfirmedReachableConnection` to false, so locality reads
        // as `.unknown` (not a stale `.local`) until a fresh probe re-confirms —
        // otherwise a dead LAN box keeps winning best-source selection over a
        // genuinely reachable remote twin.
        let probe = MutableProbe(reachable: ["lan.host"])
        let resolver = PlexConnectionResolver(
            candidates: [url("https://lan.host:32400"), url("https://remote.host:32400")],
            deviceProfile: profile, token: "T", probe: probe, refresh: nil
        )
        let first = await resolver.resolved()
        XCTAssertEqual(first.absoluteString, "https://lan.host:32400")
        XCTAssertTrue(resolver.hasConfirmedReachableConnection, "A probed connection is confirmed")

        // The LAN box dies. Reporting the failure clears the cache AND the
        // confidence flag — no probe has re-confirmed anything yet.
        probe.setReachable([])
        resolver.reportFailure(first)
        XCTAssertFalse(
            resolver.hasConfirmedReachableConnection,
            "A reported failure must drop confirmed reachability until a fresh probe re-confirms"
        )

        // Remote comes up; a successful re-resolve re-confirms.
        probe.setReachable(["remote.host"])
        let healed = await resolver.resolved()
        XCTAssertEqual(healed.absoluteString, "https://remote.host:32400")
        XCTAssertTrue(resolver.hasConfirmedReachableConnection, "A fresh successful probe re-confirms")
    }

    func testFailedProbeSweepInvalidatesPersistedSeedConfidence() async {
        // A persisted last-known-good seed makes `hasConfirmedReachableConnection`
        // true up front (it worked last launch). But once a full probe sweep runs
        // and even the seed does not answer, confidence must drop to false so the
        // seed's locality is no longer trusted — the server is demonstrably down.
        let probe = MutableProbe(reachable: [])   // nothing answers this session
        let resolver = PlexConnectionResolver(
            candidates: [url("https://lan.host:32400"), url("https://remote.host:32400")],
            deviceProfile: profile, token: "T", probe: probe, refresh: { [] },
            reachableSeed: url("https://lan.host:32400")
        )
        XCTAssertTrue(
            resolver.hasConfirmedReachableConnection,
            "A persisted seed is trusted before any probe disproves it"
        )
        _ = await resolver.resolved()   // full sweep finds nothing reachable
        XCTAssertFalse(
            resolver.hasConfirmedReachableConnection,
            "Once the seed itself fails its probe, its locality is no longer trusted"
        )
    }

    func testFallsBackToFirstCandidateWhenNothingReachable() async {
        let probe = MutableProbe(reachable: [])
        let resolver = PlexConnectionResolver(
            candidates: [url("https://primary.host:32400"), url("https://other.host:32400")],
            deviceProfile: profile, token: "T", probe: probe, refresh: { [] }
        )
        let resolved = await resolver.resolved()
        XCTAssertEqual(resolved.absoluteString, "https://primary.host:32400")
        // Not cached (unreachable), so a later reachable state re-resolves.
        probe.setReachable(["other.host"])
        // primary still dead; resolver should now find the reachable other.host.
        // (No reportFailure needed because an unreachable result is never cached.)
        let retry = await resolver.resolved()
        XCTAssertEqual(retry.absoluteString, "https://other.host:32400")
    }

    func testReturnsImmediatelyOnFirstSuccessWithoutWaitingForDeadProbes() async throws {
        // One reachable LAN address plus several candidates that "hang" until
        // cancelled. The resolver must return as soon as the LAN host answers,
        // never blocking on the slow ones.
        let probe = SlowProbe(fastReachable: "lan.host", slowHosts: ["dead-a.host", "dead-b.host", "dead-c.host"])
        let resolver = PlexConnectionResolver(
            candidates: [
                url("https://dead-a.host:32400"),
                url("https://lan.host:32400"),
                url("https://dead-b.host:32400"),
                url("https://dead-c.host:32400")
            ],
            deviceProfile: profile, token: "T", probe: probe, refresh: nil
        )
        let start = Date()
        let resolved = await resolver.resolved()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(resolved.absoluteString, "https://lan.host:32400")
        XCTAssertLessThan(elapsed, 1.0, "Resolution must not wait on the slow/dead probes")
    }

    func testPrivateLANProbedAndPreferredOverDockerBridge() async {
        // Both reachable; the resolver must prefer the 192.168 LAN address over
        // the 172.x Docker-bridge candidate listed first.
        let probe = MutableProbe(reachable: ["192-168-68-71.h", "172-18-0-1.h"])
        let resolver = PlexConnectionResolver(
            candidates: [url("https://172-18-0-1.h:32400"), url("https://192-168-68-71.h:32400")],
            deviceProfile: profile, token: "T", probe: probe, refresh: nil
        )
        let resolved = await resolver.resolved()
        XCTAssertEqual(resolved.absoluteString, "https://192-168-68-71.h:32400")
    }

    func testReachableSeedAndCallbackPersistChosenConnection() async {
        let probe = MutableProbe(reachable: ["good.host", "seed.host"])
        var persisted: String?
        let resolver = PlexConnectionResolver(
            candidates: [url("https://good.host:32400")],
            deviceProfile: profile, token: "T", probe: probe, refresh: nil,
            reachableSeed: url("https://seed.host:32400"),
            onReachable: { persisted = $0.absoluteString }
        )
        // Seed is prepended, so it becomes a candidate and (being reachable) wins.
        let resolved = await resolver.resolved()
        XCTAssertEqual(resolved.absoluteString, "https://seed.host:32400")
        XCTAssertEqual(persisted, "https://seed.host:32400", "Resolved connection must be persisted via onReachable")
    }

    func testPrioritizedDedupesAndOrdersLANFirst() {
        let ordered = PlexConnectionResolver.prioritized([
            url("https://45-56-108-77.h:32400"),   // public
            url("https://172-18-0-1.h:32400"),     // docker bridge
            url("https://192-168-68-71.h:32400"),  // LAN
            url("https://192-168-68-71.h:32400"),  // duplicate LAN
            url("https://relay.plex.direct:443")   // hostname
        ]).map(\.absoluteString)
        XCTAssertEqual(ordered, [
            "https://192-168-68-71.h:32400",
            "https://relay.plex.direct:443",
            "https://172-18-0-1.h:32400",
            "https://45-56-108-77.h:32400"
        ])
    }

    /// Probe where some hosts answer instantly and others suspend until the
    /// task is cancelled (simulating a dead address stuck in connect).
    private final class SlowProbe: HTTPClient, @unchecked Sendable {
        let fastReachable: String
        let slowHosts: Set<String>
        init(fastReachable: String, slowHosts: Set<String>) {
            self.fastReachable = fastReachable
            self.slowHosts = slowHosts
        }
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            let host = baseURL.host ?? ""
            if host == fastReachable {
                return (Data("{}".utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if slowHosts.contains(host) {
                try await Task.sleep(nanoseconds: 30 * 1_000_000_000) // 30s unless cancelled
                throw AppError.serverUnreachable
            }
            throw AppError.serverUnreachable
        }
    }
}

// MARK: - Provider mapping

final class PlexProviderMappingTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testLibrariesMapSectionType() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections", json: """
        {"MediaContainer":{"size":2,"Directory":[
          {"key":"1","title":"Movies","type":"movie","thumb":"/m.png"},
          {"key":"2","title":"Shows","type":"show"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let libs = try await provider.libraries()
        XCTAssertEqual(libs.map(\.title), ["Movies", "Shows"])
        XCTAssertEqual(libs.map(\.id), ["1", "2"])
        XCTAssertEqual(libs[0].kind, .movie)
        XCTAssertEqual(libs[1].kind, .series)
    }

    func testTrailersFilterToTrailerSubtype() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/101/extras", json: """
        {"MediaContainer":{"size":2,"Metadata":[
          {"ratingKey":"e1","type":"clip","subtype":"trailer","title":"Trailer"},
          {"ratingKey":"e2","type":"clip","subtype":"behindTheScenes","title":"Making Of"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let trailers = try await provider.trailers(for: "101")

        XCTAssertEqual(trailers.map(\.id), ["e1"])
        XCTAssertEqual(trailers.first?.title, "Trailer")
        XCTAssertEqual(trailers.first?.kind, .video)
    }

    func testTrailersEmptyWhenNoExtras() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/101/extras", json: """
        {"MediaContainer":{"size":0}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let trailers = try await provider.trailers(for: "101")
        XCTAssertTrue(trailers.isEmpty)
    }

    func testContinueWatchingMapsResumeFields() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/onDeck", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"101","type":"movie","title":"Blade Runner","year":1982,
           "duration":7200000,"viewOffset":1800000}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.id, "101")
        XCTAssertEqual(item.title, "Blade Runner")
        XCTAssertEqual(item.kind, .movie)
        XCTAssertEqual(item.productionYear, 1982)
        XCTAssertEqual(item.runtime, 7200)
        XCTAssertEqual(item.resumePosition, 1800)
        XCTAssertEqual(item.playedPercentage ?? 0, 0.25, accuracy: 0.001)

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/library/onDeck"))
        XCTAssertEqual(query.first(where: { $0.name == "includeGuids" })?.value, "1")
    }

    /// r6-plex-cw-recency regression: an onDeck *next* episode has no
    /// `lastViewedAt` of its own (it's unwatched), so without stamping it sorts to
    /// the bottom of a merged Continue Watching row. The provider must stamp it with
    /// its series' last-viewed date, harvested from `/library/all?type=2`, keyed by
    /// the episode's `grandparentRatingKey`.
    func testContinueWatchingStampsNextEpisodeWithSeriesRecency() async throws {
        let stub = StubHTTPClient()
        // onDeck: an unwatched next episode (no viewOffset, no lastViewedAt) whose
        // grandparent (series) ratingKey is 900.
        stub.stub(pathSuffix: "/library/onDeck", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"e2","type":"episode","title":"Episode 2","index":2,"parentIndex":1,
           "grandparentRatingKey":"900","grandparentTitle":"The Series","duration":1800000}
        ]}}
        """)
        // /library/all (type=2 shows, sorted lastViewedAt:desc) reports the series'
        // real recency.
        stub.stub(pathSuffix: "/library/all", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"900","type":"show","title":"The Series","lastViewedAt":1700000000}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.id, "e2")
        XCTAssertEqual(item.seriesID, "900")
        XCTAssertEqual(item.lastPlayedAt, Date(timeIntervalSince1970: 1_700_000_000),
                       "A next-up episode with no lastViewedAt must inherit its series' recency")

        // The recently-viewed-shows query must ask for shows (type=2) by recency.
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/library/all"))
        XCTAssertEqual(query.first(where: { $0.name == "type" })?.value, "2")
        XCTAssertEqual(query.first(where: { $0.name == "sort" })?.value, "lastViewedAt:desc")
    }

    /// An in-progress onDeck item already carries its own `lastViewedAt`; stamping
    /// must never overwrite it with a series-level date.
    func testContinueWatchingKeepsOwnTimestampOverSeriesRecency() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/onDeck", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"e5","type":"episode","title":"Episode 5","index":5,"parentIndex":1,
           "grandparentRatingKey":"900","duration":1800000,"viewOffset":600000,
           "lastViewedAt":1650000000}
        ]}}
        """)
        stub.stub(pathSuffix: "/library/all", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"900","type":"show","title":"The Series","lastViewedAt":1700000000}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(items.first?.lastPlayedAt, Date(timeIntervalSince1970: 1_650_000_000),
                       "An in-progress item's own timestamp must win over its series recency")
    }

    func testConnectionLocalityUnknownUntilReachableConfirmed() async {
        // r6-plex-unreachable-local: a Plex server advertises its own LAN address
        // even to remote clients, so an unproven most-preferred candidate can be a
        // local-LOOKING URL that is actually dead. Reporting it as `.local` would
        // wrongly win best-source selection over a genuinely reachable remote twin.
        // Locality must stay `.unknown` until reachability is confirmed.
        let key = "plex.reachable.lan-srv"
        UserDefaults.standard.removeObject(forKey: key)
        let session = UserSession(
            server: MediaServer(id: "lan-srv", name: "Home",
                                baseURL: URL(string: "https://192.168.1.50:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
        let unconfirmed = PlexProvider(session: session, http: StubHTTPClient())
        XCTAssertEqual(unconfirmed.connectionLocality, .unknown,
                       "An unproven LAN-shaped candidate must not be trusted as .local")

        // A persisted last-known-good seed IS a confirmed-reachable address, so the
        // LAN classification becomes trustworthy again.
        UserDefaults.standard.set("https://192.168.1.50:32400", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let confirmed = PlexProvider(session: session, http: StubHTTPClient())
        XCTAssertEqual(confirmed.connectionLocality, .local,
                       "A persisted reachable seed makes the LAN classification trustworthy")
    }

    func testLatestRequestsIncludeGuidsForHomeDedup() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/recentlyAdded", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"r1","type":"movie","title":"Dune","Guid":[{"id":"imdb://tt1160419"}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let latest = try await provider.latest(limit: 10)
        XCTAssertEqual(latest.map(\.id), ["r1"])
        XCTAssertEqual(latest.first?.providerIDs["Imdb"], "tt1160419")

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/library/recentlyAdded"))
        XCTAssertEqual(query.first(where: { $0.name == "includeGuids" })?.value, "1")
    }

    func testEpisodeMapsSeriesTitleAndNumbers() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/55", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"55","type":"episode","title":"Pilot",
           "grandparentTitle":"The Show","parentTitle":"Season 1",
           "index":3,"parentIndex":1,"duration":1500000,
           "grandparentThumb":"/show.png","art":"/art.png","summary":"First episode"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "55")
        XCTAssertEqual(item.kind, .episode)
        XCTAssertEqual(item.parentTitle, "The Show")
        XCTAssertEqual(item.seasonNumber, 1)
        XCTAssertEqual(item.episodeNumber, 3)
        XCTAssertEqual(item.overview, "First episode")
        XCTAssertEqual(item.subtitle, "S1 · E3")
        XCTAssertEqual(item.posterURL?.absoluteString, "https://plex.host:32400/photo/:/transcode?width=500&height=750&minSize=1&upscale=1&url=%2Fshow.png%3FX-Plex-Token%3DTOKEN&X-Plex-Token=TOKEN")
    }

    func testItemMapsTechBadgesRatingGenresAndRatings() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/77", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"77","type":"movie","title":"Dune","year":2021,
           "contentRating":"PG-13","summary":"Spice.",
           "rating":8.3,"ratingImage":"rottentomatoes://image.rating.ripe",
           "audienceRating":9.0,"audienceRatingImage":"imdb://image.rating",
           "Genre":[{"tag":"Sci-Fi"},{"tag":"Adventure"}],
           "Media":[{"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3",
             "Part":[{"id":2,"key":"/p","container":"mkv","Stream":[
               {"streamType":1,"codec":"hevc","width":3840,"height":2160,"colorTrc":"smpte2084","scanType":"interlaced"},
               {"streamType":2,"codec":"eac3","channels":8,"audioChannelLayout":"7.1","extendedDisplayTitle":"Dolby Digital+ Atmos 7.1"}
             ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "77")
        XCTAssertEqual(item.officialRating, "PG-13")
        XCTAssertEqual(item.genres, ["Sci-Fi", "Adventure"])
        // 4K + HDR10 (from smpte2084 transfer) + Dolby Atmos. Dolby badges group
        // first, so Atmos sits before the HDR10 pill.
        XCTAssertEqual(item.technicalBadges.map(\.label), ["4K", "Dolby Atmos", "HDR10"])
        XCTAssertEqual(item.mediaInfo?.video?.isInterlaced, true)
        // RT critic rendered as a percentage; IMDb audience stays 0–10.
        XCTAssertEqual(item.ratings.first(where: { $0.source == .rottenTomatoes })?.displayValue, "83%")
        XCTAssertEqual(item.ratings.first(where: { $0.source == .imdb })?.displayValue, "9")
    }

    func testItemMapsDolbyVisionFromStreamDisplayTitleWhenFlagsMissing() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/78", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"78","type":"movie","title":"DoVi Title",
           "Media":[{"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3",
             "Part":[{"id":2,"key":"/p","container":"mkv","Stream":[
               {"streamType":1,"codec":"hevc","width":3840,"height":2160,"displayTitle":"4K DoVi/HDR10 (HEVC Main 10)"},
               {"streamType":2,"codec":"eac3","channels":6,"audioChannelLayout":"5.1"}
             ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "78")
        XCTAssertEqual(item.mediaInfo?.dynamicRangeBadges.map(\.label), ["Dolby Vision", "HDR10"])
        XCTAssertFalse(item.technicalBadges.map(\.label).contains("SDR"))
    }

    func testItemMapsHDR10PlusFromTransferCharacteristics() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/79", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"79","type":"movie","title":"HDR10 Plus",
           "Media":[{"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3",
             "Part":[{"id":2,"key":"/p","container":"mkv","Stream":[
               {"streamType":1,"codec":"hevc","width":3840,"height":2160,"colorTrc":"smpte2094-40"},
               {"streamType":2,"codec":"eac3","channels":6,"audioChannelLayout":"5.1"}
             ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "79")
        XCTAssertEqual(item.mediaInfo?.dynamicRangeBadges.map(\.label), ["HDR10+"])
    }

    func testItemMapsDolbyVisionFromMediaLevelDisplayTitleWithoutStreams() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/80", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"80","type":"movie","title":"DoVi Media Level",
           "Media":[{"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3",
             "videoResolution":"4k","width":3840,"height":2160,"audioChannels":6,
             "videoStreamDisplayTitle":"4K Dolby Vision/HDR10 (HEVC Main 10)",
             "Part":[{"id":2,"key":"/p","container":"mkv"}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "80")
        XCTAssertEqual(item.mediaInfo?.dynamicRangeBadges.map(\.label), ["Dolby Vision", "HDR10"])
    }

    func testHeroBadgesPickBestMediaOverFirstLowerQualityVersion() async throws {
        // Mirrors a real title that carries a 1080p SDR companion listed FIRST and
        // the 4K Dolby Vision Atmos original second (ultrawide 3840×1600). Badging
        // Plex's `.first` would advertise "1080p · SDR" while playback selects the
        // 4K DoVi version — so the hero must badge the best Media, not the first.
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/91", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"91","type":"movie","title":"Dual Version",
           "Media":[
             {"id":10,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3","videoResolution":"1080",
               "Part":[{"id":11,"key":"/p","container":"mkv","Stream":[
                 {"streamType":1,"codec":"hevc","width":1920,"height":1080},
                 {"streamType":2,"codec":"eac3","channels":6,"audioChannelLayout":"5.1","displayTitle":"Dolby Digital Plus 5.1"}
               ]}]},
             {"id":20,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3","videoResolution":"4k",
               "Part":[{"id":21,"key":"/p","container":"mkv","Stream":[
                 {"streamType":1,"codec":"hevc","width":3840,"height":1600,"DOVIPresent":true,"DOVIProfile":8},
                 {"streamType":2,"codec":"eac3","channels":6,"audioChannelLayout":"5.1","extendedDisplayTitle":"Dolby Digital Plus + Dolby Atmos 5.1"}
               ]}]}
           ]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "91")
        let labels = item.technicalBadges.map(\.label)
        XCTAssertEqual(item.mediaInfo?.resolutionBadge?.label, "4K")
        XCTAssertTrue(item.mediaInfo?.dynamicRangeBadges.map(\.label).contains("Dolby Vision") ?? false)
        XCTAssertFalse(labels.contains("1080p"))
        XCTAssertFalse(labels.contains("SDR"))
    }

    func testItemDecodesRealPlexDolbyVisionStreamWithIntegerAndStringFlags() async throws {
        // Mirrors a REAL Plex JSON video stream for a single 4K Dolby Vision file:
        // Plex serialises the boolean-ish flags as integers (`"DOVIPresent": 1`,
        // `"selected": 1`) and the DoVi profile/level can arrive as strings. A
        // synthesised `Bool?`/`Int?` decode throws on these, discarding the whole
        // stream so the hero fell back to "1080p · SDR". With lenient scalar
        // decoding the stream survives and badges 4K · Dolby Vision · HDR10 · Atmos.
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/92", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"92","type":"movie","title":"Turbulence",
           "Media":[{"id":60392,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3",
             "videoResolution":"4k","width":3840,"height":2160,"audioChannels":6,
             "Part":[{"id":2,"key":"/p","container":"mkv","Stream":[
               {"id":242139,"streamType":1,"default":1,"selected":1,"codec":"hevc",
                "width":3840,"height":2160,"colorTrc":"smpte2084","bitDepth":10,
                "DOVIPresent":1,"DOVIBLPresent":1,"DOVIProfile":"8","DOVILevel":"6",
                "displayTitle":"4K DoVi/HDR10","extendedDisplayTitle":"4K DoVi/HDR10 (HEVC Main 10)"},
               {"id":2,"streamType":2,"selected":1,"codec":"eac3","channels":6,
                "audioChannelLayout":"5.1","extendedDisplayTitle":"Dolby Digital Plus + Dolby Atmos 5.1 (English)"}
             ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "92")
        let labels = item.technicalBadges.map(\.label)
        XCTAssertEqual(item.mediaInfo?.resolutionBadge?.label, "4K")
        XCTAssertEqual(item.mediaInfo?.dynamicRangeBadges.map(\.label), ["Dolby Vision", "HDR10"])
        XCTAssertTrue(labels.contains("Dolby Atmos"))
        XCTAssertFalse(labels.contains("1080p"))
        XCTAssertFalse(labels.contains("SDR"))
    }

    func testDolbyVisionProfile5ShowsNoHDR10Badge() async throws {
        // DoVi Profile 5 is single-layer with NO HDR10 base (DOVIBLCompatID=0). It
        // is PQ-encoded and has a base layer present, but neither implies an HDR10
        // fallback — the compat ID is the authoritative signal. Regression for the
        // bug where every P5 file showed a bogus "HDR10" badge alongside DoVi.
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/7043", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"7043","type":"movie","title":"The Batman",
           "Media":[{"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3",
             "videoResolution":"4k","width":3840,"height":2160,"audioChannels":8,
             "Part":[{"id":2,"key":"/p","container":"mkv","Stream":[
               {"id":10,"streamType":1,"default":1,"selected":1,"codec":"hevc",
                "width":3840,"height":2160,"colorTrc":"smpte2084","bitDepth":10,
                "DOVIPresent":1,"DOVIBLPresent":1,"DOVIBLCompatID":0,"DOVIProfile":5,
                "DOVIRPUPresent":1,"DOVILevel":6},
               {"id":11,"streamType":2,"selected":1,"codec":"eac3","channels":8,"audioChannelLayout":"7.1"}
             ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)
        let item = try await provider.item(id: "7043")
        XCTAssertEqual(item.mediaInfo?.dynamicRangeBadges.map(\.label), ["Dolby Vision"])
        XCTAssertFalse(item.technicalBadges.map(\.label).contains("HDR10"))
    }

    func testEpisodeAtmosDetectedFromMediaLevelAudioProfile() async throws {
        // Real-world Plex Fallout-episode shape: Atmos is signalled ONLY at the
        // Media level (`audioProfile="dolby digital plus + dolby atmos"`). The
        // per-stream audio profile/displayTitle are absent, so the previous
        // mapping dropped Atmos and badged "Dolby Digital+ 5.1". Threading the
        // Media-level audioProfile into the stream mapping must restore the
        // Dolby Atmos badge, and DoVi/HDR10 should still come from the video
        // stream's DOVI flags + smpte2084 transfer.
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/93", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"93","type":"episode","title":"The End","index":1,"parentIndex":1,
           "Media":[{"id":60393,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3",
             "videoResolution":"4k","audioChannels":6,
             "audioProfile":"dolby digital plus + dolby atmos","videoProfile":"main 10",
             "Part":[{"id":2,"key":"/p","container":"mkv","Stream":[
               {"id":1,"streamType":1,"codec":"hevc","width":3840,"height":2160,
                "DOVIBLCompatID":1,"DOVIBLPresent":1,"DOVILevel":6,"DOVIPresent":1,
                "DOVIProfile":8,"DOVIRPUPresent":1,"bitDepth":10,
                "colorPrimaries":"bt2020","colorSpace":"bt2020nc","colorTrc":"smpte2084",
                "profile":"main 10","displayTitle":"4K DoVi/HDR10",
                "extendedDisplayTitle":"4K DoVi/HDR10 (HEVC Main 10)"},
               {"id":2,"streamType":2,"codec":"eac3","channels":6,"audioChannelLayout":"5.1"}
             ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "93")
        let labels = item.technicalBadges.map(\.label)
        XCTAssertEqual(item.mediaInfo?.dynamicRangeBadges.map(\.label), ["Dolby Vision", "HDR10"])
        XCTAssertTrue(labels.contains("Dolby Atmos"),
                      "Atmos must be picked up from Media-level audioProfile, got \(labels)")
        XCTAssertFalse(labels.contains("Dolby Digital+"),
                       "Atmos supersedes Dolby Digital+ when both apply, got \(labels)")
        // Final ordering: 4K · Dolby Vision · Dolby Atmos · HDR10 (Dolby logos
        // adjacent, HDR pill after).
        XCTAssertEqual(labels, ["4K", "Dolby Vision", "Dolby Atmos", "HDR10"])
    }

    func testMediaLevelFallbackDetectsAtmosFromAudioProfile() async throws {
        // When the per-stream array is omitted (list/children endpoints), Atmos
        // must still be recovered from the Media-level audioProfile and DoVi/HDR
        // from videoStreamDisplayTitle so episode rails badge correctly.
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/94", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"94","type":"episode","title":"Ep","index":1,"parentIndex":1,
           "Media":[{"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3",
             "videoResolution":"4k","width":3840,"height":2160,"audioChannels":6,
             "audioProfile":"dolby digital plus + dolby atmos",
             "videoStreamDisplayTitle":"4K Dolby Vision/HDR10 (HEVC Main 10)",
             "Part":[{"id":2,"key":"/p","container":"mkv"}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "94")
        let labels = item.technicalBadges.map(\.label)
        XCTAssertEqual(item.mediaInfo?.dynamicRangeBadges.map(\.label), ["Dolby Vision", "HDR10"])
        XCTAssertTrue(labels.contains("Dolby Atmos"))
        XCTAssertEqual(labels, ["4K", "Dolby Vision", "Dolby Atmos", "HDR10"])
    }

    func testItemFallsBackToMediaLevelFactsWithoutStreams() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/88", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"88","type":"episode","title":"Ep","index":1,"parentIndex":1,
           "Media":[{"id":1,"container":"mkv","videoCodec":"h264","audioCodec":"eac3",
             "videoResolution":"4k","width":3840,"height":2160,"audioChannels":6,
             "Part":[{"id":2,"key":"/p","container":"mkv"}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "88")
        // No Stream array: resolution + codec + surround come from Media-level
        // facts. We deliberately do NOT assert SDR from the coarse fallback
        // because Plex's trimmed children responses often strip HDR display-
        // title hints — a wrong "SDR" pill on a real DoVi episode is worse
        // than no range pill at all. Dolby Digital+ rides the 5.1 layout as
        // its trailing detail.
        XCTAssertEqual(item.technicalBadges.map(\.label), ["4K", "Dolby Digital+"])
        XCTAssertEqual(item.technicalBadges.first(where: { $0.label == "Dolby Digital+" })?.detail, "5.1")
        XCTAssertFalse(item.technicalBadges.map(\.label).contains("SDR"))
    }

    func testMediaLevelFallbackOmitsSDRWhenHDRSignalAbsent() async throws {
        // The user-reported Fallout-on-Plex shape from a listing endpoint that
        // omits BOTH the per-Stream array AND `videoStreamDisplayTitle` — Plex
        // only emits the coarse `videoProfile="main 10"` plus the Media-level
        // `audioProfile`. We can't prove HDR from "main 10" alone, but we also
        // must not lie and say SDR; Atmos must still come through. Result:
        // "4K · Dolby Atmos" with no range pill at all.
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/95", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"95","type":"episode","title":"Ep","index":1,"parentIndex":1,
           "Media":[{"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3",
             "videoResolution":"4k","width":3840,"height":2160,"audioChannels":6,
             "videoProfile":"main 10",
             "audioProfile":"dolby digital plus + dolby atmos",
             "Part":[{"id":2,"key":"/p","container":"mkv"}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "95")
        let labels = item.technicalBadges.map(\.label)
        XCTAssertTrue(labels.contains("Dolby Atmos"),
                      "Atmos must come through media-level audioProfile, got \(labels)")
        XCTAssertFalse(labels.contains("SDR"),
                       "Coarse fallback must not assert SDR with no HDR evidence, got \(labels)")
        XCTAssertEqual(labels, ["4K", "Dolby Atmos"])
    }

    func testItemsPagePassesContainerParamsAndType() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/1/all", json: """
        {"MediaContainer":{"size":2,"totalSize":250,"offset":60,"Metadata":[
          {"ratingKey":"m1","type":"movie","title":"Alien"},
          {"ratingKey":"m2","type":"movie","title":"Aliens"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let page = try await provider.items(in: "1", kind: .movie, page: PageRequest(startIndex: 60, limit: 60))
        XCTAssertEqual(page.items.map(\.title), ["Alien", "Aliens"])
        XCTAssertEqual(page.items.first?.kind, .movie)
        XCTAssertEqual(page.startIndex, 60)
        XCTAssertEqual(page.totalCount, 250)
        XCTAssertTrue(page.hasMore)

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/library/sections/1/all"))
        XCTAssertEqual(query.first(where: { $0.name == "X-Plex-Container-Start" })?.value, "60")
        XCTAssertEqual(query.first(where: { $0.name == "X-Plex-Container-Size" })?.value, "60")
        XCTAssertEqual(query.first(where: { $0.name == "type" })?.value, "1")
        XCTAssertEqual(query.first(where: { $0.name == "includeGuids" })?.value, "1")
        // List endpoints must inline streams so movie rail cards can badge
        // DoVi/HDR/Atmos from real stream facts; the bare media-level fallback
        // can't recover HDR signal on its own. `includeElements=Stream` is the
        // verified-correct flag (`includeStreams=1` is a Plex no-op).
        XCTAssertEqual(query.first(where: { $0.name == "includeElements" })?.value, "Stream")
    }

    func testSeriesLibraryUsesShowType() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/2/all", json: #"{"MediaContainer":{"size":0,"totalSize":0,"Metadata":[]}}"#)
        let provider = PlexProvider(session: makeSession(), http: stub)

        _ = try await provider.items(in: "2", kind: .series, page: PageRequest())
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/library/sections/2/all"))
        XCTAssertEqual(query.first(where: { $0.name == "type" })?.value, "2")
        XCTAssertEqual(query.first(where: { $0.name == "includeGuids" })?.value, "1")
    }

    func testSearchIncludesGuidsAndMapsProviderIDs() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/search", json: """
        {"MediaContainer":{"size":2,"Metadata":[
          {"ratingKey":"m1","type":"movie","title":"Dune","Guid":[{"id":"imdb://tt1160419"}]},
          {"ratingKey":"s1","type":"show","title":"Dune: Prophecy","Guid":[{"id":"tmdb://225634"}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let results = try await provider.search(query: " dune ", limit: 25)

        XCTAssertEqual(results.map(\.id), ["m1", "s1"])
        XCTAssertEqual(results.map(\.kind), [.movie, .series])
        XCTAssertEqual(results[0].providerIDs["Imdb"], "tt1160419")
        XCTAssertEqual(results[1].providerIDs["Tmdb"], "225634")

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/search"))
        XCTAssertEqual(query.first(where: { $0.name == "query" })?.value, "dune")
        XCTAssertEqual(query.first(where: { $0.name == "includeGuids" })?.value, "1")
    }

    func testSearchMapsOriginalTitle() async throws {
        // Plex stores the foreign film under its English title with the original
        // recorded in `originalTitle`; the mapping must surface it for cross-server
        // discovery queries.
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/search", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"m1","type":"movie","title":"Office Turbulence","originalTitle":"Turbulencia en la oficina","Guid":[{"id":"tmdb://55555"}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let results = try await provider.search(query: "office turbulence", limit: 25)

        XCTAssertEqual(results.first?.title, "Office Turbulence")
        XCTAssertEqual(results.first?.originalTitle, "Turbulencia en la oficina",
                       "Plex originalTitle must map to MediaItem.originalTitle")
    }

    func testChildrenMapSeasons() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/9/children", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"s1","type":"season","title":"Season 1","index":1}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let children = try await provider.children(of: "9")
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0].kind, .season)
        XCTAssertEqual(children[0].id, "s1")
        // A season item must carry its own ordinal so cross-server season matching
        // (by NUMBER) works instead of collapsing to the first season.
        XCTAssertEqual(children[0].seasonNumber, 1)
        // The /children endpoint must ask Plex to inline the per-Stream array;
        // without `includeElements=Stream` Plex returns zero <Stream> elements
        // and DoVi/HDR badges silently disappear from season/episode rails.
        // (`includeStreams=1` is the common-but-wrong incantation — verified
        // no-op against a live PMS.)
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/library/metadata/9/children"))
        XCTAssertEqual(query.first(where: { $0.name == "includeElements" })?.value, "Stream")
        // /children must also inline the external Guid array so episodes/seasons
        // walked for cross-server twin resolution carry imdb/tmdb/tvdb ids.
        XCTAssertEqual(query.first(where: { $0.name == "includeGuids" })?.value, "1")
    }

    func testChildrenStreamsYieldFullDoViBadges() async throws {
        // Regression: the Fallout-on-Plex episode badge bug. Even when an
        // episode is fetched via /library/metadata/{key}/children, Plex returns
        // the per-Stream array (because we send `includeStreams=1`) so DoVi +
        // HDR10 + Atmos must all render — not just "4K · Dolby Atmos".
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/s1/children", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"e1","type":"episode","title":"The End","index":1,"parentIndex":1,
           "Media":[{"id":60393,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3",
             "videoResolution":"4k","audioChannels":6,
             "audioProfile":"dolby digital plus + dolby atmos","videoProfile":"main 10",
             "Part":[{"id":2,"key":"/p","container":"mkv","Stream":[
               {"id":1,"streamType":1,"codec":"hevc","width":3840,"height":2160,
                "DOVIBLCompatID":1,"DOVIBLPresent":1,"DOVILevel":6,"DOVIPresent":1,
                "DOVIProfile":8,"DOVIRPUPresent":1,"bitDepth":10,
                "colorPrimaries":"bt2020","colorSpace":"bt2020nc","colorTrc":"smpte2084",
                "profile":"main 10","displayTitle":"4K DoVi/HDR10",
                "extendedDisplayTitle":"4K DoVi/HDR10 (HEVC Main 10)"},
               {"id":2,"streamType":2,"codec":"eac3","channels":6,"audioChannelLayout":"5.1"}
             ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let children = try await provider.children(of: "s1")
        XCTAssertEqual(children.count, 1)
        let labels = children[0].technicalBadges.map(\.label)
        XCTAssertEqual(labels, ["4K", "Dolby Vision", "Dolby Atmos", "HDR10"],
                       "DoVi/HDR10/Atmos must all survive the /children path; got \(labels)")
    }

    func testPlaybackInfoTranscodesUnsupportedContainer() async throws {
        // An MKV part cannot be demuxed by AVFoundation, so the provider must
        // resolve a server-side HLS transcode URL rather than the raw file —
        // this is the fix for "Plex doesn't play while Jellyfin does".
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/77", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"77","type":"movie","title":"Movie","duration":3600000,"viewOffset":600000,
           "Media":[{"id":1,"container":"mkv","videoCodec":"h264","audioCodec":"ac3","Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
             {"id":10,"streamType":1,"index":0,"codec":"h264"},
             {"id":11,"streamType":2,"index":1,"codec":"ac3","language":"English","languageTag":"en","displayTitle":"English (AC3)","selected":true},
             {"id":12,"streamType":3,"index":2,"codec":"srt","language":"English",
              "displayTitle":"English (SRT)","forced":false,
              "key":"/library/streams/12/subtitle.srt"}
           ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "77")
        XCTAssertEqual(request.playSessionID, "77")
        XCTAssertEqual(request.startPosition, 600)
        XCTAssertEqual(request.audioTracks.count, 1)
        XCTAssertEqual(request.subtitleTracks.count, 1)
        guard case .some(.authenticatedHTTP(let subtitleLocator)) =
            request.subtitleTracks.first?.deliverySource else {
            return XCTFail("expected authenticated subtitle source")
        }
        XCTAssertEqual(subtitleLocator.purpose, .subtitle)
        XCTAssertEqual(
            subtitleLocator.resource.path,
            "library/streams/12/subtitle.srt"
        )
        XCTAssertEqual(
            subtitleLocator.resource.pathBase,
            .configuredBaseURL
        )
        XCTAssertFalse(String(describing: subtitleLocator).contains("TOKEN"))
        XCTAssertEqual(request.audioTracks.first?.language, "en")
        XCTAssertTrue(request.audioTracks.first?.isDefault == true)
        XCTAssertTrue(request.isTranscoding)

        guard case .authenticatedHTTP(let locator) = request.playbackSource else {
            return XCTFail("expected authenticated HTTP locator")
        }
        XCTAssertEqual(locator.provider, .plex)
        XCTAssertEqual(
            locator.resource.path,
            "/video/:/transcode/universal/start.m3u8"
        )
        XCTAssertEqual(locator.deliveryMode, .serverTranscode)
        XCTAssertEqual(locator.playSessionID, "plozz-d1-77")
        XCTAssertEqual(
            locator.resource.queryItems.first { $0.name == "protocol" }?.value,
            "hls"
        )
        XCTAssertEqual(
            locator.resource.queryItems.first { $0.name == "path" }?.value,
            "/library/metadata/77"
        )
        XCTAssertFalse(
            locator.resource.queryItems.contains {
                $0.name.localizedCaseInsensitiveContains("token")
            }
        )
        let localRemux = try XCTUnwrap(request.localRemuxSource)
        guard case .authenticatedHTTP(let original) = localRemux.originalSource,
              case .authenticatedHTTP(let reference) = localRemux.referencePlaybackSource else {
            return XCTFail("expected typed local remux sources")
        }
        XCTAssertEqual(original.resource.path, "/library/parts/2/16000/file.mkv")
        XCTAssertEqual(
            original.resource.queryItems.first { $0.name == "download" }?.value,
            "1"
        )
        XCTAssertEqual(
            reference.resource.path,
            "/video/:/transcode/universal/start.m3u8"
        )
        XCTAssertEqual(
            reference.resource.queryItems.first { $0.name == "directStream" }?.value,
            "1"
        )
    }

    func testPlaybackInfoDirectPlaysSupportedContainer() async throws {
        // An MP4/h264/aac file is natively playable, so the provider should hand
        // AVPlayer the original part URL (direct play, no transcode).
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/88", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"88","type":"movie","title":"Movie","duration":3600000,
           "Media":[{"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"aac","Part":[{"id":2,"key":"/library/parts/2/16000/file name.mp4","container":"mp4","Stream":[
             {"id":10,"streamType":1,"index":0,"codec":"h264"},
             {"id":11,"streamType":2,"index":1,"codec":"aac","language":"English","languageTag":"en","selected":true}
           ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "88")
        XCTAssertFalse(request.isTranscoding)
        guard case .authenticatedHTTP(let locator) = request.playbackSource else {
            return XCTFail("expected authenticated HTTP locator")
        }
        XCTAssertEqual(
            locator.resource.path,
            "/library/parts/2/16000/file%20name.mp4"
        )
        XCTAssertEqual(locator.deliveryMode, .directFile)
        XCTAssertNil(locator.playSessionID)
        XCTAssertFalse(
            locator.resource.queryItems.contains {
                $0.name.localizedCaseInsensitiveContains("token")
            }
        )

        let forced = try await provider.playbackInfo(
            for: "88",
            forceTranscode: true
        )
        XCTAssertTrue(forced.isTranscoding)
        guard case .authenticatedHTTP(let forcedLocator) = forced.playbackSource else {
            return XCTFail("expected authenticated HTTP locator")
        }
        XCTAssertEqual(
            forcedLocator.resource.path,
            "/video/:/transcode/universal/start.m3u8"
        )
        XCTAssertEqual(forcedLocator.deliveryMode, .serverTranscode)
    }

    func testPlaybackInfoUsesSelectedPlexMediaIndex() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/89", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"89","type":"movie","title":"Movie","duration":3600000,
           "Media":[
             {"id":11,"container":"mkv","videoCodec":"h264","audioCodec":"aac",
              "Part":[{"id":1,"key":"/library/parts/1/first.mkv","container":"mkv"}]},
             {"id":22,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3",
              "Part":[{"id":2,"key":"/library/parts/2/selected.mkv","container":"mkv"}]}
           ]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(
            for: "89",
            mediaSourceID: "22",
            forceTranscode: true
        )
        guard case .authenticatedHTTP(let locator) = request.playbackSource else {
            return XCTFail("expected authenticated HTTP locator")
        }
        XCTAssertEqual(locator.mediaSourceID, "22")
        XCTAssertEqual(
            locator.resource.queryItems.first { $0.name == "mediaIndex" }?.value,
            "1"
        )
        XCTAssertEqual(
            locator.resource.queryItems.first { $0.name == "partIndex" }?.value,
            "0"
        )
        let localRemux = try XCTUnwrap(request.localRemuxSource)
        guard case .authenticatedHTTP(let original) = localRemux.originalSource else {
            return XCTFail("expected authenticated original source")
        }
        XCTAssertEqual(
            original.resource.path,
            "/library/parts/2/selected.mkv"
        )
    }

    func testPlaybackInfoBuildsPlexBIFScrubPreviewWhenIndexed() async throws {
        // A part the server has generated BIF preview thumbnails for advertises
        // `indexes:"sd"`, so the provider should expose a Plex BIF scrub source
        // pointing at /library/parts/{id}/indexes/sd without storing the token.
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/99", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"99","type":"movie","title":"Movie","duration":3600000,
           "Media":[{"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"aac","Part":[{"id":42,"key":"/library/parts/42/16000/file.mp4","container":"mp4","indexes":"sd","Stream":[
             {"id":10,"streamType":1,"index":0,"codec":"h264"},
             {"id":11,"streamType":2,"index":1,"codec":"aac","selected":true}
           ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "99")
        guard case .some(.authenticatedHTTP(let locator)) =
            request.scrubPreview?.plexBIFResource else {
            return XCTFail("expected authenticated BIF resource")
        }
        XCTAssertEqual(locator.resource.path, "library/parts/42/indexes/sd")
        XCTAssertEqual(locator.purpose, .scrubPreview)
        XCTAssertFalse(String(describing: locator).contains("TOKEN"))
    }

    func testAudioPlaybackInfoReturnsCredentialFreeSource() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/song1", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"song1","type":"track","title":"Song",
           "Media":[{"id":7,"container":"m4a","audioCodec":"aac",
             "Part":[{"id":8,"key":"/library/parts/8/song name.m4a","container":"m4a"}]}]}
        ]}}
        """)
        let provider = PlexProvider(
            session: makeSession(),
            accountID: "account",
            http: stub
        )

        let request = try await provider.audioPlaybackInfo(
            for: "song1",
            queueContext: nil
        )
        guard case .authenticatedHTTP(let locator) = request.playbackSource else {
            return XCTFail("expected authenticated HTTP audio locator")
        }
        XCTAssertEqual(locator.accountID, "account")
        XCTAssertEqual(locator.purpose, .audioStream)
        XCTAssertEqual(locator.deliveryMode, .directFile)
        XCTAssertEqual(
            locator.resource.path,
            "/library/parts/8/song%20name.m4a"
        )
        XCTAssertFalse(
            locator.resource.queryItems.contains {
                $0.name.localizedCaseInsensitiveContains("token")
            }
        )
        XCTAssertNil(request.streamURL)
    }

    func testPlaybackInfoPrefersHDBIFWhenAvailable() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/101", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"101","type":"movie","title":"Movie","duration":3600000,
           "Media":[{"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"aac","Part":[{"id":55,"key":"/library/parts/55/16000/file.mp4","container":"mp4","indexes":"sd,hd","Stream":[
             {"id":10,"streamType":1,"index":0,"codec":"h264"},
             {"id":11,"streamType":2,"index":1,"codec":"aac","selected":true}
           ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "101")
        guard case .some(.authenticatedHTTP(let locator)) =
            request.scrubPreview?.plexBIFResource else {
            return XCTFail("expected authenticated BIF resource")
        }
        XCTAssertEqual(locator.resource.path, "library/parts/55/indexes/hd")
    }

    func testPlaybackInfoBuildsBIFScrubPreviewForEpisode() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/102", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"102","type":"episode","title":"Episode 1","duration":1800000,
           "Media":[{"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"aac","Part":[{"id":99,"key":"/library/parts/99/16000/file.mp4","container":"mp4","indexes":"hd","Stream":[
             {"id":10,"streamType":1,"index":0,"codec":"h264"},
             {"id":11,"streamType":2,"index":1,"codec":"aac","selected":true}
           ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "102")
        guard case .some(.authenticatedHTTP(let locator)) =
            request.scrubPreview?.plexBIFResource else {
            return XCTFail("expected authenticated BIF resource")
        }
        XCTAssertEqual(locator.resource.path, "library/parts/99/indexes/hd")
        XCTAssertFalse(String(describing: locator).contains("TOKEN"))
    }

    func testPlaybackInfoHasNoScrubPreviewWhenPartNotIndexed() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/100", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"100","type":"movie","title":"Movie","duration":3600000,
           "Media":[{"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"aac","Part":[{"id":42,"key":"/library/parts/42/16000/file.mp4","container":"mp4","Stream":[
             {"id":10,"streamType":1,"index":0,"codec":"h264"},
             {"id":11,"streamType":2,"index":1,"codec":"aac","selected":true}
           ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "100")
        XCTAssertNil(request.scrubPreview)
    }

    func testReportPlaybackSendsTimelineState() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/:/timeline", json: "")
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.reportPlayback(
            PlaybackProgress(itemID: "77", playSessionID: "77", positionSeconds: 120, isPaused: true),
            event: .pause
        )

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/:/timeline"))
        XCTAssertEqual(query.first(where: { $0.name == "ratingKey" })?.value, "77")
        XCTAssertEqual(query.first(where: { $0.name == "state" })?.value, "paused")
        XCTAssertEqual(query.first(where: { $0.name == "time" })?.value, "120000")
    }

    func testReportPlaybackStopMapsToStopped() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/:/timeline", json: "")
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.reportPlayback(
            PlaybackProgress(itemID: "77", playSessionID: "77", positionSeconds: 0, isPaused: false),
            event: .stop
        )
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/:/timeline"))
        XCTAssertEqual(query.first(where: { $0.name == "state" })?.value, "stopped")
    }
}

// MARK: - Auth client

final class PlexAuthClientTests: XCTestCase {
    /// Probe double that reports everything unreachable, so `servers()` resolves
    /// deterministically via ranked preference order without touching the network.
    private final class UnreachableProbe: HTTPClient, @unchecked Sendable {
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            throw AppError.serverUnreachable
        }
    }

    private func client(_ stub: StubHTTPClient) -> PlexAuthClient {
        PlexAuthClient(deviceProfile: PlexDeviceProfile(clientIdentifier: "dev1"), http: stub, probeHTTP: UnreachableProbe())
    }

    func testDefaultDeviceProfileReportsMinimumSupportedTVOS() {
        let profile = PlexDeviceProfile(clientIdentifier: "device")
        XCTAssertEqual(profile.headers()["X-Plex-Platform-Version"], "18.0")
    }

    func testAuthorizationURLCarriesPinAndDeviceIdentity() {
        let profile = PlexDeviceProfile(product: "Plozz Player", clientIdentifier: "device/id")
        let client = PlexAuthClient(deviceProfile: profile)
        let url = client.authorizationURL(for: PlexPinChallenge(id: 42, code: "A&B"))

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "app.plex.tv")
        XCTAssertEqual(url.path, "/auth")

        let encodedFragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment
        let query = encodedFragment.map { String($0.dropFirst()) }
        let queryItems = query.flatMap { URLComponents(string: "https://example.com/?\($0)")?.queryItems }
        let values = Dictionary(uniqueKeysWithValues: (queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(values["clientID"], "device/id")
        XCTAssertEqual(values["code"], "A&B")
        XCTAssertEqual(values["context[device][product]"], "Plozz Player")
    }

    func testCreatePinParsesChallenge() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/api/v2/pins", json: #"{"id":424242,"code":"WXYZ","authToken":null}"#)
        let pin = try await client(stub).createPin()
        XCTAssertEqual(pin.id, 424242)
        XCTAssertEqual(pin.code, "WXYZ")

        // We must NOT request a strong PIN: strong codes are long and not
        // usable for the plex.tv/link manual-entry flow.
        let query = stub.queryItems(forPathSuffix: "/api/v2/pins")
        XCTAssertNil(query?.first(where: { $0.name == "strong" }))
    }

    func testCreateStrongPinRequestsHostedAuthChallenge() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/api/v2/pins", json: #"{"id":424242,"code":"long-code","authToken":null}"#)

        let pin = try await client(stub).createPin(strong: true)

        XCTAssertEqual(pin.code, "long-code")
        let query = stub.queryItems(forPathSuffix: "/api/v2/pins")
        XCTAssertEqual(query?.first(where: { $0.name == "strong" })?.value, "true")
    }

    func testPollPinPendingThenClaimed() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/api/v2/pins/1", jsons: [
            #"{"id":1,"code":"WXYZ","authToken":null}"#,
            #"{"id":1,"code":"WXYZ","authToken":"ACCOUNT_TOKEN"}"#
        ])
        let c = client(stub)
        let first = try await c.pollPin(id: 1)
        XCTAssertEqual(first, .pending)
        let second = try await c.pollPin(id: 1)
        XCTAssertEqual(second, .claimed(authToken: "ACCOUNT_TOKEN"))
    }

    func testPollPinSurfacesRateLimitAndRetryDelay() async {
        let stub = StubHTTPClient()
        stub.stub(
            pathSuffix: "/api/v2/pins/1",
            json: "",
            status: 429,
            headers: ["Retry-After": "12"]
        )

        do {
            _ = try await client(stub).pollPin(id: 1)
            XCTFail("Expected rate limit")
        } catch let error as PlexPinError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 12))
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testServersFilterToServerProvidesAndPickConnection() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/api/v2/resources", json: """
        [
          {"name":"Player","provides":"client","clientIdentifier":"c1","connections":[]},
          {"name":"My Server","provides":"server","clientIdentifier":"srv1","accessToken":"SRVTOKEN","owned":true,
           "connections":[
             {"protocol":"https","uri":"https://remote.plex.direct:32400","local":false,"relay":false},
             {"protocol":"https","uri":"https://local.plex.direct:32400","local":true,"relay":false}
           ]}
        ]
        """)
        let servers = try await client(stub).servers(authToken: "ACCOUNT_TOKEN")
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].id, "srv1")
        XCTAssertEqual(servers[0].name, "My Server")
        XCTAssertEqual(servers[0].accessToken, "SRVTOKEN")
        XCTAssertTrue(servers[0].isOwned)
        XCTAssertEqual(servers[0].baseURL.absoluteString, "https://local.plex.direct:32400")
    }

    func testUserParsesIdentity() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/api/v2/user", json: #"{"id":9,"uuid":"uuid-9","username":"alice","title":"Alice T"}"#)
        let user = try await client(stub).user(authToken: "ACCOUNT_TOKEN")
        XCTAssertEqual(user.id, "uuid-9")
        XCTAssertEqual(user.userName, "Alice T")
    }

    func testHomeUsersParsesAndMapsFlags() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/api/v2/home/users", json: """
        {"users":[
          {"id":1,"uuid":"owner-uuid","title":"Brandon","admin":true,"protected":false,"restricted":false},
          {"id":2,"uuid":"kid-uuid","title":"Kiddo","admin":false,"protected":true,"restricted":true}
        ]}
        """)
        let users = try await client(stub).homeUsers(authToken: "ADMIN_TOKEN")
        XCTAssertEqual(users.count, 2)
        XCTAssertEqual(users[0].id, "owner-uuid")
        XCTAssertEqual(users[0].name, "Brandon")
        XCTAssertTrue(users[0].isAdmin)
        XCTAssertFalse(users[0].requiresPIN)
        XCTAssertEqual(users[1].id, "kid-uuid")
        XCTAssertTrue(users[1].requiresPIN)
        XCTAssertTrue(users[1].isRestricted)
        XCTAssertEqual(stub.method(forPathSuffix: "/api/v2/home/users"), .get)
    }

    func testHomeUsersTreatsHasPasswordAsRequiresPIN() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/api/v2/home/users", json: """
        {"users":[{"uuid":"u","title":"Guest","hasPassword":true}]}
        """)
        let users = try await client(stub).homeUsers(authToken: "ADMIN_TOKEN")
        XCTAssertEqual(users.count, 1)
        XCTAssertTrue(users[0].requiresPIN)
    }

    func testSwitchHomeUserPassesPinAndReturnsToken() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/kid-uuid/switch", json: #"{"authToken":"KID_TOKEN"}"#)
        let token = try await client(stub).switchHomeUser(uuid: "kid-uuid", pin: "1234", authToken: "ADMIN_TOKEN")
        XCTAssertEqual(token, "KID_TOKEN")
        XCTAssertEqual(stub.method(forPathSuffix: "/kid-uuid/switch"), .post)
        let pin = stub.queryItems(forPathSuffix: "/kid-uuid/switch")?.first { $0.name == "pin" }
        XCTAssertEqual(pin?.value, "1234")
    }

    func testSwitchHomeUserOmitsPinWhenNil() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/owner-uuid/switch", json: #"{"authenticationToken":"OWNER_TOKEN"}"#)
        let token = try await client(stub).switchHomeUser(uuid: "owner-uuid", pin: nil, authToken: "ADMIN_TOKEN")
        XCTAssertEqual(token, "OWNER_TOKEN")
        let query = stub.queryItems(forPathSuffix: "/owner-uuid/switch")
        XCTAssertNil(query?.first { $0.name == "pin" })
    }

    func testSwitchHomeUserUnauthorizedWhenNoToken() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/kid-uuid/switch", json: #"{"authToken":null}"#)
        do {
            _ = try await client(stub).switchHomeUser(uuid: "kid-uuid", pin: "0000", authToken: "ADMIN_TOKEN")
            XCTFail("Expected unauthorized")
        } catch let error as AppError {
            XCTAssertEqual(error, .unauthorized)
        }
    }
}

// MARK: - Capability-driven direct play

final class PlexDirectPlayCapabilityTests: XCTestCase {

    private func makeClient(_ caps: MediaCapabilities) -> PlexClient {
        PlexClient(
            baseURL: URL(string: "https://plex.host:32400")!,
            deviceProfile: PlexDeviceProfile(clientIdentifier: "dev1"),
            token: "TOKEN",
            http: StubHTTPClient(),
            capabilities: caps
        )
    }

    /// Decodes a single `Media`/`Part` pair from a Plex metadata JSON fragment.
    private func decodeMedia(_ json: String) throws -> (PlexMedia, PlexPart) {
        let wrapper = "{\"MediaContainer\":{\"Metadata\":[{\"ratingKey\":\"1\",\"Media\":[\(json)]}]}}"
        let response = try JSONDecoder().decode(PlexMediaContainerResponse.self, from: Data(wrapper.utf8))
        let media = try XCTUnwrap(response.MediaContainer.Metadata?.first?.Media?.first)
        let part = try XCTUnwrap(media.Part?.first)
        return (media, part)
    }

    private func canDirectPlay(_ json: String, caps: MediaCapabilities) throws -> Bool {
        let (media, part) = try decodeMedia(json)
        return makeClient(caps).canDirectPlay(media: media, part: part)
    }

    // The bread-and-butter case must be unaffected by the rework: an MP4 with
    // h264 video + AAC audio direct-plays under the conservative default profile.
    func testCommonH264AacMp4DirectPlaysUnderDefault() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        XCTAssertTrue(try canDirectPlay(json, caps: .default))
    }

    func testHevcGatedOnSupport() throws {
        // Plex labels HEVC as "h265" here; it must fold onto .hevc.
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h265","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let hevcYes = MediaCapabilities(supportsHEVC: true)
        let hevcNo = MediaCapabilities(supportsHEVC: false)
        XCTAssertTrue(try canDirectPlay(json, caps: hevcYes))
        XCTAssertFalse(try canDirectPlay(json, caps: hevcNo))
    }

    func testAV1GatedOnSupport() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"av1","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"av1"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let av1Yes = MediaCapabilities(supportsAV1: true)
        XCTAssertFalse(try canDirectPlay(json, caps: .default), "AV1 must transcode without support")
        XCTAssertTrue(try canDirectPlay(json, caps: av1Yes))
    }

    func testAV01AliasGatedOnSupport() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"av01","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"av01"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let av1Yes = MediaCapabilities(supportsAV1: true)
        XCTAssertFalse(try canDirectPlay(json, caps: .default))
        XCTAssertTrue(try canDirectPlay(json, caps: av1Yes))
    }

    func testDTSDirectPlayOnlyWhenPassthroughSupported() throws {
        // Plex commonly labels DTS as "dca"; it must fold onto .dts.
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"dca",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"dca"}
         ]}]}
        """
        let dtsYes = MediaCapabilities(maxOutputChannels: 8, supportsDTSPassthrough: true)
        XCTAssertFalse(try canDirectPlay(json, caps: .default), "stereo output must not claim DTS passthrough")
        XCTAssertTrue(try canDirectPlay(json, caps: dtsYes))
    }

    func testEAC3AlwaysPassthroughEligible() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"eac3",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"eac3"}
         ]}]}
        """
        XCTAssertTrue(try canDirectPlay(json, caps: .default))
    }

    func testDolbyVisionProfile7TranscodesEvenWithDoViDisplay() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"hevc","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","DOVIPresent":true,"DOVIProfile":7},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let doviDisplay = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        XCTAssertFalse(try canDirectPlay(json, caps: doviDisplay))
    }

    func testDolbyVisionProfile8DirectPlaysOnDoViDisplayOnly() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"hevc","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","DOVIPresent":true,"DOVIProfile":8},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let doviDisplay = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        XCTAssertTrue(try canDirectPlay(json, caps: doviDisplay))
        XCTAssertFalse(try canDirectPlay(json, caps: .default), "non-DoVi display must transcode DoVi")
    }

    func testUnknownDolbyVisionProfileIsConservative() throws {
        // DOVIPresent but no profile reported → don't assume P5/P8.
        let json = """
        {"id":1,"container":"mp4","videoCodec":"hevc","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","DOVIPresent":true},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let doviDisplay = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        XCTAssertFalse(try canDirectPlay(json, caps: doviDisplay))
    }

    func testHDR10GatedOnDisplay() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"hevc","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","colorTrc":"smpte2084"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let hdrDisplay = MediaCapabilities(supportsHEVC: true, supportsHDR10: true)
        let sdrOnly = MediaCapabilities(supportsHEVC: true, supportsHDR10: false, supportsHLG: false)
        XCTAssertTrue(try canDirectPlay(json, caps: hdrDisplay))
        XCTAssertFalse(try canDirectPlay(json, caps: sdrOnly))
    }

    func testUnsupportedContainerStillTranscodes() throws {
        let json = """
        {"id":1,"container":"mkv","videoCodec":"h264","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        XCTAssertFalse(try canDirectPlay(json, caps: .default))
    }
}

final class PlexWatchStateTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testSetPlayedTrueScrobbles() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/:/scrobble", json: "")
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.setPlayed(true, itemID: "42")

        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/:/scrobble") })
        let query = stub.queryItems(forPathSuffix: "/:/scrobble")
        XCTAssertEqual(query?.first(where: { $0.name == "key" })?.value, "42")
        XCTAssertEqual(
            query?.first(where: { $0.name == "identifier" })?.value,
            "com.plexapp.plugins.library"
        )
    }

    func testSetPlayedFalseUnscrobbles() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/:/unscrobble", json: "")
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.setPlayed(false, itemID: "42")

        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/:/unscrobble") })
        XCTAssertEqual(
            stub.queryItems(forPathSuffix: "/:/unscrobble")?.first(where: { $0.name == "key" })?.value,
            "42"
        )
    }

    /// The out-of-band resume write must set `viewOffset` via `/:/progress` and
    /// must NOT report `/:/timeline` (a `state=stopped` timeline ends the live
    /// session and zeroes the server's now-playing dashboard — the reproduced
    /// bug).
    func testSetResumePositionUsesProgressNotTimeline() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/:/progress", json: "")
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.setResumePosition(120, itemID: "42")

        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/:/progress") })
        XCTAssertFalse(stub.sentPaths.contains { $0.hasSuffix("/:/timeline") })
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/:/progress"))
        XCTAssertEqual(query.first(where: { $0.name == "key" })?.value, "42")
        XCTAssertEqual(query.first(where: { $0.name == "identifier" })?.value, "com.plexapp.plugins.library")
        XCTAssertEqual(query.first(where: { $0.name == "time" })?.value, "120000")
        XCTAssertEqual(query.first(where: { $0.name == "state" })?.value, "stopped")
    }

    /// Clearing the resume point (position 0) still goes through `/:/progress`,
    /// never a timeline report.
    func testSetResumePositionZeroUsesProgressNotTimeline() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/:/progress", json: "")
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.setResumePosition(0, itemID: "42")

        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/:/progress") })
        XCTAssertFalse(stub.sentPaths.contains { $0.hasSuffix("/:/timeline") })
        XCTAssertEqual(
            stub.queryItems(forPathSuffix: "/:/progress")?.first(where: { $0.name == "time" })?.value,
            "0"
        )
    }
}
