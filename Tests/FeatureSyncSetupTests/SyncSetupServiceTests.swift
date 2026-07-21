import XCTest
@testable import FeatureSyncSetup
@testable import CoreModels

@MainActor
final class SyncSetupServiceTests: XCTestCase {

    private func makeService(
        beacon: InMemoryPresenceBeaconStore,
        accounts: [Account] = [],
        profiles: [Profile] = [],
        configured: Bool = false,
        enabled: Bool = true
    ) -> SyncSetupService {
        let d = UserDefaults(suiteName: "svc.\(UUID().uuidString)")!
        var flag = SyncSetupFeatureFlag(defaults: d); flag.isEnabled = enabled
        return SyncSetupService(
            flag: SyncSetupFeatureFlag(defaults: d),
            beaconStore: beacon,
            deviceID: { "this-device" },
            deviceName: { "Living Room" },
            isConfigured: { configured },
            configProvider: { .init(accounts: accounts, profiles: profiles) }
        )
    }

    private func account(_ id: String, server: String = "s1") -> Account {
        let s = MediaServer(id: server, name: "Home", baseURL: URL(string: "https://h.example.com")!, provider: .jellyfin)
        return Account(id: id, server: s, userID: "u", userName: "U", deviceID: "dev")
    }

    func testPublishPresenceReflectsConfigAndDedupesServers() {
        let beacon = InMemoryPresenceBeaconStore()
        let svc = makeService(beacon: beacon,
                              accounts: [account("a1", server: "s1"), account("a2", server: "s1"), account("a3", server: "s2")],
                              profiles: [Profile(id: "p1", name: "B"), Profile(id: "p2", name: "K")])
        svc.publishPresence()
        let b = beacon.read()
        XCTAssertEqual(b?.serverCount, 2)   // two distinct servers
        XCTAssertEqual(b?.profileCount, 2)
        XCTAssertEqual(b?.deviceName, "Living Room")
    }

    func testDisablingClearsBeacon() {
        let beacon = InMemoryPresenceBeaconStore()
        let svc = makeService(beacon: beacon, accounts: [account("a1")], profiles: [])
        svc.setEnabled(true)
        XCTAssertNotNil(beacon.read())
        svc.setEnabled(false)
        XCTAssertNil(beacon.read())
        XCTAssertFalse(svc.isEnabled)
    }

    func testContinueOfferOnlyWhenUnconfigured() {
        let beacon = InMemoryPresenceBeaconStore(
            SyncPresenceBeacon(setupExists: true, deviceName: "Living Room", serverCount: 1, profileCount: 1))
        let fresh = makeService(beacon: beacon, configured: false)
        XCTAssertNotNil(fresh.continueOffer())
        let configured = makeService(beacon: beacon, configured: true)
        XCTAssertNil(configured.continueOffer())
    }

    func testEndToEndServicePairing() async throws {
        // Phone side has config.
        let phone = makeService(beacon: InMemoryPresenceBeaconStore(),
                                accounts: [account("a1")],
                                profiles: [Profile(id: "p1", name: "Brandon")])
        // TV side is fresh.
        let tv = makeService(beacon: InMemoryPresenceBeaconStore(), configured: false)

        let (invite, identity) = tv.makeInvite()
        let channel = InMemoryPairingChannel()

        async let received = tv.receiveConfig(identity: identity, over: channel)
        try await phone.sendConfig(to: invite, over: channel)
        let application = try await received

        XCTAssertEqual(application.profiles.map(\.id), ["p1"])
        XCTAssertEqual(application.pendingAuthorizations.map(\.id), ["a1"])
        XCTAssertTrue(application.pendingAuthorizations.allSatisfy { $0.state == .pending })
    }
}
