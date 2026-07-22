import XCTest
@testable import CoreModels

// MARK: - Fake CloudKit transport (deterministic)
//
// Models a CloudKit private-DB zone precisely enough to prove SyncLedger converges
// under the nasty multi-device interleavings that broke V2 on real hardware:
// change-tag conflicts (serverRecordChanged), per-device incremental fetch tokens,
// out-of-order / duplicate / delayed delivery, offline-then-reconnect, concurrent
// same-record edits, remote-delete vs local-edit, and engine-rebuild redownload.
// No CloudKit, no devices — pure and exhaustive, per the review's release-gate spec.

private final class FakeCloudServer {
    struct Stored { var value: Data; var editedAt: Int64; var tag: Int; var deleted: Bool }
    /// recordName -> latest state (tombstones kept so late fetchers see deletions).
    private(set) var records: [String: Stored] = [:]
    /// Append-only change log; a fetch token is an index into it.
    private(set) var log: [(name: String, seq: Int)] = []
    private var nextTag = 1
    private var nextSeq = 1

    enum SaveResult { case success(tag: Int); case conflict(server: SyncRemoteRecord); case deleted }

    /// Encode/decode the opaque `systemFields` the ledger carries as a 4-byte tag.
    static func tagData(_ tag: Int) -> Data { withUnsafeBytes(of: Int32(tag).bigEndian) { Data($0) } }
    static func tag(from data: Data?) -> Int? {
        guard let data, data.count == 4 else { return nil }
        return Int(data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).bigEndian })
    }

    func save(name: String, value: Data, editedAt: Int64, expectedTag: Int?) -> SaveResult {
        if let existing = records[name], existing.deleted {
            // Saving against a tombstone. If the client holds a change tag it saw a
            // prior version → the record was deleted out from under it: authoritative
            // deletion (no resurrection). A tag-less create is a genuinely new record.
            if expectedTag != nil { return .deleted }
        } else if let existing = records[name] {
            if existing.tag != expectedTag {
                // Client's change tag is stale → conflict, hand back the server record.
                return .conflict(server: SyncRemoteRecord(
                    recordName: name, value: existing.value, editedAt: existing.editedAt,
                    systemFields: Self.tagData(existing.tag)))
            }
        }
        let tag = nextTag; nextTag += 1
        records[name] = Stored(value: value, editedAt: editedAt, tag: tag, deleted: false)
        log.append((name, nextSeq)); nextSeq += 1
        return .success(tag: tag)
    }

    func delete(name: String, expectedTag: Int?) {
        guard var s = records[name], !s.deleted else { return }
        s.deleted = true; s.tag = nextTag; nextTag += 1
        records[name] = s
        log.append((name, nextSeq)); nextSeq += 1
    }

    /// Changes strictly after `token` (a log index). Returns saved + deleted + new token.
    func fetch(since token: Int) -> (saved: [SyncRemoteRecord], deleted: [String], token: Int) {
        var saved: [SyncRemoteRecord] = []
        var deleted: [String] = []
        var seen = Set<String>()
        // Walk newest→oldest so each record contributes only its latest state.
        for entry in log.reversed() where entry.seq > token {
            guard !seen.contains(entry.name) else { continue }
            seen.insert(entry.name)
            let s = records[entry.name]!
            if s.deleted { deleted.append(entry.name) }
            else { saved.append(SyncRemoteRecord(recordName: entry.name, value: s.value,
                                                 editedAt: s.editedAt, systemFields: Self.tagData(s.tag))) }
        }
        return (saved.reversed(), deleted.reversed(), nextSeq - 1)
    }
}

// MARK: - Fake device (ledger + a canonical local store)

private final class FakeDevice {
    var ledger = SyncLedger()
    /// The app's "real store": recordName -> canonical value. Source of truth for values.
    var store: [String: Data] = [:]
    var fetchToken = 0
    private let server: FakeCloudServer
    var now: Int64
    let name: String

    init(_ name: String, server: FakeCloudServer, startClock: Int64) {
        self.name = name; self.server = server; self.now = startClock
    }

    private func advance() -> Int64 { now += 1; return now }

    // A genuine local edit / delete.
    func edit(_ record: String, _ value: String) { store[record] = Data(value.utf8) }
    func remove(_ record: String) { store[record] = nil }
    func value(_ record: String) -> String? { store[record].map { String(decoding: $0, as: UTF8.self) } }

    /// One full sync pass: publish local edits (with conflict handling) then fetch.
    /// Mirrors the service's intended order and is safe to call repeatedly.
    func sync() { push(); fetch() }

    func push() {
        let plan = ledger.reconcileLocal(desired: store, now: advance())
        for up in plan.uploads { send(up) }
        for name in plan.deletes {
            server.delete(name: name, expectedTag: FakeCloudServer.tag(from: nil))
        }
    }

    private func send(_ up: SyncUpload) {
        let expected = FakeCloudServer.tag(from: up.systemFields)
        switch server.save(name: up.recordName, value: up.value, editedAt: up.editedAt, expectedTag: expected) {
        case .success(let tag):
            ledger.applySendSuccess(recordName: up.recordName, savedValue: up.value,
                                    savedEditedAt: up.editedAt, systemFields: FakeCloudServer.tagData(tag))
        case .conflict(let server):
            if let (rec, val) = ledger.applySendConflict(server, now: advance()) {
                applyLocal(rec, val)          // server won → apply its value
            } else {
                // We're newer → retry the save with the fresh tag.
                if let entry = ledger.entries[up.recordName] {
                    send(SyncUpload(recordName: up.recordName, value: entry.localValue,
                                    editedAt: entry.editedAt, systemFields: entry.systemFields))
                }
            }
        case .deleted:
            // The record was deleted by a peer → authoritative, delete locally too.
            if ledger.applyRemoteDeletion(up.recordName) { applyLocal(up.recordName, nil) }
        }
    }

    func fetch() {
        let result = server.fetch(since: fetchToken)
        fetchToken = result.token
        let changes = ledger.applyFetched(saved: result.saved, deleted: result.deleted, now: advance())
        for (rec, val) in changes { applyLocal(rec, val) }
    }

    /// Apply the EXACT local change the ledger dictated (nil = delete).
    private func applyLocal(_ record: String, _ value: Data?) {
        if let value { store[record] = value } else { store[record] = nil }
    }

    /// Simulate an engine-rebuild redownload: forget server tokens/tags, keep local
    /// edits, full-fetch from scratch, re-push anything still dirty.
    func redownload() {
        ledger.forgetServerState()
        fetchToken = 0
        fetch()
        for up in ledger.pendingUploads() { send(up) }
    }
}

// MARK: - Convergence helpers

private func drain(_ devices: [FakeDevice], rounds: Int = 8) {
    // Repeated full syncs until quiescent; a correct core reaches a fixed point fast.
    for _ in 0..<rounds { for d in devices { d.sync() } }
}

private func assertConverged(_ devices: [FakeDevice], _ msg: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
    guard let first = devices.first else { return }
    for d in devices {
        XCTAssertEqual(d.store, first.store, "\(msg): \(d.name) store diverged", file: file, line: line)
        // No device may have pending uploads once quiesced — that's the no-clobber /
        // no-churn invariant (a dirty record here means an endless re-upload loop).
        XCTAssertTrue(d.ledger.pendingUploads().isEmpty,
                      "\(msg): \(d.name) still dirty after quiesce (churn)", file: file, line: line)
    }
}

final class SyncLedgerTests: XCTestCase {

    // MARK: Basic propagation

    func testSingleEditPropagates() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        let b = FakeDevice("B", server: server, startClock: 2000)
        a.edit("profile:1", "Alice")
        drain([a, b])
        XCTAssertEqual(b.value("profile:1"), "Alice")
        assertConverged([a, b], "single edit")
    }

    func testEditThenReEditPropagatesLatest() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        let b = FakeDevice("B", server: server, startClock: 2000)
        a.edit("profile:1", "Alice"); drain([a, b])
        a.edit("profile:1", "Alice v2"); drain([a, b])
        XCTAssertEqual(b.value("profile:1"), "Alice v2")
        assertConverged([a, b], "re-edit")
    }

    // MARK: THE clobber regression — idempotent reconcile, no churn

    func testReceiverDoesNotClobberAfterApplying() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        let b = FakeDevice("B", server: server, startClock: 2000)
        a.edit("profile:1", "Alice")
        // B receives, then B syncs many more times. B must NEVER re-upload a fresh
        // copy that beats A (the V2 clobber). After the first apply, B is clean.
        drain([a, b])
        b.sync(); b.sync(); b.sync()
        XCTAssertTrue(b.ledger.pendingUploads().isEmpty, "B re-published after applying (clobber)")
        // A's value must still stand (never overwritten by B's echo).
        a.sync()
        XCTAssertEqual(a.value("profile:1"), "Alice")
        assertConverged([a, b], "no receiver clobber")
    }

    func testIdempotentReconcile() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        a.edit("profile:1", "Alice")
        _ = a.ledger.reconcileLocal(desired: a.store, now: 1)
        // Simulate the save landing.
        a.sync()
        let plan = a.ledger.reconcileLocal(desired: a.store, now: 2)
        XCTAssertTrue(plan.isEmpty, "second reconcile of unchanged state must be empty")
    }

    // MARK: Concurrent same-record edits — deterministic LWW, converges

    func testConcurrentSameRecordConvergesDeterministically() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        let b = FakeDevice("B", server: server, startClock: 1000)
        // Both edit the same record while "offline", B's edit strictly later.
        a.edit("profile:1", "FromA")
        b.now = 5000
        b.edit("profile:1", "FromB")
        drain([a, b])
        // Later real edit (B) wins on both devices; both converge.
        XCTAssertEqual(a.value("profile:1"), b.value("profile:1"))
        assertConverged([a, b], "concurrent same-record")
    }

    func testConcurrentDisjointFieldsBothSurvive() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        let b = FakeDevice("B", server: server, startClock: 1000)
        a.edit("profile:1", "Alice")
        b.edit("profile:2", "Bob")
        drain([a, b])
        XCTAssertEqual(a.value("profile:1"), "Alice")
        XCTAssertEqual(a.value("profile:2"), "Bob")
        XCTAssertEqual(b.value("profile:1"), "Alice")
        XCTAssertEqual(b.value("profile:2"), "Bob")
        assertConverged([a, b], "disjoint records")
    }

    // MARK: Deletions are authoritative (no resurrection)

    func testDeletePropagatesAndDoesNotResurrect() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        let b = FakeDevice("B", server: server, startClock: 2000)
        a.edit("profile:1", "Alice"); drain([a, b])
        XCTAssertEqual(b.value("profile:1"), "Alice")
        a.remove("profile:1"); drain([a, b])
        XCTAssertNil(a.value("profile:1"))
        XCTAssertNil(b.value("profile:1"), "deletion did not propagate")
        // Extra syncs must not resurrect it.
        drain([a, b])
        XCTAssertNil(b.value("profile:1"), "record resurrected")
        assertConverged([a, b], "delete")
    }

    func testRemoteDeleteBeatsConcurrentLocalEdit() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        let b = FakeDevice("B", server: server, startClock: 2000)
        a.edit("profile:1", "Alice"); drain([a, b])
        // A deletes; B concurrently edits the same record, then both sync.
        a.remove("profile:1")
        b.now = 9000; b.edit("profile:1", "B-edit")
        a.sync(); b.sync(); a.sync(); b.sync(); drain([a, b])
        // Deletion is authoritative — record gone everywhere, no resurrection loop.
        XCTAssertNil(a.value("profile:1"))
        XCTAssertNil(b.value("profile:1"))
        assertConverged([a, b], "delete beats edit")
    }

    // MARK: Offline then reconnect

    func testOfflineDeviceCatchesUp() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        let b = FakeDevice("B", server: server, startClock: 2000)
        // A makes several edits while B is offline.
        a.edit("profile:1", "Alice"); a.sync()
        a.edit("profile:2", "Anne"); a.sync()
        a.edit("profile:1", "Alice2"); a.sync()
        // B comes online.
        drain([a, b])
        XCTAssertEqual(b.value("profile:1"), "Alice2")
        XCTAssertEqual(b.value("profile:2"), "Anne")
        assertConverged([a, b], "offline catch-up")
    }

    // MARK: Three devices, interleaved

    func testThreeDeviceInterleavedConverges() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        let b = FakeDevice("B", server: server, startClock: 2000)
        let c = FakeDevice("C", server: server, startClock: 3000)
        a.edit("profile:1", "A1"); a.sync()
        b.fetch(); b.edit("setting:1:theme", "dark"); b.sync()
        c.fetch(); c.edit("membership:1", "s1,s2"); c.sync()
        a.edit("profile:1", "A2"); a.sync()
        drain([a, b, c], rounds: 10)
        assertConverged([a, b, c], "three-device interleave")
        XCTAssertEqual(a.value("profile:1"), "A2")
        XCTAssertEqual(a.value("setting:1:theme"), "dark")
        XCTAssertEqual(a.value("membership:1"), "s1,s2")
    }

    // MARK: Redownload (engine rebuild) recovers without clobber

    func testRedownloadRecoversAndDoesNotClobber() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        let b = FakeDevice("B", server: server, startClock: 2000)
        a.edit("profile:1", "Alice"); a.edit("profile:2", "Anne"); drain([a, b])
        // A makes a NEW edit that B hasn't seen; B redownloads (token reset). B must
        // pull A's data and must NOT re-upload stale copies that revert A.
        a.edit("profile:1", "Alice-latest"); a.sync()
        b.redownload()
        XCTAssertEqual(b.value("profile:1"), "Alice-latest", "redownload didn't pull latest")
        XCTAssertTrue(b.ledger.pendingUploads().isEmpty, "redownload left B dirty (clobber risk)")
        a.sync()
        XCTAssertEqual(a.value("profile:1"), "Alice-latest", "B clobbered A after redownload")
        assertConverged([a, b], "redownload")
    }

    func testRedownloadPreservesUnsyncedLocalEdit() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        let b = FakeDevice("B", server: server, startClock: 2000)
        a.edit("profile:1", "Alice"); drain([a, b])
        // B makes a local edit but hasn't pushed; then redownloads. Its unsynced edit
        // (newer) must survive and propagate, not be lost by the token reset.
        b.now = 9000; b.edit("profile:1", "Bob-unsynced")
        b.redownload()
        drain([a, b])
        XCTAssertEqual(a.value("profile:1"), "Bob-unsynced", "redownload lost B's unsynced edit")
        assertConverged([a, b], "redownload preserves dirty")
    }

    // MARK: In-flight edit must not be cleared by an older ack

    func testEditDuringInFlightSaveStaysDirty() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        // Reconcile produces an upload; before "sending", the user edits again.
        a.edit("profile:1", "v1")
        let plan = a.ledger.reconcileLocal(desired: a.store, now: a.now + 1)
        XCTAssertEqual(plan.uploads.count, 1)
        // A newer edit arrives while v1 is "in flight".
        a.edit("profile:1", "v2")
        _ = a.ledger.reconcileLocal(desired: a.store, now: a.now + 2)
        // The v1 save now succeeds (older ack).
        a.ledger.applySendSuccess(recordName: "profile:1", savedValue: Data("v1".utf8),
                                  savedEditedAt: plan.uploads[0].editedAt,
                                  systemFields: FakeCloudServer.tagData(1))
        // v2 must still be pending (not cleared by the v1 ack).
        XCTAssertFalse(a.ledger.pendingUploads().isEmpty, "newer in-flight edit was lost")
        XCTAssertEqual(a.ledger.entries["profile:1"]?.localValue, Data("v2".utf8))
    }

    // MARK: Duplicate / out-of-order delivery tolerated

    func testDuplicateFetchIsHarmless() {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        let b = FakeDevice("B", server: server, startClock: 2000)
        a.edit("profile:1", "Alice"); a.sync()
        // B fetches the same change twice (token not advanced the first time).
        let r1 = server.fetch(since: 0)
        _ = b.ledger.applyFetched(saved: r1.saved, deleted: r1.deleted, now: b.now + 1)
        let r2 = server.fetch(since: 0)
        _ = b.ledger.applyFetched(saved: r2.saved, deleted: r2.deleted, now: b.now + 2)
        XCTAssertTrue(b.ledger.pendingUploads().isEmpty, "duplicate delivery caused churn")
        drain([a, b])
        assertConverged([a, b], "duplicate delivery")
    }

    // MARK: Persistence round-trip (ledger is Codable and survives relaunch)

    func testLedgerCodableRoundTrip() throws {
        let server = FakeCloudServer()
        let a = FakeDevice("A", server: server, startClock: 1000)
        a.edit("profile:1", "Alice"); a.edit("setting:1:x", "y"); a.sync()
        let data = try JSONEncoder().encode(a.ledger)
        let restored = try JSONDecoder().decode(SyncLedger.self, from: data)
        XCTAssertEqual(restored, a.ledger)
        // A restored ledger reconciling the same store produces no work.
        var r = restored
        let plan = r.reconcileLocal(desired: a.store, now: a.now + 10)
        XCTAssertTrue(plan.isEmpty, "restored ledger re-uploaded unchanged state")
    }
}
