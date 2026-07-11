import XCTest
import CoreModels
import FeatureAuth
@testable import AppShell

/// End-to-end coverage for the per-profile "Your Servers & Libraries" master
/// server toggle (Settings → ‹Profile›). The toggle flips a server on/off by
/// including/excluding its account(s) in the active profile's set via
/// `AppState.setAccount(_:includedInActiveProfile:)`, and the switch's on/off
/// state is read straight back from `isAccountIncludedInActiveProfile`.
///
/// Regression guard for the bug where turning a server off — especially the
/// **last** remaining server — did nothing: an intentional empty selection was
/// silently re-expanded to "watch every account", so the switch snapped back on.
@MainActor
final class ServerToggleTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ServerToggleTests.\(UUID().uuidString)"
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

    /// Builds an AppState over in-memory stores seeded with the given accounts.
    private func makeAppState(accountIDs: [(String, String)]) throws -> AppState {
        let store = AccountStore(secureStore: InMemorySecureStore(), defaults: makeDefaults())
        for (id, host) in accountIDs {
            try store.add(account(id: id, host: host), token: "token-\(id)")
        }
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let state = AppState(accountStore: store, profilesModel: profiles)
        state.bootstrap()
        return state
    }

    /// A single-server household: turning it off must stick (this is the case
    /// that was completely dead — the toggle could never leave "On").
    func testTurningOffTheOnlyServerSticks() throws {
        let state = try makeAppState(accountIDs: [("a", "a.example.com")])

        // Default: the only account is active, so the server reads "On".
        XCTAssertTrue(state.isAccountIncludedInActiveProfile("a"))

        // Turn it off.
        state.setAccount("a", includedInActiveProfile: false)
        XCTAssertFalse(
            state.isAccountIncludedInActiveProfile("a"),
            "Turning off the last remaining server must actually turn it off, not snap back on."
        )

        // Turn it back on.
        state.setAccount("a", includedInActiveProfile: true)
        XCTAssertTrue(state.isAccountIncludedInActiveProfile("a"))
    }

    /// The intentional "watch nothing" state must survive a reload (e.g. the
    /// Settings page reappearing / a relaunch), not silently re-expand to all.
    func testEmptySelectionSurvivesReload() throws {
        let state = try makeAppState(accountIDs: [("a", "a.example.com")])
        state.setAccount("a", includedInActiveProfile: false)
        XCTAssertFalse(state.isAccountIncludedInActiveProfile("a"))

        // A fresh bootstrap (relaunch) must preserve the explicit empty choice.
        state.bootstrap()
        XCTAssertFalse(
            state.isAccountIncludedInActiveProfile("a"),
            "An explicit 'watch nothing' selection must persist across reloads."
        )
    }

    /// A multi-server household: toggling one server off leaves the others on,
    /// and the last one can still be turned off.
    func testTurningServersOffIndependently() throws {
        let state = try makeAppState(accountIDs: [
            ("a", "a.example.com"),
            ("b", "b.example.com")
        ])
        XCTAssertTrue(state.isAccountIncludedInActiveProfile("a"))
        XCTAssertTrue(state.isAccountIncludedInActiveProfile("b"))

        state.setAccount("a", includedInActiveProfile: false)
        XCTAssertFalse(state.isAccountIncludedInActiveProfile("a"))
        XCTAssertTrue(state.isAccountIncludedInActiveProfile("b"))

        // Turning off the now-last server must also stick.
        state.setAccount("b", includedInActiveProfile: false)
        XCTAssertFalse(state.isAccountIncludedInActiveProfile("a"))
        XCTAssertFalse(state.isAccountIncludedInActiveProfile("b"))
    }

    /// A profile may retain ids for accounts that were removed and later
    /// re-added. AppState resolves that stale-only selection to the current
    /// household set; toggling must mutate that resolved set, not the stale raw
    /// value, or removing a visible account becomes a no-op.
    func testTurningOffServerRepairsStaleStoredSelection() throws {
        let accountStore = AccountStore(
            secureStore: InMemorySecureStore(),
            defaults: makeDefaults()
        )
        try accountStore.add(account(id: "a", host: "a.example.com"), token: "token-a")
        try accountStore.add(account(id: "b", host: "b.example.com"), token: "token-b")

        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        profiles.setActiveAccountIDs(["removed-account"], for: profiles.activeProfileID)

        let state = AppState(accountStore: accountStore, profilesModel: profiles)
        state.bootstrap()
        XCTAssertTrue(state.isAccountIncludedInActiveProfile("a"))
        XCTAssertTrue(state.isAccountIncludedInActiveProfile("b"))

        state.setAccount("a", includedInActiveProfile: false)

        XCTAssertFalse(state.isAccountIncludedInActiveProfile("a"))
        XCTAssertTrue(state.isAccountIncludedInActiveProfile("b"))
        XCTAssertEqual(
            Set(profiles.storedActiveAccountIDs(for: profiles.activeProfileID) ?? []),
            ["b"]
        )
    }
}
