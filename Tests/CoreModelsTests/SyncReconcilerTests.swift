import XCTest
@testable import CoreModels

final class SyncReconcilerTests: XCTestCase {

    private func desc(_ id: String, _ v: Int, name: String = "Home") -> SyncedAccountDescriptor {
        SyncedAccountDescriptor(id: id, provider: .jellyfin, serverID: "s", serverName: name,
                                userID: "u", userName: "U", recordVersion: v)
    }

    func testHigherVersionWinsPerRecord() {
        let local = [desc("a", 1, name: "old"), desc("b", 3)]
        let remote = [desc("a", 2, name: "new"), desc("c", 1)]
        let (records, _) = SyncReconciler.merge(local: local, remote: remote, version: { $0.recordVersion })
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        XCTAssertEqual(byID["a"]?.serverName, "new")   // remote v2 beat local v1
        XCTAssertEqual(byID["b"]?.recordVersion, 3)    // local-only kept
        XCTAssertEqual(byID["c"]?.recordVersion, 1)    // remote-only kept
        XCTAssertEqual(records.count, 3)
    }

    func testTombstoneSuppressesEqualOrLowerVersion() {
        let local = [desc("a", 2)]
        let (records, tombs) = SyncReconciler.merge(
            local: local, remote: [],
            version: { $0.recordVersion },
            localTombstones: [:], remoteTombstones: ["a": 2]
        )
        XCTAssertTrue(records.isEmpty)          // v2 record suppressed by v2 tombstone
        XCTAssertEqual(tombs["a"], 2)
    }

    func testRecordNewerThanTombstoneSurvives() {
        // A re-created record at a higher version than the tombstone comes back.
        let local = [desc("a", 5)]
        let (records, _) = SyncReconciler.merge(
            local: local, remote: [],
            version: { $0.recordVersion },
            remoteTombstones: ["a": 3]
        )
        XCTAssertEqual(records.map(\.id), ["a"])
    }

    func testStaleDeviceCannotResurrectDelete() {
        // Device A deleted "a" (tombstone v4). Stale device B still has record v2.
        let localB = [desc("a", 2)]
        let (records, tombs) = SyncReconciler.merge(
            local: localB, remote: [],
            version: { $0.recordVersion },
            localTombstones: [:], remoteTombstones: ["a": 4]
        )
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(tombs["a"], 4)
    }

    func testTombstonesMergeByHighestVersion() {
        let (_, tombs) = SyncReconciler.merge(
            local: [SyncedAccountDescriptor](), remote: [],
            version: { $0.recordVersion },
            localTombstones: ["a": 2, "b": 9], remoteTombstones: ["a": 5, "c": 1]
        )
        XCTAssertEqual(tombs["a"], 5)
        XCTAssertEqual(tombs["b"], 9)
        XCTAssertEqual(tombs["c"], 1)
    }

    func testSnapshotMergeReconcilesAccountsAndProfiles() {
        let localProfiles = [VersionedProfile(profile: Profile(id: "p1", name: "Brandon"), recordVersion: 1)]
        let remoteProfiles = [
            VersionedProfile(profile: Profile(id: "p1", name: "Brandon TV"), recordVersion: 2),
            VersionedProfile(profile: Profile(id: "p2", name: "Kids"), recordVersion: 1)
        ]
        let local = SyncConfigSnapshot(accounts: [desc("a", 1)], profiles: localProfiles)
        let remote = SyncConfigSnapshot(accounts: [desc("a", 2, name: "new")], profiles: remoteProfiles,
                                        profileTombstones: [:])
        let merged = local.merged(with: remote)
        XCTAssertEqual(merged.accounts.first?.serverName, "new")
        let profByID = Dictionary(uniqueKeysWithValues: merged.profiles.map { ($0.id, $0.profile.name) })
        XCTAssertEqual(profByID["p1"], "Brandon TV")   // v2 won
        XCTAssertEqual(profByID["p2"], "Kids")
    }

    func testMergePreservesLocalOnlyProfileSettings() {
        // A whole-list replace would drop settings for a profile the remote snapshot
        // doesn't carry. Union by profileID keeps local-only and overlays remote.
        let local = SyncConfigSnapshot(
            profileSettings: [
                ProfileSettingsSnapshot(profileID: "p1", entries: ["k": Data([1])]),
                ProfileSettingsSnapshot(profileID: "p2", entries: ["k": Data([2])])
            ]
        )
        let remote = SyncConfigSnapshot(
            profileSettings: [
                ProfileSettingsSnapshot(profileID: "p1", entries: ["k": Data([9])]),  // updates p1
                ProfileSettingsSnapshot(profileID: "p3", entries: ["k": Data([3])])   // adds p3
            ]
        )
        let merged = local.merged(with: remote)
        let byID = Dictionary(uniqueKeysWithValues: merged.profileSettings.map { ($0.profileID, $0.entries["k"]) })
        XCTAssertEqual(byID["p1"], Data([9]))   // remote-wins per profile
        XCTAssertEqual(byID["p2"], Data([2]))   // local-only preserved (not dropped)
        XCTAssertEqual(byID["p3"], Data([3]))   // remote-only added
        XCTAssertEqual(merged.profileSettings.count, 3)
    }

    func testSnapshotIsCodableAndTokenFree() {
        let snap = SyncConfigSnapshot(
            accounts: [desc("a", 1)],
            profiles: [VersionedProfile(profile: Profile(id: "p1", name: "Brandon"))]
        )
        let json = String(data: try! JSONEncoder().encode(snap), encoding: .utf8)!.lowercased()
        XCTAssertFalse(json.contains("token"))
        XCTAssertFalse(json.contains("password"))
        let back = try! JSONDecoder().decode(SyncConfigSnapshot.self, from: try! JSONEncoder().encode(snap))
        XCTAssertEqual(back, snap)
    }
}
