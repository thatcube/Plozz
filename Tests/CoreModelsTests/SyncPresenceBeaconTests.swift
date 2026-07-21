import XCTest
@testable import CoreModels

final class SyncPresenceBeaconTests: XCTestCase {

    func testBeaconIsNonSecretAndRoundTrips() {
        let beacon = SyncPresenceBeacon(setupExists: true, deviceName: "Living Room", serverCount: 2, profileCount: 3)
        let data = try! JSONEncoder().encode(beacon)
        let json = String(data: data, encoding: .utf8)!.lowercased()
        XCTAssertFalse(json.contains("token"))
        XCTAssertFalse(json.contains("password"))
        XCTAssertFalse(json.contains("url"))
        let decoded = try! JSONDecoder().decode(SyncPresenceBeacon.self, from: data)
        XCTAssertEqual(decoded, beacon)
    }

    func testInMemoryStoreReadWriteClear() {
        let store = InMemoryPresenceBeaconStore()
        XCTAssertNil(store.read())
        let beacon = SyncPresenceBeacon(setupExists: true, deviceName: "Living Room", serverCount: 1, profileCount: 1)
        store.write(beacon)
        XCTAssertEqual(store.read(), beacon)
        store.clear()
        XCTAssertNil(store.read())
    }

    func testEvaluatorOffersContinueOnlyWhenUnconfiguredAndSetupExists() {
        let beacon = SyncPresenceBeacon(setupExists: true, deviceName: "Living Room", serverCount: 2, profileCount: 2)
        // Fresh device + a real setup elsewhere -> offer.
        XCTAssertTrue(PresenceBeaconEvaluator.shouldOfferContinue(beacon: beacon, thisDeviceIsConfigured: false))
        // Already configured -> don't nag.
        XCTAssertFalse(PresenceBeaconEvaluator.shouldOfferContinue(beacon: beacon, thisDeviceIsConfigured: true))
        // No beacon -> nothing to offer.
        XCTAssertFalse(PresenceBeaconEvaluator.shouldOfferContinue(beacon: nil, thisDeviceIsConfigured: false))
        // Beacon exists but no servers -> nothing useful to bring.
        let empty = SyncPresenceBeacon(setupExists: true, deviceName: "X", serverCount: 0, profileCount: 0)
        XCTAssertFalse(PresenceBeaconEvaluator.shouldOfferContinue(beacon: empty, thisDeviceIsConfigured: false))
    }
}
