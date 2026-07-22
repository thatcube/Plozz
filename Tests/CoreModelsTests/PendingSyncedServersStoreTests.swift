import XCTest
@testable import CoreModels

final class PendingSyncedServersStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "PendingSyncedServersTests-\(UUID().uuidString)")!
        return d
    }

    private func desc(_ id: String) -> SyncedAccountDescriptor {
        SyncedAccountDescriptor(id: id, provider: .jellyfin, serverID: "srv-\(id)",
                                serverName: "Server \(id)", userID: "u", userName: "U")
    }

    func testReconcileRecordsOnlyUnauthorized() {
        var store = PendingSyncedServersStore(defaults: makeDefaults())
        let newlyPending = store.reconcile(
            syncedDescriptors: [desc("A"), desc("B"), desc("C")],
            localAccountIDs: ["B"] // already signed into B
        )
        XCTAssertEqual(store.pending.map(\.id), ["A", "C"])
        XCTAssertEqual(newlyPending.map(\.id), ["A", "C"])
    }

    func testSigningInRemovesFromPending() {
        var store = PendingSyncedServersStore(defaults: makeDefaults())
        _ = store.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: [])
        XCTAssertEqual(store.pending.map(\.id), ["A"])
        // Now signed into A locally.
        _ = store.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: ["A"])
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testIgnoreHidesFromPendingButKeepsInAll() {
        var store = PendingSyncedServersStore(defaults: makeDefaults())
        _ = store.reconcile(syncedDescriptors: [desc("A"), desc("B")], localAccountIDs: [])
        store.ignore("A")
        XCTAssertEqual(store.pending.map(\.id), ["B"])
        XCTAssertEqual(store.all.map(\.id), ["A", "B"])
        XCTAssertTrue(store.ignoredIDs.contains("A"))
    }

    func testPromptedExcludedFromNewButStaysPending() {
        var store = PendingSyncedServersStore(defaults: makeDefaults())
        let first = store.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: [])
        XCTAssertEqual(first.map(\.id), ["A"])
        store.markPrompted(["A"])
        // Re-reconcile: still pending (visible in list) but not "new" for a prompt.
        let second = store.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: [])
        XCTAssertTrue(second.isEmpty, "an already-prompted server must not re-prompt")
        XCTAssertEqual(store.pending.map(\.id), ["A"], "but it stays listed as pending")
    }

    func testForgetRemovesEntirely() {        var store = PendingSyncedServersStore(defaults: makeDefaults())
        _ = store.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: [])
        store.ignore("A")
        store.forget("A")
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertFalse(store.ignoredIDs.contains("A"))
    }

    func testDescriptorLeavingHouseholdPrunesBookkeeping() {
        var store = PendingSyncedServersStore(defaults: makeDefaults())
        _ = store.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: [])
        store.ignore("A")
        store.markPrompted(["A"])
        // A removed from the household entirely (no longer synced).
        _ = store.reconcile(syncedDescriptors: [], localAccountIDs: [])
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertFalse(store.ignoredIDs.contains("A"))
        XCTAssertFalse(store.promptedIDs.contains("A"))
    }
}
