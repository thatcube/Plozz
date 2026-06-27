import XCTest
import CoreModels
@testable import FeatureHome

/// Verifies `HomeViewModel` seeds its skeleton layout from the persisted store
/// and writes back the layout the view reports — the mechanism that makes the
/// next launch's loading skeleton match the user's real Home.
@MainActor
final class HomeViewModelLayoutTests: XCTestCase {
    private func makeAccount() -> ResolvedAccount {
        let server = MediaServer(id: "srv", name: "Home", baseURL: URL(string: "http://host")!, provider: .jellyfin)
        let account = Account(id: "a", server: server, userID: "u", userName: "Me", deviceID: "d")
        return ResolvedAccount(account: account, provider: FakeMediaProvider(allItems: []))
    }

    func testSkeletonLayoutFallsBackToDefaultWhenStoreEmpty() {
        let vm = HomeViewModel(accounts: [makeAccount()], layoutStore: InMemoryHomeLayoutStore())
        XCTAssertEqual(vm.skeletonLayout, HomeRowKind.defaultSkeletonLayout)
    }

    func testSkeletonLayoutRestoredFromStore() {
        let persisted: [HomeRowKind] = [.continueWatching, .libraries]
        let vm = HomeViewModel(accounts: [makeAccount()], layoutStore: InMemoryHomeLayoutStore(persisted))
        XCTAssertEqual(vm.skeletonLayout, persisted)
    }

    func testRememberLayoutPersistsAndUpdates() {
        let store = InMemoryHomeLayoutStore()
        let vm = HomeViewModel(accounts: [makeAccount()], layoutStore: store)
        let rendered: [HomeRowKind] = [.continueWatching, .recentlyAdded]
        vm.rememberLayout(rendered)
        XCTAssertEqual(vm.skeletonLayout, rendered)
        XCTAssertEqual(store.load(), rendered)
    }

    func testRememberLayoutIsNoOpWhenUnchanged() {
        let persisted: [HomeRowKind] = [.continueWatching, .libraries]
        let store = InMemoryHomeLayoutStore(persisted)
        let vm = HomeViewModel(accounts: [makeAccount()], layoutStore: store)
        // Saving the same structure should leave it intact (and not throw/clear).
        vm.rememberLayout(persisted)
        XCTAssertEqual(vm.skeletonLayout, persisted)
        XCTAssertEqual(store.load(), persisted)
    }
}
