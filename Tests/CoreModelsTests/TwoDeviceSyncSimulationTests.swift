import XCTest
@testable import CoreModels

/// End-to-end simulation of two devices syncing through a shared CloudKit zone,
/// WITHOUT any real CloudKit. It models the transport faithfully:
///   • A "server" dict is the private-DB zone. A CloudKit save OVERWRITES the
///     server copy (last-writer-wins at the transport, once you hold the change
///     tag) — CloudKit does NOT compare our `version`/`updatedAt` field.
///   • A fetch returns every server record; the device folds them in via
///     `CloudSyncMirror.applyRemote`, then applies the resulting snapshot to its
///     local stores.
///
/// This is exactly where the "won't converge" bug lives: the transport is
/// last-writer-wins, but `applyRemote` used monotonic `version` to REJECT a
/// lower-version incoming record — so a device that made more edits (higher
/// version) permanently refuses another device's newer-in-real-time edit and never
/// re-publishes its own. These tests prove convergence deterministically.
final class TwoDeviceSyncSimulationTests: XCTestCase {

    // MARK: Simulated transport

    private final class Sim {
        /// The CloudKit zone: recordName -> record. A save overwrites; the LAST
        /// writer's value is what remains (like CloudKit with a valid change tag).
        var server: [String: CloudSyncRecord] = [:]

        struct Device {
            var mirror = CloudSyncMirror()
            var local = SyncConfigSnapshot()
        }

        /// Publish a device's local config to the server (last writer wins), and
        /// re-push any records the mirror says are locally-newer than the server.
        func publish(_ device: inout Device) {
            let plan = device.mirror.publish(local: device.local)
            for rec in plan.saves { server[rec.recordName] = rec }
            for name in plan.deletes { server[name] = nil }
        }

        /// Fetch every server record and apply. Returns whether local changed.
        @discardableResult
        func fetch(_ device: inout Device) -> Bool {
            let all = Array(server.values)
            let serverNames = Set(server.keys)
            let deleted = device.mirror.records.keys.filter { !serverNames.contains($0) }
            let result = device.mirror.applyRemote(saved: all, deletedRecordNames: Array(deleted))
            if result.changed { device.local = result.snapshot }
            // Push back exactly the records where THIS device won the resolve (server
            // is stale) — mirroring the real service, which enqueues result.toPush.
            // A plain re-publish would find nothing (local == mirror after apply).
            for rec in result.toPush { server[rec.recordName] = rec }
            return result.changed
        }
    }

    // MARK: Helpers

    private func profile(_ id: String, _ name: String) -> Profile {
        Profile(id: id, name: name, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func snap(_ profiles: [Profile]) -> SyncConfigSnapshot {
        SyncConfigSnapshot(profiles: profiles.map { VersionedProfile(profile: $0) })
    }

    private func names(_ d: Sim.Device) -> [String: String] {
        Dictionary(uniqueKeysWithValues: d.local.profiles.map { ($0.profile.id, $0.profile.name) })
    }

    // MARK: Tests

    /// Baseline: two devices each create the shared default profile with different
    /// names, publish, then both fetch — they must converge to the SAME name.
    func testEqualEditsConverge() {
        let sim = Sim()
        var a = Sim.Device(); a.local = snap([profile("default", "Brandon")])
        var b = Sim.Device(); b.local = snap([profile("default", "Me")])

        sim.publish(&a)
        sim.publish(&b)
        // Let them settle: fetch a few rounds (mirrors sync engine retries).
        for _ in 0..<3 { sim.fetch(&a); sim.fetch(&b) }

        XCTAssertEqual(names(a)["default"], names(b)["default"],
                       "two devices must converge to the same default-profile name")
    }

    /// THE reported bug: device A edits the default profile several times (high
    /// version), device B edits it once (low version). B's edit reaches the server
    /// last. A must NOT permanently refuse B's edit — they must converge.
    func testDivergentVersionsStillConverge() {
        let sim = Sim()
        var a = Sim.Device(); var b = Sim.Device()
        a.local = snap([profile("default", "A0")])
        b.local = snap([profile("default", "B0")])
        sim.publish(&a); sim.publish(&b)
        for _ in 0..<2 { sim.fetch(&a); sim.fetch(&b) }

        // A keeps editing (version climbs); B edits once more, later in real time.
        a.local = snap([profile("default", "A1")]); sim.publish(&a)
        a.local = snap([profile("default", "A2")]); sim.publish(&a)
        b.local = snap([profile("default", "B_final")]); sim.publish(&b)

        // Everyone syncs to quiescence.
        for _ in 0..<5 { sim.fetch(&a); sim.fetch(&b) }

        XCTAssertEqual(names(a)["default"], names(b)["default"],
                       "devices must converge even when one has a much higher version")
    }

    /// After convergence, a fresh edit on EITHER device propagates to the other.
    func testEditPropagatesBothDirections() {
        let sim = Sim()
        var a = Sim.Device(); var b = Sim.Device()
        a.local = snap([profile("default", "Start")])
        sim.publish(&a)
        for _ in 0..<3 { sim.fetch(&b); sim.fetch(&a) }
        XCTAssertEqual(names(b)["default"], "Start", "B receives A's initial value")

        // Edit on B → A sees it.
        b.local = snap([profile("default", "EditedOnB")]); sim.publish(&b)
        for _ in 0..<3 { sim.fetch(&a); sim.fetch(&b) }
        XCTAssertEqual(names(a)["default"], "EditedOnB", "A must receive B's edit")

        // Edit on A → B sees it.
        a.local = snap([profile("default", "EditedOnA")]); sim.publish(&a)
        for _ in 0..<3 { sim.fetch(&b); sim.fetch(&a) }
        XCTAssertEqual(names(b)["default"], "EditedOnA", "B must receive A's edit")
    }

    /// Adding a profile on one device and editing an existing one on the other
    /// both survive (union + edit), across many sync rounds.
    func testAddAndEditMerge() {
        let sim = Sim()
        var a = Sim.Device(); var b = Sim.Device()
        a.local = snap([profile("default", "Home")])
        sim.publish(&a)
        for _ in 0..<3 { sim.fetch(&b); sim.fetch(&a) }

        // A adds a profile; B edits the default.
        a.local = snap([profile("default", "Home"), profile("kid", "Kid")]); sim.publish(&a)
        b.local = snap([profile("default", "Household")]); sim.publish(&b)
        for _ in 0..<6 { sim.fetch(&a); sim.fetch(&b) }

        XCTAssertEqual(Set(names(a).keys), Set(names(b).keys), "both must have the same profile set")
        XCTAssertEqual(names(a), names(b), "both must converge to identical names")
        XCTAssertTrue(names(a).keys.contains("kid"), "the added profile must survive")
    }
}
