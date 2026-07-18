import XCTest
import CoreModels
import FeatureAuth
import FeatureProfiles
@testable import AppShell

/// Unit tests for ``PlexHomeUsersModel`` — the Plex Home users / "who's watching"
/// facet split out of ``AppState``. Cover the facet's own deterministic behavior:
/// token resolution prefers a live override, the PIN-cancel fallback routes through
/// the injected `switchProfile`, and account-lifecycle hooks clear per-account
/// state. The full switch/prompt flow (with a stubbed PlexAuthClient) stays covered
/// by ServerToggleTests through AppState.
@MainActor
final class PlexHomeUsersModelTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "PlexHomeUsersModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func plexAccount(id: String) -> Account {
        Account(
            id: id,
            server: MediaServer(
                id: "srv-\(id)",
                name: "Plex \(id)",
                baseURL: URL(string: "https://\(id).plex.tv")!,
                provider: .plex
            ),
            userID: "user-\(id)",
            userName: "User \(id)",
            deviceID: "device"
        )
    }

    private func makeModel(
        accountIDs: [String] = [],
        switchProfile: @escaping @MainActor (String) -> Void = { _ in }
    ) throws -> (PlexHomeUsersModel, AccountsProvidersModel, ProfilesModel) {
        let store = AccountStore(secureStore: InMemorySecureStore())
        for id in accountIDs {
            try store.add(plexAccount(id: id), token: "admin-\(id)")
        }
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let hub = AccountsProvidersModel(
            accountStore: store,
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
        hub.reloadAccounts()
        let model = PlexHomeUsersModel(
            accountsProviders: hub,
            profilesModel: profiles,
            switchProfile: switchProfile
        )
        return (model, hub, profiles)
    }

    func testResolvedTokenFallsBackToAdminTokenWithoutOverride() throws {
        let (model, _, _) = try makeModel(accountIDs: ["a"])
        // No override yet → the stored admin token is used.
        XCTAssertEqual(model.resolvedToken(for: "a"), "admin-a")
        // Unknown account → nil.
        XCTAssertNil(model.resolvedToken(for: "missing"))
    }

    func testCancelPINWithoutAlternateProfileClearsInsteadOfSwitching() throws {
        var switched: [String] = []
        let (model, _, _) = try makeModel(accountIDs: ["a"], switchProfile: { switched.append($0) })
        // With only the default profile, cancel can't switch away — it clears
        // overrides instead and never calls switchProfile.
        model.cancelPlexPIN()
        XCTAssertTrue(switched.isEmpty)
        XCTAssertNil(model.pendingPlexPINRequest)
        XCTAssertNil(model.plexPINError)
    }

    func testPresentAndClearUserSelection() throws {
        let (model, _, _) = try makeModel(accountIDs: ["a"])
        XCTAssertNil(model.pendingPlexUserSelection)
        model.presentUserSelection(
            .init(accountID: "a", serverName: "Plex a", users: [], isFirstRun: true)
        )
        XCTAssertEqual(model.pendingPlexUserSelection?.accountID, "a")
        model.clearUserSelection()
        XCTAssertNil(model.pendingPlexUserSelection)
    }

    func testResetAllForDebugClearsPendingState() throws {
        let (model, _, _) = try makeModel(accountIDs: ["a"])
        model.presentUserSelection(
            .init(accountID: "a", serverName: "Plex a", users: [], isFirstRun: false)
        )
        model.resetAllForDebug()
        XCTAssertNil(model.pendingPlexUserSelection)
        XCTAssertNil(model.pendingPlexPINRequest)
        XCTAssertNil(model.plexPINError)
    }

    func testForgetAccountIsSafeForUnknownID() throws {
        let (model, _, _) = try makeModel(accountIDs: ["a"])
        // Should not crash and should leave token resolution intact for others.
        model.forgetAccount("missing")
        XCTAssertEqual(model.resolvedToken(for: "a"), "admin-a")
    }

    // MARK: Generation-guard regression (stale background-refresh race)

    /// Drains queued main-actor work so a `Task { … }` spawned by the model runs to
    /// completion. Deterministic on the single-threaded main actor.
    private func drainMainActor(_ iterations: Int = 200) async {
        for _ in 0..<iterations { await Task.yield() }
    }

    /// Binds the active profile to an unprotected Home user on `accountID` and lets
    /// the confirming background refresh install + cache its token, so a later
    /// re-scope has an override to move the identity generation off.
    private func installUnprotectedOverride(
        _ model: PlexHomeUsersModel,
        accountID: String,
        userID: String,
        token: String
    ) async {
        model.plexHomeUserSwitch = { uuid, _, _, _ in "acct-\(uuid)" }
        model.plexServerTokenResolve = { _, _, _ in token }
        model.setPlexHomeUserForActiveProfile(
            accountID: accountID,
            user: PlexHomeUser(id: userID, name: userID, requiresPIN: false)
        )
        await drainMainActor()
    }

    /// A background token refresh whose profile was switched out from under it (the
    /// identity generation moved during its network window) must NOT re-install the
    /// old Home-user's token — the staleness guard drops the confirming write.
    func testStaleBackgroundRefreshDoesNotOverwriteNewerIdentity() async throws {
        let (model, _, _) = try makeModel(accountIDs: ["a"])
        // 1) Establish a live override for "old" (generation now > 0, override present).
        await installUnprotectedOverride(model, accountID: "a", userID: "old", token: "tok-old")
        XCTAssertEqual(model.resolvedToken(for: "a"), "tok-old")

        // 2) Re-scope to a DIFFERENT unprotected user, and — mid-refresh, from inside
        //    the injected server-token resolve (which runs right before the guarded
        //    write) — simulate the active profile's binding being dropped. That bumps
        //    the identity generation, so the in-flight refresh's captured generation
        //    goes stale.
        model.plexHomeUserSwitch = { uuid, _, _, _ in "acct-\(uuid)" }
        model.plexServerTokenResolve = { [weak model] _, _, _ in
            await MainActor.run { model?.setPlexHomeUserForActiveProfile(accountID: "a", user: nil) }
            return "tok-new-STALE"
        }
        model.setPlexHomeUserForActiveProfile(
            accountID: "a",
            user: PlexHomeUser(id: "new", name: "new", requiresPIN: false)
        )
        await drainMainActor()

        // The stale refresh dropped its write: the override is gone (fell back to the
        // admin token), and the stale "tok-new-STALE" was never installed.
        XCTAssertEqual(model.resolvedToken(for: "a"), "admin-a")
        XCTAssertNotEqual(model.resolvedToken(for: "a"), "tok-new-STALE")
    }

    /// The guard must NOT false-abort the common case: with no interleaving profile
    /// switch, the background refresh installs/confirms its token normally.
    func testHappyPathRefreshInstallsTokenWhenGenerationStable() async throws {
        let (model, _, _) = try makeModel(accountIDs: ["a"])
        model.plexHomeUserSwitch = { uuid, _, _, _ in "acct-\(uuid)" }
        model.plexServerTokenResolve = { _, _, _ in "tok-happy" }
        model.setPlexHomeUserForActiveProfile(
            accountID: "a",
            user: PlexHomeUser(id: "solo", name: "solo", requiresPIN: false)
        )
        await drainMainActor()

        // Generation was stable through the refresh → the confirming write proceeded.
        XCTAssertEqual(model.resolvedToken(for: "a"), "tok-happy")
    }

    /// A failing Home-users fetch is logged (see PlozzLog.auth) but still honours the
    /// `[]` contract — an empty picker instead of a crash.
    func testPlexHomeUsersReturnsEmptyOnFetchFailure() async throws {
        struct FetchError: Error {}
        let (model, _, _) = try makeModel(accountIDs: ["a"])
        model.plexHomeUsersFetch = { _, _ in throw FetchError() }
        let users = await model.plexHomeUsers(forAccountID: "a")
        XCTAssertTrue(users.isEmpty)
    }
}
