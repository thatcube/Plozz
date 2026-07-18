import Foundation
import Observation
import CoreModels
import CoreNetworking
import FeatureAuth
import FeatureProfiles
import ProviderPlex

/// The Plex Home users ("Who's watching?") facet, extracted from `AppState`.
///
/// Owns the in-memory Plex Home-user identity: per-account auth-token overrides
/// and their credential revisions, the resolved-home-user map, the unprotected-
/// token cache, the PIN-prompt state, and the "which Plex user are you?" onboarding
/// selection. It drives switching the active profile's Plex identity across every
/// signed-in Plex account (unprotected switches happen silently; the first
/// protected one raises a PIN prompt).
///
/// It depends INTO the `AccountsProvidersModel` hub via that hub's typed interface
/// (account store, device id, accounts, registry invalidation) — which is why the
/// hub was extracted first — plus the shared `ProfilesModel` and a `switchProfile`
/// callback for the PIN-cancel fallback. Kept `@MainActor @Observable` so the PIN
/// state and `plexIdentityGeneration` observation is identical to when it lived on
/// `AppState`.
@MainActor
@Observable
public final class PlexHomeUsersModel {
    /// Context for the "Which Plex user are you?" onboarding step.
    public struct PendingPlexUserSelection: Equatable, Sendable {
        public let accountID: String
        public let serverName: String
        public let users: [PlexHomeUser]
        /// Whether this selection is happening during a brand-new-install first
        /// run (drives whether we continue to profile-setup or the app).
        public let isFirstRun: Bool

        public init(accountID: String, serverName: String, users: [PlexHomeUser], isFirstRun: Bool) {
            self.accountID = accountID
            self.serverName = serverName
            self.users = users
            self.isFirstRun = isFirstRun
        }
    }

    /// A profile activation waiting on a Plex Home user's PIN.
    public struct PlexPINRequest: Identifiable, Equatable, Sendable {
        /// The id of the profile being activated.
        public let id: String
        public let accountID: String
        public let homeUserID: String
        public let homeUserName: String
        /// Optional Plex thumb URL for the Home user — used by the PIN
        /// dialog to render the real avatar above the keypad, like Plex's
        /// own tvOS PIN screen.
        public let homeUserAvatarURL: String?

        public init(
            id: String,
            accountID: String,
            homeUserID: String,
            homeUserName: String,
            homeUserAvatarURL: String? = nil
        ) {
            self.id = id
            self.accountID = accountID
            self.homeUserID = homeUserID
            self.homeUserName = homeUserName
            self.homeUserAvatarURL = homeUserAvatarURL
        }
    }

    /// A pending Plex PIN prompt, raised when activating a profile mapped to a
    /// PIN-protected Plex Home user. `RootView` presents an entry sheet bound to
    /// this; `nil` when no prompt is outstanding.
    public private(set) var pendingPlexPINRequest: PlexPINRequest?
    /// A wrong/failed-PIN message shown in the entry sheet, or `nil`.
    public private(set) var plexPINError: String?
    /// Bumped whenever the active Plex identity (token override) changes so
    /// `RootView` rebuilds the signed-in subtree and content reloads as the new
    /// Plex Home user.
    public private(set) var plexIdentityGeneration = 0
    /// A pending "Which Plex user are you?" step, populated after a Plex account
    /// with 2+ Home users signs in (and this profile hasn't bound one yet).
    /// `RootView` presents the picker bound to this; `nil` when none is pending.
    public private(set) var pendingPlexUserSelection: PendingPlexUserSelection?

    /// In-memory Plex auth-token overrides keyed by `Account.id`. Set when the
    /// active profile maps to a non-owner Plex Home user so providers resolve as
    /// that user. **PIN-protected** users are never persisted — their token must
    /// not survive relaunch, so Plozz re-prompts each launch. **Unprotected**
    /// users are seeded synchronously from `plexHomeUserTokenCache` (see below)
    /// so their identity paints instantly without the startup double-load.
    @ObservationIgnored
    private var plexTokenOverrides: [String: String] = [:]
    /// Runtime revision for the effective Plex Home-user credential. Owner
    /// credentials continue to use the account's persisted revision.
    @ObservationIgnored
    private var plexOverrideCredentialRevisions: [String: CredentialRevision] = [:]
    /// For each account, the Plex Home-user UUID the current override resolves to.
    /// Lets the reconciler tell an already-satisfied protected switch apart from a
    /// stale override left by a previous profile, so a just-entered PIN isn't
    /// re-armed into an infinite prompt/re-prompt loop.
    @ObservationIgnored
    private var plexResolvedHomeUser: [String: String] = [:]
    /// Keychain-backed cache of resolved server tokens for **unprotected** Plex
    /// Home users. Lets `ensurePlexIdentityForActiveProfile` install the right
    /// identity synchronously at launch/profile-pick (instant, ungated paint),
    /// then refresh it in the background. PIN-protected users are never cached.
    @ObservationIgnored
    private let plexHomeUserTokenCache: PlexHomeUserTokenCache

    /// The accounts + providers hub (typed). Read for the account store, device
    /// id, signed-in accounts, and per-account provider-cache invalidation.
    @ObservationIgnored
    private let accountsProviders: AccountsProvidersModel
    /// The household's profiles + active selection (shared reference).
    @ObservationIgnored
    private let profilesModel: ProfilesModel
    /// Switches the active profile — used by the PIN-cancel fallback so the UI is
    /// never left under a profile the user couldn't unlock. Injected because
    /// profile switching lives on `AppState` (profile-flow domain).
    @ObservationIgnored
    private let switchProfile: @MainActor (String) -> Void

    /// Switches to a Plex Home user, returning the new auth token. Injectable for
    /// tests; defaults to a live `PlexAuthClient` call.
    @ObservationIgnored
    var plexHomeUserSwitch: @Sendable (_ uuid: String, _ pin: String?, _ adminToken: String, _ deviceID: String) async throws -> String = { uuid, pin, adminToken, deviceID in
        try await PlexAuthClient(deviceProfile: PlexDeviceProfile(clientIdentifier: deviceID))
            .switchHomeUser(uuid: uuid, pin: pin, authToken: adminToken)
    }
    /// Lists a Plex account's Home users. Injectable for tests; defaults to a
    /// live `PlexAuthClient` call.
    @ObservationIgnored
    var plexHomeUsersFetch: @Sendable (_ adminToken: String, _ deviceID: String) async throws -> [PlexHomeUser] = { adminToken, deviceID in
        try await PlexAuthClient(deviceProfile: PlexDeviceProfile(clientIdentifier: deviceID))
            .homeUsers(authToken: adminToken)
    }
    /// Resolves the **server-scoped** access token for `serverID` from a Plex
    /// account/Home-user token, by asking plex.tv (`/api/v2/resources`) for that
    /// user's access to the server. Injectable for tests; defaults to a live
    /// `PlexAuthClient` call. Returns `nil` when the user has no access to the
    /// server (or the lookup fails), so callers can fall back to the raw token.
    @ObservationIgnored
    var plexServerTokenResolve: @Sendable (_ serverID: String, _ userToken: String, _ deviceID: String) async -> String? = { serverID, userToken, deviceID in
        let client = PlexAuthClient(deviceProfile: PlexDeviceProfile(clientIdentifier: deviceID))
        let servers = try? await client.servers(authToken: userToken)
        return servers?.first { $0.id == serverID }?.accessToken
    }

    init(
        accountsProviders: AccountsProvidersModel,
        profilesModel: ProfilesModel,
        plexHomeUserTokenCache: PlexHomeUserTokenCache = .makeDefault(),
        switchProfile: @escaping @MainActor (String) -> Void
    ) {
        self.accountsProviders = accountsProviders
        self.profilesModel = profilesModel
        self.plexHomeUserTokenCache = plexHomeUserTokenCache
        self.switchProfile = switchProfile
    }

    // MARK: Token / credential resolution (the AccountsProviders hub seams)

    /// The auth token to use for `accountID`, preferring an in-memory Plex
    /// Home-user override over the account's stored (admin) token.
    public func resolvedToken(for accountID: String) -> String? {
        plexTokenOverrides[accountID] ?? accountsProviders.accountStore.token(for: accountID)
    }

    /// The effective credential revision for an account, using an override-scoped
    /// revision when a Plex Home-user override is active.
    public func effectiveCredentialRevision(for account: Account) -> CredentialRevision {
        guard account.server.provider == .plex,
              plexTokenOverrides[account.id] != nil else {
            return account.credentialRevision
        }
        if let revision = plexOverrideCredentialRevisions[account.id] {
            return revision
        }
        let revision = CredentialRevision()
        plexOverrideCredentialRevisions[account.id] = revision
        return revision
    }

    private func setPlexTokenOverride(_ token: String?, for accountID: String) {
        if plexTokenOverrides[accountID] != token {
            plexOverrideCredentialRevisions[accountID] = token == nil
                ? nil
                : CredentialRevision()
        }
        plexTokenOverrides[accountID] = token
    }

    // MARK: Plex Home users ("Who's watching?")

    /// Lists the Plex Home users for a signed-in Plex account (for the profile
    /// editor's "Plex User" picker). Returns `[]` for non-Plex/unknown accounts
    /// or on failure. Always uses the account's stored (admin) token.
    public func plexHomeUsers(forAccountID accountID: String) async -> [PlexHomeUser] {
        guard let account = accountsProviders.accounts.first(where: { $0.id == accountID }),
              account.server.provider == .plex,
              let adminToken = accountsProviders.accountStore.token(for: accountID) else { return [] }
        // Log a fetch failure instead of swallowing it silently — an empty picker
        // then reads as a real error, not indistinguishable from "no Home users".
        // Contract unchanged: still returns [] on failure.
        do {
            return try await plexHomeUsersFetch(adminToken, accountsProviders.deviceID)
        } catch {
            PlozzLog.auth.error("Plex Home-users fetch failed acct=\(accountID): \(error)")
            return []
        }
    }

    /// Links the active profile to a specific Plex Home user (or clears the
    /// link when `user` is `nil`, falling back to the account's admin user).
    /// Writes through to the profile, then re-applies the Plex identity so the
    /// switch takes effect immediately (a protected user triggers the PIN
    /// prompt via `ensurePlexIdentityForActiveProfile`).
    public func setPlexHomeUserForActiveProfile(accountID: String, user: PlexHomeUser?) {
        let profile = profilesModel.activeProfile
        let binding: PlexHomeUserBinding? = user.map {
            PlexHomeUserBinding(
                homeUserID: $0.id,
                name: $0.name,
                avatarURL: $0.avatarURL?.absoluteString,
                requiresPIN: $0.requiresPIN
            )
        }
        let updated = profile.settingHomeUserBinding(binding, forPlexAccount: accountID)
        profilesModel.update(updated)
        ensurePlexIdentityForActiveProfile()
    }

    /// Submits a PIN for the outstanding Plex Home-user switch.
    public func submitPlexPIN(_ pin: String) {
        guard let request = pendingPlexPINRequest else { return }
        PlozzLog.auth.debug("submitPlexPIN len=\(pin.count) acct=\(request.accountID)")
        plexPINError = nil
        Task { await performPlexSwitch(accountID: request.accountID, homeUserID: request.homeUserID, pin: pin) }
    }

    /// Cancels the outstanding Plex PIN prompt, reverting to the default profile
    /// so the UI isn't left under a profile the user couldn't unlock.
    public func cancelPlexPIN() {
        pendingPlexPINRequest = nil
        plexPINError = nil
        if let fallback = profilesModel.profiles.first?.id,
           fallback != profilesModel.activeProfileID {
            switchProfile(fallback)
        } else {
            clearPlexOverrides()
        }
    }

    /// Treats a programmatic sheet dismissal as a cancel **only** when a prompt
    /// is still outstanding (a successful switch already cleared it).
    public func dismissPlexPINIfPresented() {
        if pendingPlexPINRequest != nil { cancelPlexPIN() }
    }

    /// Aligns the in-memory Plex identity for **every** signed-in Plex account
    /// with the active profile's per-account Home-user bindings:
    /// - Unprotected bindings switch silently on each account.
    /// - The first protected binding (in account order) raises a PIN prompt;
    ///   subsequent ones are processed after the user submits or cancels.
    /// - An account with no binding drops any existing override for that
    ///   account (back to the admin user).
    public func ensurePlexIdentityForActiveProfile() {
        let profile = profilesModel.activeProfile
        let plexAccounts = accountsProviders.accounts.filter { $0.server.provider == .plex }
        let boundCount = plexAccounts.filter { profile.homeUserBinding(forPlexAccount: $0.id) != nil }.count
        PlozzLog.boot("ensurePlexIdentity profile=\(profile.id) plexAccounts=\(plexAccounts.count) withBinding=\(boundCount) gen=\(self.plexIdentityGeneration)")

        var pinTarget: (accountID: String, binding: PlexHomeUserBinding)?

        for account in plexAccounts {
            if let binding = profile.homeUserBinding(forPlexAccount: account.id) {
                if binding.requiresPIN == true {
                    // A protected user must never have a token sitting at rest;
                    // if it was previously unprotected and cached, drop it now.
                    plexHomeUserTokenCache.remove(account: account.id, homeUser: binding.homeUserID)
                    // Already resolved to exactly this user? It's satisfied —
                    // leave it, don't re-prompt. (Was the source of the
                    // re-entrancy loop: success cleared the override, the
                    // reconciler immediately re-prompted, cover never tore down.)
                    if plexTokenOverrides[account.id] != nil,
                       plexResolvedHomeUser[account.id] == binding.homeUserID {
                        continue
                    }
                    // Stale override for a DIFFERENT user — drop before prompting.
                    if plexTokenOverrides[account.id] != nil {
                        setPlexTokenOverride(nil, for: account.id)
                        plexResolvedHomeUser[account.id] = nil
                        accountsProviders.registry.invalidate(accountID: account.id)
                        plexIdentityGeneration += 1
                        PlozzLog.boot("genBump=\(self.plexIdentityGeneration) site=ensure.staleOverride acct=\(account.id)")
                    }
                    if pinTarget == nil {
                        pinTarget = (account.id, binding)
                    }
                } else {
                    // Unprotected Home user. If we're already resolved to exactly
                    // this user this session, there's nothing to do (and no need
                    // for another background refresh — one already ran).
                    if plexTokenOverrides[account.id] != nil,
                       plexResolvedHomeUser[account.id] == binding.homeUserID {
                        continue
                    }
                    // Seed the cached token synchronously so the signed-in subtree
                    // paints immediately with the correct identity. On a cache hit
                    // this is the whole switch — no network on the launch path, and
                    // the background refresh below confirms the token (usually
                    // unchanged → no reload). On a cache miss (first launch for this
                    // Home user) Home paints fast with the admin token and reloads
                    // once when the switch lands; that token is then cached so it
                    // never happens again.
                    if let cached = plexHomeUserTokenCache.token(account: account.id, homeUser: binding.homeUserID) {
                        setPlexTokenOverride(cached, for: account.id)
                        plexResolvedHomeUser[account.id] = binding.homeUserID
                        accountsProviders.registry.invalidate(accountID: account.id)
                        PlozzLog.boot("ensure.cachedOverride acct=\(account.id) home=\(binding.homeUserID) — instant paint")
                    } else {
                        PlozzLog.boot("ensure.unprotectedSwitch acct=\(account.id) home=\(binding.homeUserID) — cache miss, async")
                    }
                    // Refresh in the background to keep the cached token fresh.
                    // `performPlexSwitch` only bumps the identity generation when the
                    // resolved token actually changed, so a warm-cache refresh that
                    // returns the same token triggers no reload. Capture the identity
                    // generation at spawn and pass it as `expectedGeneration` so a
                    // stale refresh — one whose profile was switched out from under it
                    // during the network window — drops its confirming write instead
                    // of re-installing the OLD Home-user's token under the NEW profile.
                    let refreshGeneration = plexIdentityGeneration
                    Task { await performPlexSwitch(accountID: account.id, homeUserID: binding.homeUserID, pin: nil, expectedGeneration: refreshGeneration) }
                }
            } else {
                if plexTokenOverrides[account.id] != nil {
                    setPlexTokenOverride(nil, for: account.id)
                    plexResolvedHomeUser[account.id] = nil
                    accountsProviders.registry.invalidate(accountID: account.id)
                    plexIdentityGeneration += 1
                    PlozzLog.boot("genBump=\(self.plexIdentityGeneration) site=ensure.dropOverride acct=\(account.id)")
                }
            }
        }

        if let pin = pinTarget {
            pendingPlexPINRequest = PlexPINRequest(
                id: "\(profile.id)#\(pin.accountID)",
                accountID: pin.accountID,
                homeUserID: pin.binding.homeUserID,
                homeUserName: pin.binding.name.isEmpty ? "Plex User" : pin.binding.name,
                homeUserAvatarURL: pin.binding.avatarURL
            )
            plexPINError = nil
        } else {
            pendingPlexPINRequest = nil
            plexPINError = nil
        }
    }

    /// Drops all Plex token overrides, falling back to stored (admin) tokens.
    private func clearPlexOverrides() {
        pendingPlexPINRequest = nil
        plexPINError = nil
        if !plexTokenOverrides.isEmpty {
            let accountIDs = Array(plexTokenOverrides.keys)
            plexTokenOverrides.removeAll()
            plexOverrideCredentialRevisions.removeAll()
            plexResolvedHomeUser.removeAll()
            for accountID in accountIDs {
                accountsProviders.registry.invalidate(accountID: accountID)
            }
            plexIdentityGeneration += 1
            PlozzLog.boot("genBump=\(self.plexIdentityGeneration) site=clearPlexOverrides")
        }
    }

    /// Performs the Plex Home-user switch and installs the resulting token as the
    /// account's override, bumping the identity generation only when the resolved
    /// token actually changed.
    private func performPlexSwitch(accountID: String, homeUserID: String, pin: String?, expectedGeneration: Int? = nil) async {
        PlozzLog.auth.debug("performPlexSwitch acct=\(accountID) home=\(homeUserID) pin?=\(pin != nil)")
        guard let adminToken = accountsProviders.accountStore.token(for: accountID) else {
            // Surface a user-visible error instead of silently returning; otherwise a
            // PIN submission with no cached admin token vanishes (no dismissal, no error)
            // and the user can't tell whether the PIN was accepted.
            PlozzLog.auth.error("no admin token cached for acct=\(accountID) — surfacing error")
            if pin != nil { plexPINError = "Couldn’t reach this Plex account. Try signing in again." }
            return
        }
        do {
            let token = try await plexHomeUserSwitch(homeUserID, pin, adminToken, accountsProviders.deviceID)
            PlozzLog.auth.debug("Plex Home-user switch OK — clearing pendingPlexPINRequest")
            // `token` is the Home user's account-level plex.tv token. Re-resolve
            // it to THIS server's access token (the kind PMS authorizes browsing
            // with), mirroring how the owner account was built at sign-in. Falls
            // back to the account token if the per-server lookup fails so the
            // switch never silently dead-ends. See `plexServerTokenResolve`.
            var resolvedToken = token
            var gotServerToken = false
            if let serverID = accountsProviders.accounts.first(where: { $0.id == accountID })?.server.id,
               let serverToken = await plexServerTokenResolve(serverID, token, accountsProviders.deviceID) {
                resolvedToken = serverToken
                gotServerToken = true
            }
            let previousToken = plexTokenOverrides[accountID]
            // Don't downgrade a good cached identity on a flaky refresh: if we
            // already have an override for this account and the per-server lookup
            // fell back to the account-level token, keep what we have instead of
            // replacing it (which would also force a needless reload).
            if previousToken != nil, !gotServerToken {
                PlozzLog.boot("refresh fell back to account token — keeping existing override acct=\(accountID)")
                pendingPlexPINRequest = nil
                plexPINError = nil
                if pin != nil { ensurePlexIdentityForActiveProfile() }
                return
            }
            // Staleness guard: a background refresh captured the identity generation
            // at spawn (`expectedGeneration`); if the active profile was switched /
            // its binding dropped during the network window the generation has moved,
            // so this write would re-install the OLD Home-user's token under the NEW
            // profile. Drop it. Harmless: the synchronously-cached token installed by
            // `ensurePlexIdentityForActiveProfile` before the spawn is already correct
            // for whichever profile is now active, and a fresh ensure runs on switch.
            // The user PIN path passes `nil` here and is never guarded (it's gated by
            // its own `pendingPlexPINRequest` lifecycle).
            if let expected = expectedGeneration, expected != plexIdentityGeneration {
                PlozzLog.boot("performPlexSwitch stale refresh dropped acct=\(accountID) gen=\(expected) live=\(self.plexIdentityGeneration)")
                return
            }
            setPlexTokenOverride(resolvedToken, for: accountID)
            plexResolvedHomeUser[accountID] = homeUserID
            // Cache unprotected (no-PIN) switches so future launches install this
            // identity synchronously. PIN-protected switches are never persisted.
            if pin == nil {
                plexHomeUserTokenCache.store(token: resolvedToken, account: accountID, homeUser: homeUserID)
            }
            pendingPlexPINRequest = nil
            plexPINError = nil
            // Only bump the identity generation — which tears down + rebuilds the
            // signed-in subtree — when the token actually changed. A background
            // refresh that returns the same token (the common case on a cache hit)
            // must NOT rebuild, or it reintroduces the startup double-load.
            if previousToken != resolvedToken {
                accountsProviders.registry.invalidate(accountID: accountID)
                plexIdentityGeneration += 1
                PlozzLog.boot("genBump=\(self.plexIdentityGeneration) site=performPlexSwitch acct=\(accountID) home=\(homeUserID)")
            } else {
                PlozzLog.boot("refresh unchanged — no genBump acct=\(accountID) home=\(homeUserID)")
            }
            // If another Plex account still needs a PIN, surface that next.
            if pin != nil { ensurePlexIdentityForActiveProfile() }
        } catch AppError.unauthorized {
            PlozzLog.auth.info("Plex Home-user switch unauthorized — wrong PIN")
            plexPINError = "Incorrect PIN. Please try again."
        } catch {
            PlozzLog.auth.error("Plex Home-user switch failed: \(error)")
            plexPINError = "Couldn’t switch Plex user. Please try again."
        }
    }

    // MARK: Account lifecycle hooks (called by AppState's Events domain)

    /// Forgets an account's Plex Home-user identity — drops any token override,
    /// the resolved-user marker, and every cached token for it. Called when an
    /// account is removed or signed out.
    public func forgetAccount(_ id: String) {
        setPlexTokenOverride(nil, for: id)
        plexResolvedHomeUser[id] = nil
        plexHomeUserTokenCache.removeAll(account: id)
    }

    /// Wipes ALL Plex Home-user state (overrides, revisions, resolved-user map,
    /// the whole token cache, and any pending PIN / user-selection). Used by the
    /// debug "reset to first run" path once every account is gone.
    public func resetAllForDebug() {
        plexTokenOverrides.removeAll()
        plexOverrideCredentialRevisions.removeAll()
        plexResolvedHomeUser.removeAll()
        plexHomeUserTokenCache.removeAll()
        pendingPlexUserSelection = nil
        pendingPlexPINRequest = nil
        plexPINError = nil
    }

    /// Presents (or clears) the "which Plex user are you?" onboarding selection.
    public func presentUserSelection(_ selection: PendingPlexUserSelection?) {
        pendingPlexUserSelection = selection
    }

    /// Clears the pending user selection once the onboarding step consumes it.
    public func clearUserSelection() {
        pendingPlexUserSelection = nil
    }
}
