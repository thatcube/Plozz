import Foundation
import Observation
import CoreModels
import FeatureAuth
import FeatureDiscovery
import FeatureProfiles
import ProviderJellyfin
import ProviderPlex
import RatingsService
import TopShelfKit

/// The app's composition root and single source of truth for session state.
///
/// Owns the **multi-account** model: it persists a list of `Account`s through
/// `AccountStore` (token per account in the Keychain), drives the
/// `SessionStateMachine`, and resolves the right `MediaProvider` per account via
/// a `ProviderRegistry`. `RootView` observes `state` and renders exactly one
/// screen per case.
@MainActor
@Observable
public final class AppState {
    public private(set) var state: SessionState = .launching

    /// All signed-in accounts, in stable order.
    public private(set) var accounts: [Account] = []
    /// The subset of `accounts` currently included in the active set. Sourced
    /// from the **active profile** (falling back to the household-global active
    /// set for the default profile). Branch H (aggregated Home) fans out over
    /// this; this branch uses the primary one.
    public private(set) var activeAccountIDs: Set<String> = []

    /// A Jellyfin item id requested via a Top Shelf deep link
    /// (`plozz://item/<id>`) that the signed-in UI should open for playback.
    /// Set when the app is launched/foregrounded from a Top Shelf card and
    /// cleared once the Home tab has routed to it.
    public var pendingPlayItemID: String?

    /// Per-profile settings models. Rebuilt when the active profile changes so
    /// switching profiles swaps the active theme/spoiler/caption/diagnostics
    /// state cleanly. When the caller injects models (tests), they're used
    /// as-is and not rebuilt.
    public private(set) var captionModel: CaptionSettingsModel
    public private(set) var spoilerModel: SpoilerSettingsModel
    public private(set) var themeModel: ThemeSettingsModel
    public private(set) var diagnosticsModel: DiagnosticsSettingsModel
    /// Which discovered libraries appear on the unified Home (opt-out). Shared
    /// live between the Settings checklist and Home so toggles take effect
    /// without a reload, and scoped per profile (rebuilt on profile switch) so
    /// each profile keeps its own Home customization.
    public private(set) var homeLibraryVisibilityModel: HomeLibraryVisibilityModel

    /// The household's profiles + active selection. Owned at the app level and
    /// layered on top of the multi-account core.
    public let profilesModel: ProfilesModel
    /// When `true`, `RootView` shows the profile picker instead of the signed-in
    /// UI (shown at launch with >1 profile, and from "Switch Profile").
    public private(set) var isChoosingProfile = false

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

    /// A profile activation waiting on a Plex Home user's PIN.
    public struct PlexPINRequest: Identifiable, Equatable, Sendable {
        /// The id of the profile being activated.
        public let id: String
        public let accountID: String
        public let homeUserID: String
        public let homeUserName: String
    }

    /// Provider-agnostic external-ratings enrichment (IMDb/RT/Metacritic via
    /// OMDb when a key is configured; otherwise a no-op). Injected into item
    /// detail so ratings are fetched async without blocking the screen.
    public let ratingsProvider: any ExternalRatingsProviding

    /// The handler behind every card's press-and-hold context menu. Lazily
    /// created so it can capture `self`; resolves the owning provider per item
    /// and performs watched-state (and future) actions against the server.
    @ObservationIgnored
    public private(set) lazy var mediaItemActionHandler: any MediaItemActionHandling =
        MediaItemActionCoordinator(appState: self)

    private var machine = SessionStateMachine()
    private let accountStore: AccountPersisting
    private let registry: ProviderRegistry
    /// Optional tvOS system-user seam (default app-owned no-op). See
    /// `SystemProfileBridging`.
    private let systemBridge: SystemProfileBridging
    /// True when settings models were injected by the caller (tests) and so must
    /// not be rebuilt on profile switch.
    private let usesInjectedModels: Bool

    /// In-memory Plex auth-token overrides keyed by `Account.id`. Set when the
    /// active profile maps to a non-owner Plex Home user so providers resolve as
    /// that user. **Never persisted** — protected-user tokens/PINs must not
    /// survive relaunch; Plozz re-prompts (or re-switches) each launch.
    private var plexTokenOverrides: [String: String] = [:]

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

    public init(
        accountStore: AccountPersisting? = nil,
        registry: ProviderRegistry? = nil,
        profilesModel: ProfilesModel? = nil,
        systemBridge: SystemProfileBridging? = nil,
        captionModel: CaptionSettingsModel? = nil,
        spoilerModel: SpoilerSettingsModel? = nil,
        themeModel: ThemeSettingsModel? = nil,
        diagnosticsModel: DiagnosticsSettingsModel? = nil,
        homeLibraryVisibilityModel: HomeLibraryVisibilityModel? = nil,
        ratingsProvider: (any ExternalRatingsProviding)? = nil
    ) {
        self.accountStore = accountStore ?? Self.makeDefaultAccountStore()
        self.registry = registry ?? Self.makeDefaultRegistry()
        self.profilesModel = profilesModel ?? Self.makeDefaultProfilesModel()
        self.systemBridge = systemBridge ?? Self.makeDefaultSystemBridge()
        self.ratingsProvider = ratingsProvider ?? RatingsServiceFactory.make()

        // If the caller supplied any settings model, treat them all as injected
        // (test path) and don't rebuild them on profile switch. Otherwise build
        // them scoped to the active profile's namespace.
        let injected = captionModel != nil || spoilerModel != nil
            || themeModel != nil || diagnosticsModel != nil
            || homeLibraryVisibilityModel != nil
        self.usesInjectedModels = injected
        let ns = (profilesModel ?? self.profilesModel).activeNamespace
        self.captionModel = captionModel ?? CaptionSettingsModel(store: CaptionSettingsStore(namespace: ns))
        self.spoilerModel = spoilerModel ?? SpoilerSettingsModel(store: SpoilerSettingsStore(namespace: ns))
        self.themeModel = themeModel ?? ThemeSettingsModel(store: ThemeSettingsStore(namespace: ns))
        self.diagnosticsModel = diagnosticsModel ?? DiagnosticsSettingsModel(store: DiagnosticsSettingsStore(namespace: ns))
        self.homeLibraryVisibilityModel = homeLibraryVisibilityModel
            ?? HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(namespace: ns))
    }

    private static func makeDefaultAccountStore() -> AccountPersisting {
        #if canImport(Security)
        return AccountStore(secureStore: KeychainStore())
        #else
        return AccountStore(secureStore: InMemorySecureStore())
        #endif
    }

    /// Builds the household profiles model, backing the shared profile set with
    /// the user-independent Keychain on Apple platforms so every Apple TV system
    /// user sees the same profiles (the active selection stays per-user).
    private static func makeDefaultProfilesModel() -> ProfilesModel {
        #if canImport(Security)
        return ProfilesModel(store: ProfileStore(secureStore: KeychainStore(service: "com.plozz.app.household")))
        #else
        return ProfilesModel()
        #endif
    }

    /// Selects the tvOS system-user bridge when TVServices is available, so the
    /// launch picker can honor each Apple TV user's remembered profile; falls
    /// back to the app-owned no-op elsewhere (tests/previews/non-tvOS).
    private static func makeDefaultSystemBridge() -> SystemProfileBridging {
        #if canImport(TVServices)
        return TVSystemProfileBridge()
        #else
        return AppOwnedProfileBridge()
        #endif
    }

    /// Registers the providers this build links. Each backend is a single
    /// `register(kind, …)` line; nothing else in core changes.
    private static func makeDefaultRegistry() -> ProviderRegistry {
        let registry = ProviderRegistry()
        registry.register(.jellyfin) { session in
            JellyfinProvider(session: session, hybridEngineEnabled: HybridPlayback.enabled)
        }
        registry.register(.plex) { session in
            PlexProvider(session: session, hybridEngineEnabled: HybridPlayback.enabled)
        }
        return registry
    }

    /// Restores stored accounts on launch (relaunch without re-login), migrating
    /// any legacy single session first. With more than one profile, opens the
    /// profile picker before the signed-in UI.
    public func bootstrap() {
        accountStore.migrateLegacySessionIfNeeded()
        reloadAccounts()
        // Show the launch picker when the household has more than one profile,
        // unless the current Apple TV system user already has a remembered pick
        // that the system says we may honor (per `shouldStorePreferencesForCurrentUser`).
        // On single-Apple-TV-user devices the system signal is false, preserving
        // the original "always show the picker for >1 profile" behavior.
        let systemRemembers = mayRememberProfileSelection && profilesModel.hasRememberedSelection
        isChoosingProfile = profilesModel.profiles.count > 1 && !systemRemembers
        apply(.restored(accounts))
        // Honor a remembered/auto-landed profile's Plex Home-user mapping at
        // launch. When the picker is shown, the switch happens once the user
        // picks instead.
        if !isChoosingProfile {
            ensurePlexIdentityForActiveProfile()
        }
    }

    /// Stable per-install device id used for Quick Connect + auth.
    public var deviceID: String { accountStore.deviceID() }

    /// Whether the environment permits remembering the selected profile for the
    /// current Apple TV system user (see `SystemProfileBridging`). Wired in
    /// Phase 1: combined with `ProfilesModel.hasRememberedSelection`, it lets the
    /// launch picker auto-skip for a system user who already chose a profile.
    public var mayRememberProfileSelection: Bool { systemBridge.mayRememberProfileSelection }

    public var lastServerStore: LastServerStoring { UserDefaultsLastServerStore() }

    // MARK: Providers

    /// The provider for the primary active account — the single-provider Home in
    /// this branch. `nil` when not signed in.
    public var primaryProvider: (any MediaProvider)? {
        guard let account = primaryActiveAccount,
              let token = resolvedToken(for: account.id) else { return nil }
        return try? registry.provider(for: account.session(token: token))
    }

    /// The active account that drives the current single-provider UI.
    public var primaryActiveAccount: Account? {
        accounts.first { activeAccountIDs.contains($0.id) } ?? accounts.first
    }

    /// ## Aggregation seam (branch H)
    /// The active accounts paired with their resolved providers. Branch H's Home
    /// view model fans out over this list; this branch does not consume it yet
    /// beyond `primaryProvider`. Tokens are resolved on demand and never stored
    /// on the value.
    public var resolvedActiveAccounts: [ResolvedAccount] {
        accounts.compactMap { account in
            guard activeAccountIDs.contains(account.id),
                  let token = resolvedToken(for: account.id),
                  let provider = try? registry.provider(for: account.session(token: token))
            else { return nil }
            return ResolvedAccount(account: account, provider: provider)
        }
    }

    /// The accounts the unified Home/Search fan out over. Normally the active
    /// set; falls back to the primary account so the signed-in UI is never empty
    /// even if the active-id set is somehow empty.
    public var homeAccounts: [ResolvedAccount] {
        let active = resolvedActiveAccounts
        if !active.isEmpty { return active }
        guard let account = primaryActiveAccount,
              let token = resolvedToken(for: account.id),
              let provider = try? registry.provider(for: account.session(token: token))
        else { return [] }
        return [ResolvedAccount(account: account, provider: provider)]
    }

    /// Resolves the provider for a specific account id — used to route a tapped
    /// library/item from the merged Home back to its owning provider. Tokens are
    /// resolved on demand and never stored on the value.
    public func provider(forAccountID id: String) -> (any MediaProvider)? {
        guard let account = accounts.first(where: { $0.id == id }),
              let token = resolvedToken(for: account.id)
        else { return nil }
        return try? registry.provider(for: account.session(token: token))
    }

    // MARK: Plex Home users ("Who's watching?")

    /// The auth token to use for `accountID`, preferring an in-memory Plex
    /// Home-user override over the account's stored (admin) token.
    private func resolvedToken(for accountID: String) -> String? {
        plexTokenOverrides[accountID] ?? accountStore.token(for: accountID)
    }

    /// Lists the Plex Home users for a signed-in Plex account (for the profile
    /// editor's "Plex User" picker). Returns `[]` for non-Plex/unknown accounts
    /// or on failure. Always uses the account's stored (admin) token.
    public func plexHomeUsers(forAccountID accountID: String) async -> [PlexHomeUser] {
        guard let account = accounts.first(where: { $0.id == accountID }),
              account.server.provider == .plex,
              let adminToken = accountStore.token(for: accountID) else { return [] }
        return (try? await plexHomeUsersFetch(adminToken, deviceID)) ?? []
    }

    /// Submits a PIN for the outstanding Plex Home-user switch.
    public func submitPlexPIN(_ pin: String) {
        guard let request = pendingPlexPINRequest else { return }
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
            switchProfile(to: fallback)
        } else {
            clearPlexOverrides()
        }
    }

    /// Treats a programmatic sheet dismissal as a cancel **only** when a prompt
    /// is still outstanding (a successful switch already cleared it).
    public func dismissPlexPINIfPresented() {
        if pendingPlexPINRequest != nil { cancelPlexPIN() }
    }

    /// Aligns the in-memory Plex identity with the active profile's linked Home
    /// user: unprotected users switch silently; protected users raise a PIN
    /// prompt; an unmapped profile drops any override (back to the admin user).
    private func ensurePlexIdentityForActiveProfile() {
        let profile = profilesModel.activeProfile
        guard let homeUserID = profile.plexHomeUserID,
              let accountID = profile.plexHomeUserAccountID,
              accounts.contains(where: { $0.id == accountID }) else {
            clearPlexOverrides()
            return
        }
        pendingPlexPINRequest = nil
        plexPINError = nil
        if profile.plexHomeUserRequiresPIN == true {
            // PIN is never cached — drop any stale override and re-prompt.
            if plexTokenOverrides[accountID] != nil {
                plexTokenOverrides[accountID] = nil
                plexIdentityGeneration += 1
            }
            pendingPlexPINRequest = PlexPINRequest(
                id: profile.id,
                accountID: accountID,
                homeUserID: homeUserID,
                homeUserName: profile.plexHomeUserName ?? "Plex User"
            )
        } else {
            Task { await performPlexSwitch(accountID: accountID, homeUserID: homeUserID, pin: nil) }
        }
    }

    /// Drops all Plex token overrides, falling back to stored (admin) tokens.
    private func clearPlexOverrides() {
        pendingPlexPINRequest = nil
        plexPINError = nil
        if !plexTokenOverrides.isEmpty {
            plexTokenOverrides.removeAll()
            plexIdentityGeneration += 1
        }
    }

    /// Performs the Plex Home-user switch and installs the resulting token as the
    /// account's override, bumping the identity generation so content reloads.
    private func performPlexSwitch(accountID: String, homeUserID: String, pin: String?) async {
        guard let adminToken = accountStore.token(for: accountID) else { return }
        do {
            let token = try await plexHomeUserSwitch(homeUserID, pin, adminToken, deviceID)
            plexTokenOverrides[accountID] = token
            pendingPlexPINRequest = nil
            plexPINError = nil
            plexIdentityGeneration += 1
        } catch AppError.unauthorized {
            plexPINError = "Incorrect PIN. Please try again."
        } catch {
            plexPINError = "Couldn’t switch Plex user. Please try again."
        }
    }

    // MARK: Events

    /// Handles an incoming deep link. Recognised `plozz://item/<id>` links queue
    /// the item for playback once the user is signed in.
    public func handle(url: URL) {
        if let id = TopShelf.itemID(from: url) {
            pendingPlayItemID = id
        }
    }

    public func selectServer(_ server: MediaServer) {
        apply(.serverSelected(server))
    }

    /// Persists a freshly-authenticated account and advances the machine.
    public func didAuthenticate(_ session: UserSession) {
        let account = Account(from: session)
        do {
            try accountStore.add(account, token: session.accessToken)
        } catch {
            apply(.authenticationFailed(.unknown("")))
            return
        }
        reloadAccounts()
        apply(.accountAuthenticated)
    }

    /// Completes a Plex sign-in started from the provider chooser.
    ///
    /// The Plex PIN-link flow resolves the chosen server only *after* the user
    /// links the code, so — unlike the Jellyfin path — no server was selected up
    /// front. Drive the state machine through `.serverSelected` first so the
    /// subsequent `.accountAuthenticated` transition is legal, then persist the
    /// account exactly like any other provider.
    public func didAuthenticatePlex(_ session: UserSession) {
        apply(.serverSelected(session.server))
        didAuthenticate(session)
    }

    /// Begins adding another account from inside the signed-in app.
    public func addAccount() {
        apply(.addAccountRequested)
    }

    public func cancelAuthentication() {
        apply(.cancelOnboarding)
    }

    /// Removes one account; drops to onboarding if it was the last.
    public func removeAccount(id: String) {
        try? accountStore.remove(id: id)
        reloadAccounts()
        apply(.accountsChanged(accounts))
    }

    /// Signs out of the primary active account (the one Settings currently shows).
    public func signOut() {
        if let account = primaryActiveAccount {
            removeAccount(id: account.id)
        }
    }

    /// Removes every account (full reset).
    public func signOutAll() {
        try? accountStore.clearAll()
        reloadAccounts()
        apply(.accountsChanged(accounts))
    }

    public func retry() {
        apply(.retry)
    }

    // MARK: Profiles

    /// Opens the profile picker (from Settings → "Switch Profile").
    public func requestProfileSelection() {
        isChoosingProfile = true
    }

    /// Dismisses the profile picker without changing the active profile (only
    /// allowed when a profile is already active behind it).
    public func cancelProfileSelection() {
        isChoosingProfile = false
    }

    /// Switches to `id`, re-scoping settings + the active account set, then
    /// dismisses the picker. Fast: a few `UserDefaults` reads plus an in-memory
    /// account recompute; content reloads async via the rebuilt view subtree.
    public func switchProfile(to id: String) {
        profilesModel.select(id)
        rebuildSettingsModels()
        reloadAccounts()
        isChoosingProfile = false
        ensurePlexIdentityForActiveProfile()
    }

    /// Creates or updates a profile from an editor draft. Updating the active
    /// profile re-applies its settings + account scope immediately.
    public func saveProfile(_ draft: ProfileDraft) {
        if let id = draft.id {
            if var profile = profilesModel.profiles.first(where: { $0.id == id }) {
                profile.name = draft.name
                profile.avatarSymbol = draft.avatarSymbol
                profile.colorIndex = draft.colorIndex
                profile.linkedAccountID = draft.linkedAccountID
                profile.plexHomeUserID = draft.plexHomeUserID
                profile.plexHomeUserName = draft.plexHomeUserName
                profile.plexHomeUserAccountID = draft.plexHomeUserAccountID
                profile.plexHomeUserRequiresPIN = draft.plexHomeUserRequiresPIN
                profilesModel.update(profile)
            }
            profilesModel.setActiveAccountIDs(draft.activeAccountIDs, for: id)
            if id == profilesModel.activeProfileID {
                rebuildSettingsModels()
                reloadAccounts()
                ensurePlexIdentityForActiveProfile()
            }
        } else {
            profilesModel.add(
                name: draft.name,
                avatarSymbol: draft.avatarSymbol,
                colorIndex: draft.colorIndex,
                linkedAccountID: draft.linkedAccountID,
                activeAccountIDs: draft.activeAccountIDs,
                plexHomeUserID: draft.plexHomeUserID,
                plexHomeUserName: draft.plexHomeUserName,
                plexHomeUserAccountID: draft.plexHomeUserAccountID,
                plexHomeUserRequiresPIN: draft.plexHomeUserRequiresPIN
            )
        }
    }

    /// Removes a profile (the default profile can't be removed). If it was
    /// active, selection falls back to the first profile and re-scopes.
    public func removeProfile(id: String) {
        let wasActive = id == profilesModel.activeProfileID
        profilesModel.remove(id)
        if wasActive {
            rebuildSettingsModels()
            reloadAccounts()
        }
    }

    /// The account subset currently stored for a profile (for the editor), or
    /// the resolved fallback when it never chose one.
    public func activeAccountIDs(forProfile id: String) -> [String] {
        Array(profilesModel.activeAccountIDs(for: id, fallback: accountStore.activeAccountIDs()))
    }

    // MARK: Internals

    private func reloadAccounts() {
        accounts = accountStore.loadAccounts()
        let known = Set(accounts.map(\.id))
        // The active set is the active profile's chosen subset, falling back to
        // the household-global active set (default profile / upgrade path).
        let globalActive = accountStore.activeAccountIDs()
        let profileIDs = profilesModel.activeAccountIDs(
            for: profilesModel.activeProfileID,
            fallback: globalActive
        )
        var resolved = Set(profileIDs.filter { known.contains($0) })
        // A profile that selected nothing valid uses every account.
        if resolved.isEmpty { resolved = known }
        activeAccountIDs = resolved
    }

    /// Rebuilds the four settings models scoped to the active profile's
    /// namespace. No-op when settings models were injected (tests).
    private func rebuildSettingsModels() {
        guard !usesInjectedModels else { return }
        let ns = profilesModel.activeNamespace
        captionModel = CaptionSettingsModel(store: CaptionSettingsStore(namespace: ns))
        spoilerModel = SpoilerSettingsModel(store: SpoilerSettingsStore(namespace: ns))
        themeModel = ThemeSettingsModel(store: ThemeSettingsStore(namespace: ns))
        diagnosticsModel = DiagnosticsSettingsModel(store: DiagnosticsSettingsStore(namespace: ns))
        homeLibraryVisibilityModel = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(namespace: ns))
    }

    private func apply(_ event: SessionEvent) {
        machine.apply(event)
        state = machine.state
    }
}
