import Foundation
import Observation
import CoreModels
import CoreUI
import CoreNetworking
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
    public struct PendingPlexUserSelection: Equatable, Identifiable, Sendable {
        public let accountID: String
        public let serverName: String
        public let users: [PlexHomeUser]
        /// Plex accounts from the same sign-in batch that should receive the
        /// selected Home-user binding.
        public let applyToAccountIDs: [String]
        /// Whether this selection is happening during a brand-new-install first
        /// run (drives whether we continue to profile-setup or the app).
        public let isFirstRun: Bool
        public var id: String { accountID }

        public init(
            accountID: String,
            serverName: String,
            users: [PlexHomeUser],
            isFirstRun: Bool,
            applyToAccountIDs: [String]? = nil
        ) {
            self.accountID = accountID
            self.serverName = serverName
            self.users = users
            self.isFirstRun = isFirstRun
            self.applyToAccountIDs = applyToAccountIDs ?? [accountID]
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
    public private(set) var plexPINError: LocalizedStringResource?
    /// Bumped whenever the active Plex identity (token override) changes so
    /// `RootView` rebuilds the signed-in subtree and content reloads as the new
    /// Plex Home user.
    public private(set) var plexIdentityGeneration = 0
    /// A pending "Which Plex user are you?" step, populated after a Plex account
    /// with 2+ Home users signs in (and this profile hasn't bound one yet).
    /// `RootView` presents the picker bound to this; `nil` when none is pending.
    public private(set) var pendingPlexUserSelection: PendingPlexUserSelection?

    /// A PIN entered to unlock a Plozz profile whose lock the user linked to
    /// their Plex PIN, waiting to be spent on that profile's next Plex
    /// Home-user switch so they're only asked once. Never persisted, never
    /// logged, and dropped after a single read — see
    /// `prefillPlexPIN(_:forProfile:)`.
    @ObservationIgnored
    private var prefilledPlexPIN: (profileID: String, pin: String)?

    /// In-memory Plex auth-token overrides keyed by `Account.id`. Set when the    /// active profile maps to a non-owner Plex Home user so providers resolve as
    /// that user. **PIN-protected** users are never persisted — their token must
    /// not survive relaunch, so Plozz re-prompts each launch. **Unprotected**
    /// users are seeded synchronously from `plexHomeUserTokenCache` (see below)
    /// so their identity paints instantly without the startup double-load.
    @ObservationIgnored
    private var plexTokenOverrides: [String: String] = [:]
    /// The Home user's ACCOUNT-level plex.tv token per account.
    ///
    /// Separate from `plexTokenOverrides`, which holds the per-SERVER access
    /// token that PMS authorizes browsing with: plex.tv Discover — the watchlist
    /// — needs the account-level one, and given a server token answers 401/403.
    ///
    /// Held in the box rather than a dictionary beside it so there is exactly ONE
    /// copy. A parallel dict was how the clearing paths came to update one and not
    /// the other, leaving a previous identity's token readable.
    @ObservationIgnored
    public let plexDiscoverTokens = PlexDiscoverTokenBox()

    /// Per-account identity generation, bumped whenever THIS account's resolved
    /// Plex identity changes.
    ///
    /// Beside the global `plexIdentityGeneration` (which the watchlist reconciler
    /// keys on, and which must move for any identity change) because supersession
    /// is an account-level question: two in-flight switches on DIFFERENT accounts
    /// are both current, and arbitrating them with one shared counter rejects
    /// whichever finishes second, stranding that account on the owner's token.
    @ObservationIgnored
    private var plexAccountIdentityGenerations: [String: Int] = [:]

    /// Records that `accountID`'s identity changed: bumps its own generation and
    /// the global one together, so neither can be updated without the other.
    private func bumpIdentityGeneration(for accountID: String, site: String) {
        plexAccountIdentityGenerations[accountID, default: 0] += 1
        plexIdentityGeneration += 1
        PlozzLog.boot("genBump=\(self.plexIdentityGeneration) site=\(site) acct=\(accountID)")
    }
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

    public init(
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

    /// Installs (or clears) the per-server token override for an account.
    ///
    /// Clearing also drops the account-level Discover token, because the two are
    /// one identity: leaving the Discover half behind let a profile that had
    /// switched to the owner — or to a different Home user — keep reading and
    /// writing the PREVIOUS user's watchlist, and made the fail-closed check
    /// pass on a token that no longer applied.
    private func setPlexTokenOverride(_ token: String?, for accountID: String) {
        if plexTokenOverrides[accountID] != token {
            plexOverrideCredentialRevisions[accountID] = token == nil
                ? nil
                : CredentialRevision()
        }
        plexTokenOverrides[accountID] = token
        if token == nil {
            plexDiscoverTokens.setToken(nil, for: accountID)
        }
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
                requiresPIN: $0.requiresPIN,
                isManaged: $0.isRestricted
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
    ///
    /// Drops the Plex overrides FIRST rather than relying on the fallback switch
    /// to fix the identity. The switch can now legitimately not happen — if the
    /// fallback profile carries its own `ProfileLock` the switch defers to that
    /// prompt, and the user can cancel that too — and without this we'd be left
    /// sitting inside the profile whose protected Plex user was just declined,
    /// resolved to the admin token.
    public func cancelPlexPIN() {
        clearPlexOverrides()
        if let fallback = profilesModel.profiles.first?.id,
           fallback != profilesModel.activeProfileID {
            switchProfile(fallback)
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

        // Take any stashed "same PIN as Plex" value for THIS profile up front, so
        // exactly one pass can ever see it. Reading it here rather than inside the
        // `pinTarget` branch matters: a profile with no protected binding would
        // otherwise leave the plaintext PIN sitting in memory for the rest of the
        // run, to be spent on some unrelated later pass (e.g. after the user links
        // a protected Home user in Settings).
        let prefilledPIN = consumePrefilledPIN(forProfile: profile.id)

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
                        bumpIdentityGeneration(for: account.id, site: "ensure.staleOverride")
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
                        let identityChanged = plexTokenOverrides[account.id] != cached
                            || plexResolvedHomeUser[account.id] != binding.homeUserID
                        setPlexTokenOverride(cached, for: account.id)
                        plexResolvedHomeUser[account.id] = binding.homeUserID
                        // Restore the Discover credential in the same breath, or
                        // the watchlist is left without one on every warm start.
                        //
                        // Cleared FIRST when the identity changed, unconditionally.
                        // A cache entry can hold the server token without the
                        // Discover half — it predates that half being cached, or
                        // the app died between the two writes — and simply not
                        // overwriting left the PREVIOUS user's Discover token
                        // live under the new user's server token. The watchlist
                        // then found a credential, passed the fail-closed check,
                        // and read the wrong person's list. No credential is the
                        // correct state here: that path refuses to act.
                        if identityChanged {
                            plexDiscoverTokens.setToken(nil, for: account.id)
                        }
                        if let cachedDiscover = plexHomeUserTokenCache.discoverToken(
                            account: account.id,
                            homeUser: binding.homeUserID
                        ) {
                            plexDiscoverTokens.setToken(cachedDiscover, for: account.id)
                        }
                        accountsProviders.registry.invalidate(accountID: account.id)
                        if identityChanged {
                            bumpIdentityGeneration(for: account.id, site: "ensure.cachedOverride")
                        }
                        PlozzLog.boot("ensure.cachedOverride acct=\(account.id) home=\(binding.homeUserID) — instant paint")
                    } else {
                        // Cache miss on a DIFFERENT user than the one currently
                        // installed. Drop the old credentials now rather than
                        // leaving them live for the length of the network switch:
                        // the profile already reads as bound to the new user, so
                        // a watchlist import in that window sees a binding, finds
                        // the PREVIOUS user's Discover token, passes the
                        // fail-closed check, and imports the wrong person's list.
                        // Better to hold no credential — that path correctly
                        // refuses to act — than to hold the wrong one.
                        if plexTokenOverrides[account.id] != nil,
                           plexResolvedHomeUser[account.id] != binding.homeUserID {
                            setPlexTokenOverride(nil, for: account.id)
                            plexResolvedHomeUser[account.id] = nil
                            accountsProviders.registry.invalidate(accountID: account.id)
                            bumpIdentityGeneration(for: account.id, site: "ensure.missStaleOverride")
                        }
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
                    // Per-ACCOUNT, not the global counter: two valid cache-miss
                    // switches on different accounts capture the same global
                    // generation, and whichever lands first bumps it — rejecting
                    // the other as "stale" though its own binding is still
                    // current, leaving that account stuck on the owner token.
                    // Supersession is an account-level question.
                    let refreshGeneration = plexAccountIdentityGenerations[account.id, default: 0]
                    Task { await performPlexSwitch(accountID: account.id, homeUserID: binding.homeUserID, pin: nil, expectedGeneration: refreshGeneration) }
                }
            } else {
                if plexTokenOverrides[account.id] != nil {
                    setPlexTokenOverride(nil, for: account.id)
                    plexResolvedHomeUser[account.id] = nil
                    accountsProviders.registry.invalidate(accountID: account.id)
                    bumpIdentityGeneration(for: account.id, site: "ensure.dropOverride")
                }
            }
        }

        if let pin = pinTarget {
            // If the user told us their profile PIN is also their Plex PIN, spend
            // it here instead of asking a second time for the same digits. On
            // failure we must RE-RAISE the prompt ourselves: nothing else does,
            // and leaving it unshown would silently drop the profile back to the
            // admin token — i.e. the restricted Home user's library limits would
            // quietly not apply. See `prefillPlexPIN(_:forProfile:)`.
            if let prefilledPIN {
                PlozzLog.auth.debug("using profile-lock PIN for Plex switch acct=\(pin.accountID)")
                pendingPlexPINRequest = nil
                plexPINError = nil
                let request = Self.pinRequest(profileID: profile.id, target: pin)
                Task { [weak self] in
                    await self?.performPlexSwitch(
                        accountID: pin.accountID,
                        homeUserID: pin.binding.homeUserID,
                        pin: prefilledPIN
                    )
                    // `performPlexSwitch` clears the request on success and only
                    // sets an error on failure, so an error still standing here
                    // means the switch didn't happen and the user needs the
                    // keypad after all.
                    guard let self, self.plexPINError != nil, self.pendingPlexPINRequest == nil else { return }
                    PlozzLog.auth.debug("profile-lock PIN rejected by Plex — raising the normal prompt")
                    self.pendingPlexPINRequest = request
                }
                return
            }
            pendingPlexPINRequest = Self.pinRequest(profileID: profile.id, target: pin)
            plexPINError = nil
        } else {
            pendingPlexPINRequest = nil
            plexPINError = nil
        }
    }

    /// Builds the PIN prompt for a protected Home-user binding.
    private static func pinRequest(
        profileID: String,
        target: (accountID: String, binding: PlexHomeUserBinding)
    ) -> PlexPINRequest {
        PlexPINRequest(
            id: "\(profileID)#\(target.accountID)",
            accountID: target.accountID,
            homeUserID: target.binding.homeUserID,
            homeUserName: target.binding.name.isEmpty ? "Plex User" : target.binding.name,
            homeUserAvatarURL: target.binding.avatarURL
        )
    }

    /// Hands this model the PIN the user just entered to unlock a Plozz profile,
    /// for the case where they set that profile's lock to "same PIN as Plex".
    ///
    /// Read and dropped by the very next `ensurePlexIdentityForActiveProfile()`
    /// pass — which consumes it up front whether or not it ends up being used —
    /// so the plaintext can't linger in memory or be replayed against a later
    /// binding. Purely an optimisation of the *prompt*: the profile is already
    /// unlocked by the time this is called, so if Plex rejects it the person
    /// simply gets the Plex PIN screen they'd have got anyway.
    public func prefillPlexPIN(_ pin: String, forProfile profileID: String) {
        prefilledPlexPIN = (profileID: profileID, pin: pin)
    }

    /// Verifies that `pin` opens every PIN-protected Plex Home user bound to the
    /// profile, without publishing any token or changing the active identity.
    ///
    /// Used while creating a Profile Lock so "same as Plex" is a verified fact,
    /// not an unchecked promise discovered to be wrong at the next login.
    public func validatePlexPIN(
        _ pin: String,
        forProfile profileID: String
    ) async -> PlexPINValidationResult {
        guard let profile = profilesModel.profiles.first(where: { $0.id == profileID })
        else { return .unavailable }

        let targets = accountsProviders.accounts.compactMap { account
            -> (accountID: String, homeUserID: String)? in
            guard account.server.provider == .plex,
                  let binding = profile.homeUserBinding(
                      forPlexAccount: account.id
                  ),
                  binding.requiresPIN == true
            else { return nil }
            return (account.id, binding.homeUserID)
        }
        guard !targets.isEmpty else { return .unavailable }

        for target in targets {
            guard let adminToken = accountsProviders.accountStore.token(
                for: target.accountID
            ) else { return .unavailable }
            do {
                _ = try await plexHomeUserSwitch(
                    target.homeUserID,
                    pin,
                    adminToken,
                    accountsProviders.deviceID
                )
            } catch AppError.unauthorized {
                return .invalid
            } catch {
                return .unavailable
            }
        }
        return .valid
    }

    /// Takes the stashed PIN if it belongs to `profileID`, clearing it either way
    /// — including when it belonged to a different profile, since a stash that
    /// didn't match is stale by definition.
    private func consumePrefilledPIN(forProfile profileID: String) -> String? {
        defer { prefilledPlexPIN = nil }
        guard let stash = prefilledPlexPIN, stash.profileID == profileID else { return nil }
        return stash.pin
    }

    /// The account-level plex.tv token to use for Discover (watchlist) calls on
    /// `accountID`, or `nil` to use the account's stored token.
    public func discoverToken(for accountID: String) -> String? {
        plexDiscoverTokens.token(for: accountID)
    }

    /// Drops all Plex token overrides, falling back to stored (admin) tokens.
    private func clearPlexOverrides() {
        pendingPlexPINRequest = nil
        plexPINError = nil
        if !plexTokenOverrides.isEmpty {
            let accountIDs = Array(plexTokenOverrides.keys)
            plexTokenOverrides.removeAll()
            plexDiscoverTokens.removeAll()
            plexOverrideCredentialRevisions.removeAll()
            plexResolvedHomeUser.removeAll()
            for accountID in accountIDs {
                accountsProviders.registry.invalidate(accountID: accountID)
                plexAccountIdentityGenerations[accountID, default: 0] += 1
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
            // Identity guard, checked FIRST because it's the one that always
            // holds: does the active profile still want to be this Home user on
            // this account? The generation counter can't answer that on its own —
            // two switches that both miss the cache change no synchronous token
            // state, so both capture the SAME generation. If the superseded one
            // lands first it installs its token and bumps the counter, and the
            // live request is then rejected as "stale", stranding the profile on
            // the previous user's credentials with nothing left to correct it.
            // Comparing against the binding can't alias like that.
            //
            // A MISSING binding is superseded too, not exempt: every caller
            // writes the binding before switching, so no binding means the active
            // profile now plays as the account owner — installing a Home user's
            // token over that is the same wrong answer in the other direction.
            let liveBinding = profilesModel.activeProfile.homeUserBinding(forPlexAccount: accountID)
            guard liveBinding?.homeUserID == homeUserID else {
                PlozzLog.boot("performPlexSwitch superseded acct=\(accountID) home=\(homeUserID) live=\(liveBinding?.homeUserID ?? "owner")")
                return
            }
            // Checked for EVERY switch, not just the guarded refresh: the PIN
            // path passes no `expectedGeneration`, so signing the account out
            // during the network window left the persisted binding still
            // matching and the task free to re-install — and re-cache — the
            // credentials the user had just removed.
            guard accountsProviders.accounts.contains(where: { $0.id == accountID }) else {
                PlozzLog.boot("performPlexSwitch dropped — account gone acct=\(accountID)")
                return
            }
            let liveAccountGeneration = plexAccountIdentityGenerations[accountID, default: 0]
            if let expected = expectedGeneration, expected != liveAccountGeneration {
                PlozzLog.boot("performPlexSwitch stale refresh dropped acct=\(accountID) gen=\(expected) live=\(liveAccountGeneration)")
                return
            }
            setPlexTokenOverride(resolvedToken, for: accountID)
            // `token` IS the Home user's account-level plex.tv token — the one
            // Discover (the watchlist) needs, as opposed to the per-server token
            // installed above. Published HERE, past the staleness guard and the
            // early return, so a superseded refresh can't leave the previous
            // profile's Discover identity installed.
            plexDiscoverTokens.setToken(token, for: accountID)
            plexResolvedHomeUser[accountID] = homeUserID
            // Cache unprotected (no-PIN) switches so future launches install this
            // identity synchronously. PIN-protected switches are never persisted.
            if pin == nil {
                plexHomeUserTokenCache.store(token: resolvedToken, account: accountID, homeUser: homeUserID)
                // The Discover half of the same identity, so a warm start — which
                // restores the server token synchronously and skips this switch
                // entirely — can restore both. Without it the watchlist has no
                // credential and correctly refuses to act, reading as permanently
                // empty. PIN-protected switches persist neither.
                plexHomeUserTokenCache.storeDiscoverToken(token, account: accountID, homeUser: homeUserID)
            }
            pendingPlexPINRequest = nil
            plexPINError = nil
            // Only bump the identity generation — which tears down + rebuilds the
            // signed-in subtree — when the token actually changed. A background
            // refresh that returns the same token (the common case on a cache hit)
            // must NOT rebuild, or it reintroduces the startup double-load.
            if previousToken != resolvedToken {
                accountsProviders.registry.invalidate(accountID: accountID)
                bumpIdentityGeneration(for: accountID, site: "performPlexSwitch")
            } else {
                PlozzLog.boot("refresh unchanged — no genBump acct=\(accountID) home=\(homeUserID)")
            }
            // If another Plex account still needs a PIN, surface that next.
            if pin != nil { ensurePlexIdentityForActiveProfile() }
        } catch AppError.unauthorized {
            PlozzLog.auth.info("Plex Home-user switch unauthorized — wrong PIN")
            plexPINError = ProfileLockCopy.incorrectPIN
        } catch {
            PlozzLog.auth.error("Plex Home-user switch failed: \(error)")
            plexPINError = ProfileLockCopy.plexSwitchFailed
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
        // Invalidates any refresh still awaiting the network for this account.
        // Removal changes neither the profile's binding nor — without this — the
        // generation, so a switch that was already in flight would pass both
        // guards and re-install (and re-cache) credentials for an account the
        // user has just signed out of.
        bumpIdentityGeneration(for: id, site: "forgetAccount")
    }

    /// Wipes ALL Plex Home-user state (overrides, revisions, resolved-user map,
    /// the whole token cache, and any pending PIN / user-selection). Used by the
    /// debug "reset to first run" path once every account is gone.
    public func resetAllForDebug() {
        plexTokenOverrides.removeAll()
        plexDiscoverTokens.removeAll()
        plexAccountIdentityGenerations.removeAll()
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
