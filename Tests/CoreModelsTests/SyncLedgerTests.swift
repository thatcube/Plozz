import XCTest
@testable import CoreModels

// MARK: - Fake CloudKit transport (deterministic, high-fidelity)
//
// Models a CloudKit private-DB zone precisely enough to prove SyncLedger converges
// under the interleavings that broke V2 on real hardware AND the failure modes the
// two independent reviews flagged: change-tag conflicts (serverRecordChanged),
// incremental fetch tokens, TOMBSTONELESS full resync after CKErrorChangeTokenExpired
// (live records only — the fidelity gap that hid the resurrection bug), delete
// races, out-of-order delivery, in-flight edits/reverts, and partial captures.

private final class FakeCloudServer {
    struct Stored { var value: Data; var editedAt: Int64; var tag: Int; var deleted: Bool }
    private(set) var records: [String: Stored] = [:]
    private(set) var log: [(name: String, seq: Int)] = []
    private var nextTag = 1
    private var nextSeq = 1

    enum SaveResult { case success(tag: Int); case conflict(server: SyncRemoteRecord); case deleted }

    static func tagData(_ tag: Int) -> Data { withUnsafeBytes(of: Int32(tag).bigEndian) { Data($0) } }
    static func tag(from data: Data?) -> Int? {
        guard let data, data.count == 4 else { return nil }
        return Int(data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).bigEndian })
    }
    var headToken: Int { nextSeq - 1 }

    func save(name: String, value: Data, editedAt: Int64, expectedTag: Int?) -> SaveResult {
        if let existing = records[name], existing.deleted {
            // Save against a tombstone. A client holding a tag saw a prior version →
            // authoritative deletion (no resurrection). A tag-less create is genuinely new.
            if expectedTag != nil { return .deleted }
        } else if let existing = records[name] {
            if existing.tag != expectedTag {
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

    /// Incremental changes strictly after `token` (a log index): saves + deletes.
    func fetch(since token: Int) -> (saved: [SyncRemoteRecord], deleted: [String], token: Int) {
        var saved: [SyncRemoteRecord] = []; var deleted: [String] = []; var seen = Set<String>()
        for entry in log.reversed() where entry.seq > token {
            guard !seen.contains(entry.name) else { continue }
            seen.insert(entry.name)
            let s = records[entry.name]!
            if s.deleted { deleted.append(entry.name) }
            else { saved.append(SyncRemoteRecord(recordName: entry.name, value: s.value,
                                                 editedAt: s.editedAt, systemFields: Self.tagData(s.tag))) }
        }
        return (saved.reversed(), deleted.reversed(), headToken)
    }

    /// A FULL resync after a token reset: real CloudKit returns LIVE records only —
    /// NO tombstones for already-deleted records. This is exactly what let deleted
    /// records resurrect in V3's first draft.
    func fetchLive() -> (saved: [SyncRemoteRecord], token: Int) {
        let saved = records
            .filter { !$0.value.deleted }
            .map { SyncRemoteRecord(recordName: $0.key, value: $0.value.value,
                                    editedAt: $0.value.editedAt, systemFields: Self.tagData($0.value.tag)) }
            .sorted { $0.recordName < $1.recordName }
        return (saved, headToken)
    }
}

// MARK: - Fake device (ledger + a canonical local store)

private final class FakeDevice {
    var ledger = SyncLedger()
    var store: [String: Data] = [:]
    var fetchToken = 0
    private let server: FakeCloudServer
    var now: Int64
    let name: String
    /// When set, `capture()` drops these record names to simulate a partial/unhydrated
    /// snapshot (the mass-deletion foot-gun).
    var hiddenOnCapture: Set<String> = []

    init(_ name: String, server: FakeCloudServer, startClock: Int64) {
        self.name = name; self.server = server; self.now = startClock
    }
    private func advance() -> Int64 { now += 1; return now }

    func edit(_ record: String, _ value: String) { store[record] = Data(value.utf8) }
    func remove(_ record: String) { store[record] = nil }
    func value(_ record: String) -> String? { store[record].map { String(decoding: $0, as: UTF8.self) } }
    private func capture() -> [String: Data] { store.filter { !hiddenOnCapture.contains($0.key) } }

    func sync() { push(); fetch() }

    func push(synthesizeDeletions: Bool = true) {
        let plan = ledger.reconcileLocal(desired: capture(), now: advance(),
                                         synthesizeDeletions: synthesizeDeletions)
        for up in plan.uploads { send(up) }
        for name in plan.deletes { sendDelete(name) }
        // Durability: retry any tombstones not just queued (models a rebuild/partial fail).
        for name in ledger.pendingDeletes() where !plan.deletes.contains(name) { sendDelete(name) }
    }

    private func send(_ up: SyncUpload) {
        switch server.save(name: up.recordName, value: up.value, editedAt: up.editedAt,
                           expectedTag: FakeCloudServer.tag(from: up.systemFields)) {
        case .success(let tag):
            ledger.applySendSuccess(recordName: up.recordName, savedValue: up.value,
                                    savedEditedAt: up.editedAt, systemFields: FakeCloudServer.tagData(tag))
        case .conflict(let server):
            if let (rec, val) = ledger.applySendConflict(server, now: advance()) {
                applyLocal(rec, val)
            } else if let entry = ledger.entries[up.recordName], entry.dirty {
                send(SyncUpload(recordName: up.recordName, value: entry.localValue,
                                editedAt: entry.editedAt, systemFields: entry.systemFields))
            }
        case .deleted:
            if ledger.applyRemoteDeletion(up.recordName) { applyLocal(up.recordName, nil) }
        }
    }

    private func sendDelete(_ name: String) {
        server.delete(name: name, expectedTag: FakeCloudServer.tag(from: ledger.entries[name]?.systemFields))
        ledger.applyDeleteSuccess(name)
    }

    func fetch() {
        let result = server.fetch(since: fetchToken)
        fetchToken = result.token
        let changes = ledger.applyFetched(saved: result.saved, deleted: result.deleted, now: advance())
        for (rec, val) in changes { applyLocal(rec, val) }
    }

    private func applyLocal(_ record: String, _ value: Data?) {
        if let value { store[record] = value } else { store[record] = nil }
    }

    /// Engine-rebuild redownload via the full-resync lifecycle. `tombstoneless` models
    /// a real CKErrorChangeTokenExpired resync (live records only, no tombstones).
    func redownload(tombstoneless: Bool = true) {
        ledger.beginFullResync()
        let saved: [SyncRemoteRecord]; let token: Int; let deleted: [String]
        if tombstoneless { let r = server.fetchLive(); saved = r.saved; token = r.token; deleted = [] }
        else { let r = server.fetch(since: 0); saved = r.saved; token = r.token; deleted = r.deleted }
        let changes = ledger.applyFetched(saved: saved, deleted: deleted, now: advance())
        for (rec, val) in changes { applyLocal(rec, val) }
        let finalized = ledger.endFullResync()
        for (rec, val) in finalized { applyLocal(rec, val) }
        fetchToken = token
        for up in ledger.pendingUploads() { send(up) }
        for name in ledger.pendingDeletes() { sendDelete(name) }
    }
}

// MARK: - Helpers

private func drain(_ devices: [FakeDevice], rounds: Int = 8) {
    for _ in 0..<rounds { for d in devices { d.sync() } }
}
private func assertConverged(_ devices: [FakeDevice], _ msg: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
    guard let first = devices.first else { return }
    for d in devices {
        XCTAssertEqual(d.store, first.store, "\(msg): \(d.name) store diverged", file: file, line: line)
        XCTAssertTrue(d.ledger.pendingUploads().isEmpty,
                      "\(msg): \(d.name) still dirty after quiesce (churn)", file: file, line: line)
        XCTAssertTrue(d.ledger.pendingDeletes().isEmpty,
                      "\(msg): \(d.name) has unconfirmed deletes after quiesce", file: file, line: line)
    }
}

final class SyncLedgerTests: XCTestCase {

    // MARK: Basic propagation

    func testSingleEditPropagates() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        a.edit("profile:1", "Alice"); drain([a, b])
        XCTAssertEqual(b.value("profile:1"), "Alice"); assertConverged([a, b], "single edit")
    }

    func testReEditPropagatesLatest() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        a.edit("profile:1", "Alice"); drain([a, b])
        a.edit("profile:1", "Alice v2"); drain([a, b])
        XCTAssertEqual(b.value("profile:1"), "Alice v2"); assertConverged([a, b], "re-edit")
    }

    // MARK: Receiver clobber regression

    func testReceiverDoesNotClobberAfterApplying() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        a.edit("profile:1", "Alice"); drain([a, b])
        b.sync(); b.sync(); b.sync()
        XCTAssertTrue(b.ledger.pendingUploads().isEmpty, "B re-published after applying (clobber)")
        a.sync(); XCTAssertEqual(a.value("profile:1"), "Alice"); assertConverged([a, b], "no receiver clobber")
    }

    func testIdempotentReconcile() {
        let s = FakeCloudServer(); let a = FakeDevice("A", server: s, startClock: 1000)
        a.edit("profile:1", "Alice"); a.sync()
        let plan = a.ledger.reconcileLocal(desired: a.store, now: 999999)
        XCTAssertTrue(plan.isEmpty, "second reconcile of unchanged state must be empty")
    }

    // MARK: Concurrency

    func testConcurrentSameRecordConvergesDeterministically() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 1000)
        a.edit("profile:1", "FromA"); b.now = 5000; b.edit("profile:1", "FromB")
        drain([a, b])
        XCTAssertEqual(a.value("profile:1"), b.value("profile:1")); assertConverged([a, b], "concurrent same")
    }

    func testConcurrentDisjointBothSurvive() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 1000)
        a.edit("profile:1", "Alice"); b.edit("profile:2", "Bob"); drain([a, b])
        XCTAssertEqual(a.value("profile:2"), "Bob"); XCTAssertEqual(b.value("profile:1"), "Alice")
        assertConverged([a, b], "disjoint")
    }

    func testThreeDeviceInterleavedConverges() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        let c = FakeDevice("C", server: s, startClock: 3000)
        a.edit("profile:1", "A1"); a.sync()
        b.fetch(); b.edit("setting:1:theme", "dark"); b.sync()
        c.fetch(); c.edit("membership:1", "s1,s2"); c.sync()
        a.edit("profile:1", "A2"); a.sync()
        drain([a, b, c], rounds: 10)
        assertConverged([a, b, c], "three-device")
        XCTAssertEqual(a.value("profile:1"), "A2"); XCTAssertEqual(a.value("setting:1:theme"), "dark")
        XCTAssertEqual(a.value("membership:1"), "s1,s2")
    }

    // MARK: Deletions

    func testDeletePropagatesAndDoesNotResurrect() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        a.edit("profile:keep", "K"); a.edit("profile:1", "Alice"); drain([a, b])
        a.remove("profile:1"); drain([a, b])
        XCTAssertNil(a.value("profile:1")); XCTAssertNil(b.value("profile:1"))
        drain([a, b]); XCTAssertNil(b.value("profile:1"), "resurrected")
        assertConverged([a, b], "delete")
    }

    func testRemoteDeleteBeatsConcurrentLocalEdit() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        a.edit("profile:keep", "K"); a.edit("profile:1", "Alice"); drain([a, b])
        a.remove("profile:1"); b.now = 9000; b.edit("profile:1", "B-edit")
        a.sync(); b.sync(); a.sync(); b.sync(); drain([a, b])
        XCTAssertNil(a.value("profile:1")); XCTAssertNil(b.value("profile:1"))
        assertConverged([a, b], "delete beats edit")
    }

    // Sol #2 / durability: a pending delete survives until confirmed.
    func testPendingDeleteIsDurableUntilConfirmed() {
        let s = FakeCloudServer(); let a = FakeDevice("A", server: s, startClock: 1000)
        a.edit("profile:1", "Alice"); a.edit("profile:2", "Anne"); a.sync()
        // Reconcile a deletion of profile:2 but DON'T send it (simulate crash before send).
        let plan = a.ledger.reconcileLocal(desired: ["profile:1": Data("Alice".utf8)], now: a.now + 1)
        XCTAssertEqual(plan.deletes, ["profile:2"])
        XCTAssertEqual(a.ledger.pendingDeletes(), ["profile:2"], "delete intent must persist")
        // A relaunch (Codable round-trip) preserves the pending delete.
        let data = try! JSONEncoder().encode(a.ledger)
        let restored = try! JSONDecoder().decode(SyncLedger.self, from: data)
        XCTAssertEqual(restored.pendingDeletes(), ["profile:2"], "pending delete lost across relaunch")
    }

    // MARK: THE critical bug — tombstoneless full resync must not resurrect

    func testTombstonelessResyncDoesNotResurrect() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        a.edit("profile:1", "Alice"); a.edit("profile:2", "Anne"); drain([a, b])
        XCTAssertEqual(b.value("profile:1"), "Alice")
        // A deletes profile:1 while B is offline (B never fetches the tombstone).
        a.remove("profile:1"); a.sync()
        // B's change token expires → full resync returns LIVE records only (no tombstone).
        b.redownload(tombstoneless: true)
        XCTAssertNil(b.value("profile:1"), "deleted record resurrected after tombstoneless resync")
        XCTAssertEqual(b.value("profile:2"), "Anne")
        drain([a, b])
        XCTAssertNil(a.value("profile:1"), "B re-created the deleted record on the server")
        assertConverged([a, b], "tombstoneless resync")
    }

    func testRedownloadRecoversAndDoesNotClobber() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        a.edit("profile:1", "Alice"); a.edit("profile:2", "Anne"); drain([a, b])
        a.edit("profile:1", "Alice-latest"); a.sync()
        b.redownload(tombstoneless: true)
        XCTAssertEqual(b.value("profile:1"), "Alice-latest", "redownload didn't pull latest")
        XCTAssertTrue(b.ledger.pendingUploads().isEmpty, "redownload left B dirty")
        a.sync(); XCTAssertEqual(a.value("profile:1"), "Alice-latest", "B clobbered A")
        assertConverged([a, b], "redownload")
    }

    func testRedownloadPreservesUnsyncedLocalEdit() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        a.edit("profile:1", "Alice"); drain([a, b])
        b.now = 9000; b.edit("profile:1", "Bob-unsynced")
        b.redownload(tombstoneless: true); drain([a, b])
        XCTAssertEqual(a.value("profile:1"), "Bob-unsynced", "redownload lost B's unsynced edit")
        assertConverged([a, b], "redownload preserves dirty")
    }

    func testRedownloadPreservesPendingDelete() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        a.edit("profile:1", "Alice"); a.edit("profile:2", "Anne"); drain([a, b])
        // B deletes profile:2 locally but hasn't confirmed, then redownloads.
        _ = b.ledger.reconcileLocal(desired: ["profile:1": Data("Alice".utf8)], now: b.now + 1)
        b.store["profile:2"] = nil
        XCTAssertEqual(b.ledger.pendingDeletes(), ["profile:2"])
        b.redownload(tombstoneless: true); drain([a, b])
        XCTAssertNil(a.value("profile:2"), "redownload lost B's pending delete → not propagated")
        assertConverged([a, b], "redownload preserves pending delete")
    }

    // MARK: Offline

    func testOfflineDeviceCatchesUp() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        a.edit("profile:1", "Alice"); a.sync()
        a.edit("profile:2", "Anne"); a.sync()
        a.edit("profile:1", "Alice2"); a.sync()
        drain([a, b])
        XCTAssertEqual(b.value("profile:1"), "Alice2"); XCTAssertEqual(b.value("profile:2"), "Anne")
        assertConverged([a, b], "offline catch-up")
    }

    // MARK: In-flight edit safety (Sol #1)

    func testEditDuringInFlightSaveStaysDirty() {
        let s = FakeCloudServer(); let a = FakeDevice("A", server: s, startClock: 1000)
        a.edit("profile:1", "v1")
        let plan = a.ledger.reconcileLocal(desired: a.store, now: a.now + 1)
        XCTAssertEqual(plan.uploads.count, 1)
        a.edit("profile:1", "v2")
        _ = a.ledger.reconcileLocal(desired: a.store, now: a.now + 2)
        a.ledger.applySendSuccess(recordName: "profile:1", savedValue: Data("v1".utf8),
                                  savedEditedAt: plan.uploads[0].editedAt, systemFields: FakeCloudServer.tagData(1))
        XCTAssertFalse(a.ledger.pendingUploads().isEmpty, "newer in-flight edit lost")
        XCTAssertEqual(a.ledger.entries["profile:1"]?.localValue, Data("v2".utf8))
    }

    // Sol #1 sharper: revert to baseline while a save is in flight must still re-upload.
    func testInFlightSaveThenRevertReuploadsRevert() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        a.edit("profile:1", "A"); drain([a, b])           // baseline A on server + both
        // A edits to B-value, reconcile (queue the save), but before the ack A reverts to A.
        a.edit("profile:1", "Bval")
        let plan = a.ledger.reconcileLocal(desired: a.store, now: a.now + 1)
        XCTAssertEqual(plan.uploads.first?.value, Data("Bval".utf8))
        a.edit("profile:1", "A")                            // revert
        _ = a.ledger.reconcileLocal(desired: a.store, now: a.now + 2)  // clears dirty (A==syncedValue A)
        // The in-flight Bval save now lands on the server.
        a.ledger.applySendSuccess(recordName: "profile:1", savedValue: Data("Bval".utf8),
                                  savedEditedAt: plan.uploads[0].editedAt, systemFields: FakeCloudServer.tagData(9))
        // The ledger must know the server now has Bval and re-upload the revert to A.
        XCTAssertEqual(a.ledger.entries["profile:1"]?.syncedValue, Data("Bval".utf8))
        XCTAssertTrue(a.ledger.entries["profile:1"]?.dirty == true, "revert not re-marked dirty")
        let plan2 = a.ledger.reconcileLocal(desired: a.store, now: a.now + 3)
        XCTAssertEqual(plan2.uploads.first?.value, Data("A".utf8), "revert not re-uploaded → server keeps Bval")
    }

    // MARK: Stale / out-of-order delivery (Opus #4)

    func testOlderFetchAfterNewerDoesNotRollbackClean() {
        let s = FakeCloudServer(); let b = FakeDevice("B", server: s, startClock: 2000)
        // B holds a clean value v2@editedAt 30.
        let v2 = SyncRemoteRecord(recordName: "profile:1", value: Data("v2".utf8), editedAt: 30,
                                  systemFields: FakeCloudServer.tagData(2))
        _ = b.ledger.applyFetched(saved: [v2], deleted: [], now: 31)
        b.store["profile:1"] = Data("v2".utf8)
        // A stale re-delivery of v1@editedAt 10 arrives.
        let v1 = SyncRemoteRecord(recordName: "profile:1", value: Data("v1".utf8), editedAt: 10,
                                  systemFields: FakeCloudServer.tagData(1))
        let changes = b.ledger.applyFetched(saved: [v1], deleted: [], now: 32)
        XCTAssertTrue(changes.isEmpty, "stale delivery reverted a newer clean value")
        XCTAssertEqual(b.ledger.entries["profile:1"]?.localValue, Data("v2".utf8))
        XCTAssertEqual(b.ledger.entries["profile:1"]?.editedAt, 30, "editedAt regressed")
    }

    // MARK: Delete racing an in-flight save (Opus #5)

    func testConflictAfterRemoteDeleteDoesNotResurrect() {
        let s = FakeCloudServer(); let a = FakeDevice("A", server: s, startClock: 1000)
        a.edit("profile:1", "v1"); a.sync()
        // A remote deletion removes the entry.
        XCTAssertTrue(a.ledger.applyRemoteDeletion("profile:1"))
        // A late serverRecordChanged for that record must NOT resurrect it.
        let ghost = SyncRemoteRecord(recordName: "profile:1", value: Data("ghost".utf8), editedAt: 5,
                                     systemFields: FakeCloudServer.tagData(7))
        let change = a.ledger.applySendConflict(ghost, now: a.now + 1)
        XCTAssertNil(change, "conflict resurrected a deleted record")
        XCTAssertNil(a.ledger.entries["profile:1"], "ghost entry recreated")
    }

    // MARK: Mass-deletion guard (Opus #2)

    func testEmptyCaptureDoesNotWipeServerBackedRecords() {
        let s = FakeCloudServer(); let a = FakeDevice("A", server: s, startClock: 1000)
        a.edit("profile:1", "Alice"); a.edit("profile:2", "Anne"); a.sync()
        // A hydrating/empty capture must NOT synthesize deletes.
        let plan = a.ledger.reconcileLocal(desired: [:], now: a.now + 1)
        XCTAssertTrue(plan.deletes.isEmpty, "empty capture wiped everything")
        XCTAssertEqual(Set(plan.refusedDeletions), ["profile:1", "profile:2"])
    }

    func testSynthesizeDeletionsFalseSuppressesDeletes() {
        let s = FakeCloudServer(); let a = FakeDevice("A", server: s, startClock: 1000)
        a.edit("profile:1", "Alice"); a.edit("profile:2", "Anne"); a.sync()
        let plan = a.ledger.reconcileLocal(desired: ["profile:1": Data("Alice".utf8)],
                                           now: a.now + 1, synthesizeDeletions: false)
        XCTAssertTrue(plan.deletes.isEmpty)
        XCTAssertEqual(plan.refusedDeletions, ["profile:2"])
        XCTAssertNotNil(a.ledger.entries["profile:2"], "record wrongly dropped")
    }

    // MARK: Duplicate delivery

    func testDuplicateFetchIsHarmless() {
        let s = FakeCloudServer()
        let a = FakeDevice("A", server: s, startClock: 1000), b = FakeDevice("B", server: s, startClock: 2000)
        a.edit("profile:1", "Alice"); a.sync()
        let r1 = s.fetch(since: 0)
        for (rec, val) in b.ledger.applyFetched(saved: r1.saved, deleted: r1.deleted, now: b.now + 1) {
            if let val { b.store[rec] = val } else { b.store[rec] = nil }
        }
        // Same window delivered again (duplicate) — must be a no-op, no churn.
        let r2 = s.fetch(since: 0)
        _ = b.ledger.applyFetched(saved: r2.saved, deleted: r2.deleted, now: b.now + 2)
        XCTAssertTrue(b.ledger.pendingUploads().isEmpty, "duplicate delivery caused churn")
        drain([a, b]); assertConverged([a, b], "duplicate")
    }

    // MARK: Persistence

    func testLedgerCodableRoundTrip() throws {
        let s = FakeCloudServer(); let a = FakeDevice("A", server: s, startClock: 1000)
        a.edit("profile:1", "Alice"); a.edit("setting:1:x", "y"); a.sync()
        let data = try JSONEncoder().encode(a.ledger)
        let restored = try JSONDecoder().decode(SyncLedger.self, from: data)
        XCTAssertEqual(restored, a.ledger)
        var r = restored
        let plan = r.reconcileLocal(desired: a.store, now: 999999)
        XCTAssertTrue(plan.isEmpty, "restored ledger re-uploaded unchanged state")
    }
}
