import XCTest
@testable import CoreModels

final class CloudSyncTests: XCTestCase {

    // MARK: Helpers

    private func descriptor(_ id: String, name: String = "Server", version: Int = 1) -> SyncedAccountDescriptor {
        SyncedAccountDescriptor(id: id, provider: .jellyfin, serverID: "srv-\(id)",
                                serverName: name, userID: "u-\(id)", userName: "User \(id)",
                                recordVersion: version)
    }

    private func profile(_ id: String, name: String) -> Profile {
        // Pin createdAt so repeated calls with the same id/name produce identical
        // payloads (otherwise Date() would make every encode differ).
        Profile(id: id, name: name, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func snapshot(accounts: [SyncedAccountDescriptor] = [],
                          profiles: [Profile] = [],
                          settings: [ProfileSettingsSnapshot] = [],
                          memberships: [String: [String]] = [:]) -> SyncConfigSnapshot {
        SyncConfigSnapshot(
            accounts: accounts,
            profiles: profiles.map { VersionedProfile(profile: $0) },
            profileSettings: settings,
            profileMemberships: memberships
        )
    }

    // MARK: recordName round-trip

    func testRecordNameParseRoundTrip() {
        for kind in CloudSyncRecord.Kind.allCases {
            let rec = CloudSyncRecord(kind: kind, id: "abc:def", version: 3, payload: Data())
            let parsed = CloudSyncRecord.parse(recordName: rec.recordName)
            XCTAssertEqual(parsed?.kind, kind)
            XCTAssertEqual(parsed?.id, "abc:def", "id containing ':' must survive")
        }
        XCTAssertNil(CloudSyncRecord.parse(recordName: "bogus"))
        XCTAssertNil(CloudSyncRecord.parse(recordName: "account:"))
    }

    // MARK: publish diffing + version bumps

    func testPublishFromEmptyCreatesV1Records() {
        var mirror = CloudSyncMirror()
        let local = snapshot(accounts: [descriptor("A")], profiles: [profile("p1", name: "Mom")])
        let plan = mirror.publish(local: local)

        XCTAssertEqual(plan.deletes, [])
        XCTAssertEqual(plan.saves.count, 2)
        XCTAssertTrue(plan.saves.allSatisfy { $0.version == 1 })
        XCTAssertEqual(Set(plan.saves.map(\.recordName)), ["account:A", "profile:p1"])
    }

    func testRepublishUnchangedIsNoOp() {
        var mirror = CloudSyncMirror()
        let local = snapshot(accounts: [descriptor("A")], profiles: [profile("p1", name: "Mom")])
        _ = mirror.publish(local: local)
        let second = mirror.publish(local: local)
        XCTAssertTrue(second.isEmpty, "publishing an unchanged snapshot must produce no changes")
    }

    func testEditBumpsVersion() {
        var mirror = CloudSyncMirror()
        _ = mirror.publish(local: snapshot(profiles: [profile("p1", name: "Mom")]))
        let plan = mirror.publish(local: snapshot(profiles: [profile("p1", name: "Mommy")]))
        XCTAssertEqual(plan.saves.count, 1)
        XCTAssertEqual(plan.saves.first?.recordName, "profile:p1")
        XCTAssertEqual(plan.saves.first?.version, 2)
    }

    func testRemovalProducesDelete() {
        var mirror = CloudSyncMirror()
        _ = mirror.publish(local: snapshot(accounts: [descriptor("A"), descriptor("B")]))
        let plan = mirror.publish(local: snapshot(accounts: [descriptor("A")]))
        XCTAssertEqual(plan.deletes, ["account:B"])
        XCTAssertEqual(plan.saves, [])
    }

    // MARK: membership tri-state

    func testMembershipPresentEmptyVsAbsent() {
        var mirror = CloudSyncMirror()
        // Explicit empty choice ("watch nothing") is a present record with [].
        _ = mirror.publish(local: snapshot(profiles: [profile("p1", name: "Kid")],
                                           memberships: ["p1": []]))
        XCTAssertNotNil(mirror.records["membership:p1"])
        XCTAssertEqual(mirror.snapshot.profileMemberships["p1"], [])

        // Reverting to "never chose" removes the record entirely.
        let plan = mirror.publish(local: snapshot(profiles: [profile("p1", name: "Kid")]))
        XCTAssertEqual(plan.deletes, ["membership:p1"])
        XCTAssertNil(mirror.snapshot.profileMemberships["p1"])
    }

    // MARK: remote apply + convergence

    func testApplyRemoteAddsAndDeletes() {
        var mirror = CloudSyncMirror()
        let payload = try! JSONEncoder().encode(descriptor("A"))
        let incoming = CloudSyncRecord(kind: .account, id: "A", version: 1, payload: payload)

        let added = mirror.applyRemote(saved: [incoming], deletedRecordNames: [])
        XCTAssertTrue(added.changed)
        XCTAssertEqual(added.snapshot.accounts.map(\.id), ["A"])

        let removed = mirror.applyRemote(saved: [], deletedRecordNames: ["account:A"])
        XCTAssertTrue(removed.changed)
        XCTAssertTrue(removed.snapshot.accounts.isEmpty)
    }

    func testApplyRemoteHigherVersionWins() {
        var mirror = CloudSyncMirror()
        _ = mirror.publish(local: snapshot(profiles: [profile("p1", name: "Mom")]))  // v1 local
        let remotePayload = try! JSONEncoder().encode(profile("p1", name: "Remote"))
        let remote = CloudSyncRecord(kind: .profile, id: "p1", version: 5, payload: remotePayload)

        let result = mirror.applyRemote(saved: [remote], deletedRecordNames: [])
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.snapshot.profiles.first?.profile.name, "Remote")
    }

    func testApplyRemoteLowerVersionIgnored() {
        var mirror = CloudSyncMirror()
        _ = mirror.publish(local: snapshot(profiles: [profile("p1", name: "Mom")]))
        _ = mirror.publish(local: snapshot(profiles: [profile("p1", name: "Mom2")]))  // now v2
        let stale = CloudSyncRecord(kind: .profile, id: "p1", version: 1,
                                    payload: try! JSONEncoder().encode(profile("p1", name: "Stale")))
        let result = mirror.applyRemote(saved: [stale], deletedRecordNames: [])
        XCTAssertFalse(result.changed, "a lower-version remote record must not win")
        XCTAssertEqual(result.snapshot.profiles.first?.profile.name, "Mom2")
    }

    /// The critical convergence property: applying two conflicting equal-version
    /// edits in EITHER order yields the same winner on both devices.
    func testEqualVersionTieBreakIsOrderIndependent() {
        let payloadX = try! JSONEncoder().encode(profile("p1", name: "Xavier"))
        let payloadY = try! JSONEncoder().encode(profile("p1", name: "Yolanda"))
        let recX = CloudSyncRecord(kind: .profile, id: "p1", version: 2, payload: payloadX)
        let recY = CloudSyncRecord(kind: .profile, id: "p1", version: 2, payload: payloadY)

        var deviceA = CloudSyncMirror(records: ["profile:p1": recX])
        var deviceB = CloudSyncMirror(records: ["profile:p1": recY])
        _ = deviceA.applyRemote(saved: [recY], deletedRecordNames: [])
        _ = deviceB.applyRemote(saved: [recX], deletedRecordNames: [])

        XCTAssertEqual(deviceA.records["profile:p1"], deviceB.records["profile:p1"],
                       "concurrent equal-version edits must converge to the same record on both devices")
    }

    func testResolveHigherVersionWinsRegardlessOfPayload() {
        let low = CloudSyncRecord(kind: .account, id: "A", version: 1,
                                  payload: Data([0xFF, 0xFF]))          // "big" payload
        let high = CloudSyncRecord(kind: .account, id: "A", version: 9,
                                   payload: Data([0x00]))               // "small" payload
        XCTAssertEqual(CloudSyncRecord.resolve(low, high), high)
        XCTAssertEqual(CloudSyncRecord.resolve(high, low), high)
    }

    // MARK: full round-trip

    func testSnapshotRoundTripThroughRecords() {
        var mirror = CloudSyncMirror()
        let local = snapshot(
            accounts: [descriptor("A"), descriptor("B")],
            profiles: [profile("p1", name: "Mom"), profile("p2", name: "Dad")],
            settings: [ProfileSettingsSnapshot(profileID: "p1", entries: ["theme": Data("dark".utf8)])],
            memberships: ["p1": ["A"], "p2": []]
        )
        _ = mirror.publish(local: local)
        let rebuilt = mirror.snapshot

        XCTAssertEqual(rebuilt.accounts.map(\.id), ["A", "B"])
        XCTAssertEqual(rebuilt.profiles.map(\.profile.id), ["p1", "p2"])
        XCTAssertEqual(rebuilt.profileSettings.map(\.profileID), ["p1"])
        XCTAssertEqual(rebuilt.profileMemberships["p1"], ["A"])
        XCTAssertEqual(rebuilt.profileMemberships["p2"], [])
    }
}
