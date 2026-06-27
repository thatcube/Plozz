import XCTest
import CoreModels
@testable import FeatureHome

/// Verifies `HomeViewModel.loadIfNeeded(excludedKeys:)` reloads only on a first
/// load or a genuine hidden-library change — not on every view reappearance.
///
/// tvOS cancels and restarts a `.task(id:)` each time Home returns from a pushed
/// detail, so an unguarded reload flashed the loading skeleton and reset focus to
/// the top on every back-navigation. These tests lock in the idempotent guard
/// that fixed it.
@MainActor
final class HomeViewModelLoadIfNeededTests: XCTestCase {
    private func makeViewModel(
        provider: FakeMediaProvider,
        currentExcluded: @escaping () -> Set<String>
    ) -> HomeViewModel {
        let server = MediaServer(id: "srv", name: "Home", baseURL: URL(string: "http://host")!, provider: .jellyfin)
        let account = Account(id: "a", server: server, userID: "u", userName: "Me", deviceID: "d")
        let resolved = ResolvedAccount(account: account, provider: provider)
        return HomeViewModel(
            accounts: [resolved],
            layoutStore: InMemoryHomeLayoutStore(),
            currentVisibility: { HomeLibraryVisibility(excludedKeys: currentExcluded()) }
        )
    }

    func testReappearanceWithSameVisibilityDoesNotReload() async {
        let provider = FakeMediaProvider(allItems: [])
        let vm = makeViewModel(provider: provider) { [] }

        // First appearance: aggregates once.
        await vm.loadIfNeeded(excludedKeys: [])
        XCTAssertEqual(provider.librariesCallCount, 1)

        // Two more "reappearances" (back-navigation re-fires the task) with the
        // same hidden-library set must be no-ops — no re-aggregation.
        await vm.loadIfNeeded(excludedKeys: [])
        await vm.loadIfNeeded(excludedKeys: [])
        XCTAssertEqual(provider.librariesCallCount, 1)
    }

    func testVisibilityChangeTriggersReload() async {
        var excluded: Set<String> = []
        let provider = FakeMediaProvider(allItems: [])
        let vm = makeViewModel(provider: provider) { excluded }

        await vm.loadIfNeeded(excludedKeys: excluded)
        XCTAssertEqual(provider.librariesCallCount, 1)

        // The user hides a library: the set changes, so Home re-aggregates.
        excluded = ["a:lib1"]
        await vm.loadIfNeeded(excludedKeys: excluded)
        XCTAssertEqual(provider.librariesCallCount, 2)

        // Reappearance with the new set is again a no-op.
        await vm.loadIfNeeded(excludedKeys: excluded)
        XCTAssertEqual(provider.librariesCallCount, 2)
    }
}
