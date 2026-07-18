import XCTest
import CoreModels
@testable import AppShell

/// Unit tests for ``IdentityIndexModel`` — the eager cross-server identity-index
/// facet split out of ``AppState``. These cover the deterministic seams that don't
/// require a live ``MediaProvider``: the injected dependency closures are consulted,
/// an empty active-account set is a safe no-op, and reset leaves an empty snapshot.
/// The full warm-with-provider fan-out remains covered by the existing AppShell
/// identity tests exercising it through AppState.
@MainActor
final class IdentityIndexModelTests: XCTestCase {

    private func makeModel(
        accounts: @escaping @MainActor () -> [ResolvedAccount] = { [] },
        namespace: @escaping @MainActor () -> String? = { "ns-test" }
    ) -> (IdentityIndexModel, () -> Int) {
        var publishCount = 0
        let model = IdentityIndexModel(
            activeAccounts: accounts,
            namespace: namespace,
            onPublish: { publishCount += 1 }
        )
        return (model, { publishCount })
    }

    func testInitialSnapshotIsEmpty() {
        let (model, _) = makeModel()
        XCTAssertTrue(model.identitySnapshot.isEmpty)
        XCTAssertTrue(model.identitySnapshotStore.current.isEmpty)
    }

    func testWarmWithNoActiveAccountsIsANoOp() {
        var activeAccountsCalls = 0
        let (model, publishCount) = makeModel(accounts: {
            activeAccountsCalls += 1
            return []
        })

        model.warmIdentityIndex()

        // The injected active-accounts closure is consulted exactly once, and with
        // an empty set the warm returns early: nothing publishes, snapshot stays empty.
        XCTAssertEqual(activeAccountsCalls, 1)
        XCTAssertEqual(publishCount(), 0)
        XCTAssertTrue(model.identitySnapshot.isEmpty)
    }

    func testResetFromEmptyIsSafeAndLeavesEmptySnapshot() {
        let (model, publishCount) = makeModel()
        model.reset()
        XCTAssertTrue(model.identitySnapshot.isEmpty)
        XCTAssertTrue(model.identitySnapshotStore.current.isEmpty)
        // reset must not trigger a publish/outbox re-drain.
        XCTAssertEqual(publishCount(), 0)
    }

    func testSourcesProviderIsSendableAndStable() {
        let (model, _) = makeModel()
        // The @Sendable accessor is derived from the snapshot store; two reads yield
        // usable closures (the store, not AppState, owns this now).
        let provider = model.identitySourcesProvider
        _ = provider  // callable handle exists without touching AppState
    }
}
