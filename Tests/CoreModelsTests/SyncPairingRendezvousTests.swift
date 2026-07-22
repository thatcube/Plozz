import XCTest
@testable import CoreModels

final class SyncPairingRendezvousTests: XCTestCase {

    private func make(_ device: String, ttl: Int = 300, now: Date = Date(),
                      key: Data = Data([1, 2, 3]), service: String = "ABCD") -> SyncPairingRendezvous {
        SyncPairingRendezvous(serviceName: service, publicKeyData: key,
                              deviceName: device, deviceID: device, ttlSeconds: ttl, now: now)
    }

    func testExcludesSelf() {
        let list = [make("A"), make("self")]
        let target = PairingRendezvousMatcher.target(from: list, thisDeviceID: "self")
        XCTAssertEqual(target?.deviceID, "A")
    }

    func testExcludesExpired() {
        let now = Date()
        let expired = make("old", ttl: -10, now: now)
        XCTAssertTrue(expired.isExpired(now: now))
        let target = PairingRendezvousMatcher.target(from: [expired], thisDeviceID: "self", now: now)
        XCTAssertNil(target)
    }

    func testRejectsMalformed() {
        let emptyKey = SyncPairingRendezvous(serviceName: "X", publicKeyData: Data(),
                                             deviceName: "d", deviceID: "d", ttlSeconds: 300)
        let emptyService = SyncPairingRendezvous(serviceName: "", publicKeyData: Data([1]),
                                                 deviceName: "d2", deviceID: "d2", ttlSeconds: 300)
        XCTAssertNil(PairingRendezvousMatcher.target(from: [emptyKey, emptyService], thisDeviceID: "self"))
    }

    func testRejectsWrongProtocolVersion() {
        var r = make("A")
        r.protocolVersion = 999
        XCTAssertFalse(r.isUsable())
        XCTAssertNil(PairingRendezvousMatcher.target(from: [r], thisDeviceID: "self"))
    }

    func testPicksFreshestThenDeterministicTiebreak() {
        let now = Date()
        let older = make("A", ttl: 100, now: now)
        let newer = make("B", ttl: 500, now: now)
        XCTAssertEqual(PairingRendezvousMatcher.target(from: [older, newer], thisDeviceID: "self", now: now)?.deviceID, "B")

        // Equal expiry → deterministic tie-break by deviceID (ascending).
        let x = make("X", ttl: 300, now: now)
        let y = make("Y", ttl: 300, now: now)
        XCTAssertEqual(PairingRendezvousMatcher.target(from: [y, x], thisDeviceID: "self", now: now)?.deviceID, "X")
    }

    func testTargetsListExcludesSelfAndExpired() {
        let now = Date()
        let list = [make("A", now: now), make("self", now: now), make("old", ttl: -1, now: now)]
        let targets = PairingRendezvousMatcher.targets(from: list, thisDeviceID: "self", now: now)
        XCTAssertEqual(targets.map(\.deviceID), ["A"])
    }

    func testCodableRoundTrip() throws {
        let r = make("A")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(SyncPairingRendezvous.self, from: data)
        XCTAssertEqual(r, back)
        XCTAssertEqual(back.id, "rendezvous:A")
    }
}
