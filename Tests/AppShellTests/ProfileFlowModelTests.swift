import XCTest
import CoreModels
import FeatureAuth
import FeatureMusic
@testable import AppShell

/// Unit tests for ``ProfileFlowModel`` — the profile-flow + household facet split
/// out of ``AppState``. Cover the picker-state machine (request / cancel / launch
/// picker / new-profile theme) deterministically. The full switch/save/remove and
/// household-membership orchestration stays covered end-to-end by ServerToggleTests,
/// which now exercises it through `state.profileFlow.*`.
@MainActor
final class ProfileFlowModelTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "ProfileFlowModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeModel() -> (ProfileFlowModel, ProfilesModel) {
        let store = AccountStore(secureStore: InMemorySecureStore())
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let hub = AccountsProvidersModel(
            accountStore: store,
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
        let plex = PlexHomeUsersModel(
            accountsProviders: hub,
            profilesModel: profiles,
            switchProfile: { _ in }
        )
        let settings = ProfileSettingsModel(namespace: profiles.activeNamespace)
        let model = ProfileFlowModel(
            profilesModel: profiles,
            accountsProviders: hub,
            plexHomeUsers: plex,
            profileSettings: settings,
            audioController: AudioPlaybackController(),
            updateTrackersForActiveProfile: {},
            discardWatchReconciler: { _ in }
        )
        return (model, profiles)
    }

    func testRequestAndCancelSelectionTogglePickerState() {
        let (model, _) = makeModel()
        XCTAssertFalse(model.isChoosingProfile)

        model.requestProfileSelection()
        XCTAssertTrue(model.isChoosingProfile)
        XCTAssertTrue(model.isProfileSelectionCancelable)

        model.cancelProfileSelection()
        XCTAssertFalse(model.isChoosingProfile)
    }

    func testPrepareLaunchPickerHiddenForSingleProfile() {
        let (model, _) = makeModel()
        // A brand-new household has one (default) profile → no launch picker,
        // and the launch picker is always mandatory (not cancelable).
        model.prepareLaunchPicker()
        XCTAssertFalse(model.isChoosingProfile)
        XCTAssertFalse(model.isProfileSelectionCancelable)
    }

    func testPrepareLaunchPickerShownWhenAskOnStartupWithMultipleProfiles() {
        let (model, profiles) = makeModel()
        profiles.enableProfiles()
        _ = profiles.add(name: "Second", avatarSymbol: "person", colorIndex: 1)
        profiles.setAskProfileOnStartup(true)

        model.prepareLaunchPicker()
        XCTAssertTrue(model.isChoosingProfile)
        XCTAssertFalse(model.isProfileSelectionCancelable)
    }

    func testFinishPickingThemeForNewProfileNoOpsWhenNotPicking() {
        let (model, _) = makeModel()
        // Not in the new-profile theme step → returns false and stays put.
        XCTAssertFalse(model.finishPickingThemeForNewProfile())
        XCTAssertFalse(model.isPickingThemeForNewProfile)
    }

    func testDismissPickerClearsChoosingState() {
        let (model, _) = makeModel()
        model.requestProfileSelection()
        XCTAssertTrue(model.isChoosingProfile)
        model.dismissPicker()
        XCTAssertFalse(model.isChoosingProfile)
    }

    // MARK: Orchestration (removeProfile / setAccount / switchProfile) unit coverage

    private struct Env {
        let flow: ProfileFlowModel
        let profiles: ProfilesModel
        let hub: AccountsProvidersModel
        let plex: PlexHomeUsersModel
        let store: AccountStore
    }

    private func account(id: String, provider: ProviderKind) -> Account {
        Account(
            id: id,
            server: MediaServer(
                id: "srv-\(id)",
                name: id,
                baseURL: URL(string: "https://\(id).example.com")!,
                provider: provider
            ),
            userID: "user-\(id)",
            userName: "User \(id)",
            deviceID: "device"
        )
    }

    private func makeEnv(
        accounts: [(String, ProviderKind)] = [],
        updateTrackers: @escaping @MainActor () -> Void = {},
        discardReconciler: @escaping @MainActor (String) -> Void = { _ in }
    ) throws -> Env {
        let store = AccountStore(secureStore: InMemorySecureStore())
        for (id, prov) in accounts {
            try store.add(account(id: id, provider: prov), token: "admin-\(id)")
        }
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let hub = AccountsProvidersModel(
            accountStore: store,
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
        let plex = PlexHomeUsersModel(
            accountsProviders: hub,
            profilesModel: profiles,
            switchProfile: { _ in }
        )
        let settings = ProfileSettingsModel(namespace: profiles.activeNamespace)
        let flow = ProfileFlowModel(
            profilesModel: profiles,
            accountsProviders: hub,
            plexHomeUsers: plex,
            profileSettings: settings,
            audioController: AudioPlaybackController(),
            updateTrackersForActiveProfile: updateTrackers,
            discardWatchReconciler: discardReconciler
        )
        return Env(flow: flow, profiles: profiles, hub: hub, plex: plex, store: store)
    }

    private func drainMainActor(_ iterations: Int = 200) async {
        for _ in 0..<iterations { await Task.yield() }
    }

    /// Installs a live unprotected Plex Home-user override for the ACTIVE profile on
    /// `accountID`, so a later re-scope has an override to drop.
    private func installActiveOverride(_ env: Env, accountID: String) async {
        env.plex.plexHomeUserSwitch = { uuid, _, _, _ in "acct-\(uuid)" }
        env.plex.plexServerTokenResolve = { _, _, _ in "override-\(accountID)" }
        env.plex.setPlexHomeUserForActiveProfile(
            accountID: accountID,
            user: PlexHomeUser(id: "hu-\(accountID)", name: "HU", requiresPIN: false)
        )
        await drainMainActor()
    }

    /// Regression for the fix: removing the ACTIVE profile must re-apply the
    /// FALLBACK's Plex identity (ensurePlexIdentityForActiveProfile). The removed
    /// profile held a Home-user token override the fallback doesn't want, so after
    /// removal that override must be dropped (proving ensure ran) — without the fix
    /// it would linger on the fallback until the next explicit switch.
    func testRemoveActiveProfileReAppliesFallbackPlexIdentity() async throws {
        let env = try makeEnv(accounts: [("a", .plex)])
        env.store.setActiveAccountIDs(["a"])
        let fallbackID = env.profiles.activeProfileID          // the default profile
        let second = env.profiles.add(name: "Second")
        env.profiles.select(second.id)
        env.hub.reloadAccounts()

        await installActiveOverride(env, accountID: "a")
        XCTAssertEqual(env.plex.resolvedToken(for: "a"), "override-a")

        env.flow.removeProfile(id: second.id)

        // Fallback selected AND its (binding-less) identity re-applied → the removed
        // profile's stale override is gone (resolvedToken falls back to the admin token).
        XCTAssertEqual(env.profiles.activeProfileID, fallbackID)
        XCTAssertEqual(env.plex.resolvedToken(for: "a"), "admin-a")
    }

    /// Removing a NON-active profile must not re-scope the active one: no tracker
    /// re-point, active profile + its settings unchanged, only the target is gone.
    func testRemoveNonActiveProfileDoesNotReScope() throws {
        var trackerReScopes = 0
        let env = try makeEnv(updateTrackers: { trackerReScopes += 1 })
        let activeID = env.profiles.activeProfileID
        let other = env.profiles.add(name: "Other")   // not selected → non-active

        env.flow.removeProfile(id: other.id)

        XCTAssertEqual(env.profiles.activeProfileID, activeID, "active profile unchanged")
        XCTAssertFalse(env.profiles.profiles.contains { $0.id == other.id }, "target removed")
        XCTAssertEqual(trackerReScopes, 0, "non-active removal must not re-scope trackers")
    }

    /// The documented anti-stale logic in `setAccount(_:includedInActiveProfile:)`:
    /// it mutates the RESOLVED active set, not the raw stored set. With a stale
    /// stored set (all stored ids gone → reload fell back to the global set),
    /// toggling a visible account OFF must actually remove it — not no-op on the
    /// stale set and then re-expand to every account on the next reload.
    func testSetAccountTogglesResolvedSetNotStaleStoredSet() throws {
        let env = try makeEnv(accounts: [("a", .jellyfin), ("b", .jellyfin)])
        env.store.setActiveAccountIDs(["a", "b"])                       // global = {a,b}
        // Stored set is entirely stale (references a since-removed account), so
        // reloadAccounts resolves via the global-set fallback to {a,b}.
        env.profiles.setActiveAccountIDs(["stale-removed"], for: env.profiles.activeProfileID)
        env.hub.reloadAccounts()
        XCTAssertTrue(env.flow.isAccountIncludedInActiveProfile("a"))
        XCTAssertTrue(env.flow.isAccountIncludedInActiveProfile("b"))

        env.flow.setAccount("a", includedInActiveProfile: false)

        // Toggling "a" off must stick (operated on the resolved {a,b}); a stored-set
        // implementation would no-op then re-expand to {a,b}, leaving "a" ON.
        XCTAssertFalse(env.flow.isAccountIncludedInActiveProfile("a"))
        XCTAssertTrue(env.flow.isAccountIncludedInActiveProfile("b"))
    }

    /// switchProfile runs the full re-scope: selects the target, re-points trackers,
    /// dismisses the picker, and re-applies the target's Plex identity (dropping the
    /// previous profile's override since the target has no binding).
    func testSwitchProfileRunsFullReScopeIncludingPlexEnsure() async throws {
        var trackerReScopes = 0
        let env = try makeEnv(accounts: [("a", .plex)], updateTrackers: { trackerReScopes += 1 })
        env.store.setActiveAccountIDs(["a"])
        let second = env.profiles.add(name: "Second")
        env.hub.reloadAccounts()

        // Install an override under the CURRENT (default) profile.
        await installActiveOverride(env, accountID: "a")
        XCTAssertEqual(env.plex.resolvedToken(for: "a"), "override-a")
        let trackersBefore = trackerReScopes

        env.flow.requestProfileSelection()      // opens the picker
        env.flow.switchProfile(to: second.id)

        XCTAssertEqual(env.profiles.activeProfileID, second.id, "target selected")
        XCTAssertFalse(env.flow.isChoosingProfile, "picker dismissed")
        XCTAssertEqual(trackerReScopes, trackersBefore + 1, "trackers re-pointed once")
        // ensure ran: the previous profile's override dropped (target has no binding).
        XCTAssertEqual(env.plex.resolvedToken(for: "a"), "admin-a")
    }
}
