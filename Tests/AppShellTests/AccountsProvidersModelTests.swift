import XCTest
import CoreModels
import FeatureAuth
@testable import AppShell

/// Unit tests for ``AccountsProvidersModel`` — the accounts + providers hub split
/// out of ``AppState``. Cover the hub's own behavior over in-memory stores:
/// `reloadAccounts` loads accounts and recomputes the active set, the
/// `onActiveAccountsChanged` hook fires with the resolved set, provider resolution
/// gates on the injected token seam, and the profile/device delegations hold.
/// The full active-set resolution matrix (explicit choice vs. fallback) stays
/// covered end-to-end by ServerToggleTests through AppState.
@MainActor
final class AccountsProvidersModelTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "AccountsProvidersModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func account(id: String, host: String) -> Account {
        Account(
            id: id,
            server: MediaServer(
                id: "srv-\(id)",
                name: host,
                baseURL: URL(string: "https://\(host)")!,
                provider: .jellyfin
            ),
            userID: "user-\(id)",
            userName: "User \(id)",
            deviceID: "device"
        )
    }

    private func makeModel(accountIDs: [(String, String)]) throws -> (AccountsProvidersModel, AccountStore, ProfilesModel) {
        let store = AccountStore(secureStore: InMemorySecureStore())
        for (id, host) in accountIDs {
            try store.add(account(id: id, host: host), token: "token-\(id)")
        }
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let model = AccountsProvidersModel(
            accountStore: store,
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
        return (model, store, profiles)
    }

    func testReloadAccountsLoadsAccountsAndFiresHook() throws {
        let (model, _, _) = try makeModel(accountIDs: [("a", "a.example.com"), ("b", "b.example.com")])

        var hookResolved: Set<String>?
        var hookAccountsCount: Int?
        model.onActiveAccountsChanged = { resolved, accounts in
            hookResolved = resolved
            hookAccountsCount = accounts.count
        }

        XCTAssertTrue(model.accounts.isEmpty)
        model.reloadAccounts()

        XCTAssertEqual(Set(model.accounts.map(\.id)), ["a", "b"])
        // The hook fires exactly with the recomputed active set + full account list.
        XCTAssertEqual(hookResolved, model.activeAccountIDs)
        XCTAssertEqual(hookAccountsCount, 2)
        // The resolved active set is a subset of the known accounts.
        XCTAssertTrue(model.activeAccountIDs.isSubset(of: ["a", "b"]))
    }

    func testProviderResolutionGatesOnTokenSeam() throws {
        let (model, _, _) = try makeModel(accountIDs: [("a", "a.example.com")])
        model.reloadAccounts()

        // No token → nil, before the registry is even consulted.
        model.tokenResolver = { _ in nil }
        XCTAssertNil(model.provider(forAccountID: "a"))
        // Unknown account id → nil regardless of the token seam.
        model.tokenResolver = { _ in "tok" }
        XCTAssertNil(model.provider(forAccountID: "does-not-exist"))
    }

    func testDeviceIDDelegatesToStore() throws {
        let (model, store, _) = try makeModel(accountIDs: [])
        XCTAssertEqual(model.deviceID, store.deviceID())
    }

    func testPrimaryActiveAccountFallsBackToFirst() throws {
        let (model, _, _) = try makeModel(accountIDs: [("a", "a.example.com"), ("b", "b.example.com")])
        model.reloadAccounts()
        // Even if the active set were empty, primaryActiveAccount falls back to the
        // first account so the signed-in UI is never empty.
        XCTAssertNotNil(model.primaryActiveAccount)
        XCTAssertTrue(["a", "b"].contains(model.primaryActiveAccount!.id))
    }

    // MARK: Active-set resolution matrix (reloadAccounts)
    // The hub is the sole authority for account-set resolution. These unit-test
    // the three explicit-choice branches directly on the hub (previously only
    // covered end-to-end via ServerToggleTests through AppState), driving them
    // through the same injected profilesModel/accountStore seams.

    /// (a) An explicit EMPTY choice is honored — "watch nothing" / master toggle
    /// off — and must NOT be silently re-expanded to the household-global set.
    func testReloadHonorsExplicitEmptyChoice() throws {
        let (model, _, profiles) = try makeModel(accountIDs: [("a", "a.example.com"), ("b", "b.example.com")])
        // The profile explicitly chose to watch nothing.
        profiles.setActiveAccountIDs([], for: profiles.activeProfileID)

        model.reloadAccounts()

        XCTAssertTrue(model.activeAccountIDs.isEmpty)
    }

    /// (b) An explicit choice whose accounts have ALL gone stale falls back to the
    /// household-global active set (so a profile isn't left permanently blank by a
    /// removal it didn't make) — not to empty.
    func testReloadFallsBackToGlobalWhenAllChosenAreStale() throws {
        let (model, store, profiles) = try makeModel(accountIDs: [("a", "a.example.com"), ("b", "b.example.com")])
        // Household-global active set is just "b".
        store.setActiveAccountIDs(["b"])
        // The profile's explicit choice references only accounts that no longer exist.
        profiles.setActiveAccountIDs(["gone-1", "gone-2"], for: profiles.activeProfileID)

        model.reloadAccounts()

        // Falls back to the global set (filtered to known), NOT empty, NOT all.
        XCTAssertEqual(model.activeAccountIDs, ["b"])
    }

    /// (c) An explicit choice where only SOME chosen accounts survive honors
    /// exactly the survivors — it does not fall back to the global set.
    func testReloadHonorsSurvivingSubsetOfExplicitChoice() throws {
        let (model, store, profiles) = try makeModel(accountIDs: [("a", "a.example.com"), ("b", "b.example.com")])
        // Global set is everything, to prove we do NOT fall back to it here.
        store.setActiveAccountIDs(["a", "b"])
        // The profile chose "a" plus an account that no longer exists.
        profiles.setActiveAccountIDs(["a", "gone"], for: profiles.activeProfileID)

        model.reloadAccounts()

        // Exactly the surviving chosen account — not the global {a, b}.
        XCTAssertEqual(model.activeAccountIDs, ["a"])
    }
}
