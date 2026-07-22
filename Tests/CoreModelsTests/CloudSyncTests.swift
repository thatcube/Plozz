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
            let rec = CloudSyncRecord(kind: kind, id: "abc:def", editedAt: 3, payload: Data())
            let parsed = CloudSyncRecord.parse(recordName: rec.recordName)
            XCTAssertEqual(parsed?.kind, kind)
            XCTAssertEqual(parsed?.id, "abc:def", "id containing ':' must survive")
        }
        XCTAssertNil(CloudSyncRecord.parse(recordName: "bogus"))
        XCTAssertNil(CloudSyncRecord.parse(recordName: "account:"))
    }

    // MARK: publish diffing + editedAt stamping

    func testPublishFromEmptyCreatesStampedRecords() {
        var mirror = CloudSyncMirror()
        let local = snapshot(accounts: [descriptor("A")], profiles: [profile("p1", name: "Mom")])
        let plan = mirror.publish(local: local)

        XCTAssertEqual(plan.deletes, [])
        XCTAssertEqual(plan.saves.count, 2)
        XCTAssertTrue(plan.saves.allSatisfy { $0.editedAt > 0 }, "new records get a fresh HLC timestamp")
        XCTAssertEqual(Set(plan.saves.map(\.recordName)), ["account:A", "profile:p1"])
    }

    func testRepublishUnchangedIsNoOp() {
        var mirror = CloudSyncMirror()
        let local = snapshot(accounts: [descriptor("A")], profiles: [profile("p1", name: "Mom")])
        _ = mirror.publish(local: local)
        let second = mirror.publish(local: local)
        XCTAssertTrue(second.isEmpty, "publishing an unchanged snapshot must produce no changes")
    }

    func testEditAdvancesEditedAt() {
        var mirror = CloudSyncMirror()
        let first = mirror.publish(local: snapshot(profiles: [profile("p1", name: "Mom")]))
        let firstStamp = first.saves.first!.editedAt
        let plan = mirror.publish(local: snapshot(profiles: [profile("p1", name: "Mommy")]))
        XCTAssertEqual(plan.saves.count, 1)
        XCTAssertEqual(plan.saves.first?.recordName, "profile:p1")
        XCTAssertGreaterThan(plan.saves.first!.editedAt, firstStamp, "an edit must advance editedAt")
    }

    func testProfileRemovalProducesDelete() {
        var mirror = CloudSyncMirror()
        _ = mirror.publish(local: snapshot(profiles: [profile("p1", name: "A"), profile("p2", name: "B")]))
        let plan = mirror.publish(local: snapshot(profiles: [profile("p1", name: "A")]))
        XCTAssertEqual(plan.deletes, ["profile:p2"])
        XCTAssertEqual(plan.saves, [])
    }

    /// Account descriptors are NEVER deleted from mere absence (a device isn't
    /// signed into every server) — that guards against destroying household data.
    func testAccountAbsenceDoesNotDelete() {
        var mirror = CloudSyncMirror()
        _ = mirror.publish(local: snapshot(accounts: [descriptor("A"), descriptor("B")]))
        let plan = mirror.publish(local: snapshot(accounts: [descriptor("A")]))
        XCTAssertEqual(plan.deletes, [], "an account absent from local must NOT be deleted")
        XCTAssertNotNil(mirror.records["account:B"], "the descriptor stays in the mirror")
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

    private func record(_ kind: CloudSyncRecord.Kind, _ id: String, editedAt: Int64, payload: Data) -> CloudSyncRecord {
        CloudSyncRecord(kind: kind, id: id, editedAt: editedAt, payload: payload)
    }

    func testApplyRemoteAddsAndDeletes() {
        var mirror = CloudSyncMirror()
        let payload = try! JSONEncoder().encode(descriptor("A"))
        let incoming = record(.account, "A", editedAt: 100, payload: payload)

        let added = mirror.applyRemote(saved: [incoming], deletedRecordNames: [])
        XCTAssertTrue(added.changed)
        XCTAssertEqual(added.snapshot.accounts.map(\.id), ["A"])

        let removed = mirror.applyRemote(saved: [], deletedRecordNames: ["account:A"])
        XCTAssertTrue(removed.changed)
        XCTAssertTrue(removed.snapshot.accounts.isEmpty)
    }

    func testApplyRemoteLaterEditWins() {
        var mirror = CloudSyncMirror()
        _ = mirror.publish(local: snapshot(profiles: [profile("p1", name: "Mom")]))  // stamped ~now
        let remotePayload = try! JSONEncoder().encode(profile("p1", name: "Remote"))
        // Far-future editedAt => strictly later => wins.
        let remote = record(.profile, "p1", editedAt: Int64(Date().timeIntervalSince1970 * 1000) + 1_000_000, payload: remotePayload)

        let result = mirror.applyRemote(saved: [remote], deletedRecordNames: [])
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.snapshot.profiles.first?.profile.name, "Remote")
    }

    func testApplyRemoteOlderEditIgnoredAndPushedBack() {
        var mirror = CloudSyncMirror()
        _ = mirror.publish(local: snapshot(profiles: [profile("p1", name: "Local")]))  // stamped ~now
        // An OLDER remote edit (editedAt in the past) must lose AND be flagged for
        // re-push so the stale server converges to our newer value.
        let stale = record(.profile, "p1", editedAt: 1, payload: try! JSONEncoder().encode(profile("p1", name: "Stale")))
        let result = mirror.applyRemote(saved: [stale], deletedRecordNames: [])
        XCTAssertFalse(result.changed, "an older remote edit must not overwrite a newer local one")
        XCTAssertEqual(result.snapshot.profiles.first?.profile.name, "Local")
        XCTAssertEqual(result.toPush.map(\.recordName), ["profile:p1"], "our newer copy must be pushed back")
    }

    /// The critical convergence property: applying two conflicting SAME-timestamp
    /// edits in EITHER order yields the same winner on both devices.
    func testEqualTimestampTieBreakIsOrderIndependent() {
        let payloadX = try! JSONEncoder().encode(profile("p1", name: "Xavier"))
        let payloadY = try! JSONEncoder().encode(profile("p1", name: "Yolanda"))
        let recX = record(.profile, "p1", editedAt: 500, payload: payloadX)
        let recY = record(.profile, "p1", editedAt: 500, payload: payloadY)

        var deviceA = CloudSyncMirror(records: ["profile:p1": recX])
        var deviceB = CloudSyncMirror(records: ["profile:p1": recY])
        _ = deviceA.applyRemote(saved: [recY], deletedRecordNames: [])
        _ = deviceB.applyRemote(saved: [recX], deletedRecordNames: [])

        XCTAssertEqual(deviceA.records["profile:p1"], deviceB.records["profile:p1"],
                       "concurrent same-timestamp edits must converge to the same record on both devices")
    }

    func testResolveLaterEditWinsRegardlessOfPayload() {
        let older = record(.account, "A", editedAt: 1, payload: Data([0xFF, 0xFF]))   // "big" payload
        let newer = record(.account, "A", editedAt: 9, payload: Data([0x00]))         // "small" payload
        XCTAssertEqual(CloudSyncRecord.resolve(older, newer), newer)
        XCTAssertEqual(CloudSyncRecord.resolve(newer, older), newer)
    }
}
