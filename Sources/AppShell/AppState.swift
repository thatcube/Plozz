import Foundation
import Observation
import CoreModels
import FeatureAuth
import FeatureDiscovery
import FeatureProfiles
import ProviderJellyfin
import ProviderPlex
import RatingsService
import TraktService
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

    /// Provider-agnostic external-ratings enrichment (IMDb/RT/Metacritic via
    /// OMDb when a key is configured; otherwise a no-op). Injected into item
    /// detail so ratings are fetched async without blocking the screen.
    public let ratingsProvider: any ExternalRatingsProviding

    /// Trakt sync: owns the connection lifecycle for Settings and exposes the
    /// scrobbler the player uses to sync watches to the user's Trakt history.
    /// A no-op when no Trakt client credentials are configured.
    public let traktService: TraktService

    private var machine = SessionStateMachine()
    private let accountStore: AccountPersisting
    private let registry: ProviderRegistry
    /// Optional tvOS system-user seam (default app-owned no-op). See
    /// `SystemProfileBridging`.
    private let systemBridge: SystemProfileBridging
    /// True when settings models were injected by the caller (tests) and so must
    /// not be rebuilt on profile switch.
    private let usesInjectedModels: Bool

    public init(
        accountStore: AccountPersisting? = nil,
        registry: ProviderRegistry? = nil,
        profilesModel: ProfilesModel? = nil,
        systemBridge: SystemProfileBridging = AppOwnedProfileBridge(),
        captionModel: CaptionSettingsModel? = nil,
        spoilerModel: SpoilerSettingsModel? = nil,
        themeModel: ThemeSettingsModel? = nil,
        diagnosticsModel: DiagnosticsSettingsModel? = nil,
        homeLibraryVisibilityModel: HomeLibraryVisibilityModel? = nil,
        ratingsProvider: (any ExternalRatingsProviding)? = nil,
        traktService: TraktService? = nil
    ) {
        self.accountStore = accountStore ?? Self.makeDefaultAccountStore()
        self.registry = registry ?? Self.makeDefaultRegistry()
        self.profilesModel = profilesModel ?? ProfilesModel()
        self.systemBridge = systemBridge
        self.ratingsProvider = ratingsProvider ?? RatingsServiceFactory.make()
        self.traktService = traktService ?? TraktServiceFactory.make()

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
        return AccountStore()
        #else
        return AccountStore(secureStore: InMemorySecureStore())
        #endif
    }

    /// Registers the providers this build links. Each backend is a single
    /// `register(kind, …)` line; nothing else in core changes.
    private static func makeDefaultRegistry() -> ProviderRegistry {
        let registry = ProviderRegistry()
        registry.register(.jellyfin) { session in
            JellyfinProvider(session: session)
        }
        registry.register(.plex) { session in
            PlexProvider(session: session)
        }
        return registry
    }

    /// Restores stored accounts on launch (relaunch without re-login), migrating
    /// any legacy single session first. With more than one profile, opens the
    /// profile picker before the signed-in UI.
    public func bootstrap() {
        accountStore.migrateLegacySessionIfNeeded()
        reloadAccounts()
        // Prompt for a profile at launch only when the household has more than
        // one; a single (default) profile goes straight in.
        isChoosingProfile = profilesModel.profiles.count > 1
        apply(.restored(accounts))
    }

    /// Stable per-install device id used for Quick Connect + auth.
    public var deviceID: String { accountStore.deviceID() }

    /// Whether the environment permits remembering the selected profile for the
    /// current Apple TV system user (see `SystemProfileBridging`). v1 shows the
    /// launch picker for >1 profile regardless; this surfaces the one surviving,
    /// non-deprecated tvOS system signal for future tuning.
    public var mayRememberProfileSelection: Bool { systemBridge.mayRememberProfileSelection }

    public var lastServerStore: LastServerStoring { UserDefaultsLastServerStore() }

    // MARK: Providers

    /// The provider for the primary active account — the single-provider Home in
    /// this branch. `nil` when not signed in.
    public var primaryProvider: (any MediaProvider)? {
        guard let account = primaryActiveAccount,
              let token = accountStore.token(for: account.id) else { return nil }
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
                  let token = accountStore.token(for: account.id),
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
              let token = accountStore.token(for: account.id),
              let provider = try? registry.provider(for: account.session(token: token))
        else { return [] }
        return [ResolvedAccount(account: account, provider: provider)]
    }

    /// Resolves the provider for a specific account id — used to route a tapped
    /// library/item from the merged Home back to its owning provider. Tokens are
    /// resolved on demand and never stored on the value.
    public func provider(forAccountID id: String) -> (any MediaProvider)? {
        guard let account = accounts.first(where: { $0.id == id }),
              let token = accountStore.token(for: account.id)
        else { return nil }
        return try? registry.provider(for: account.session(token: token))
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
                profilesModel.update(profile)
            }
            profilesModel.setActiveAccountIDs(draft.activeAccountIDs, for: id)
            if id == profilesModel.activeProfileID {
                rebuildSettingsModels()
                reloadAccounts()
            }
        } else {
            profilesModel.add(
                name: draft.name,
                avatarSymbol: draft.avatarSymbol,
                colorIndex: draft.colorIndex,
                linkedAccountID: draft.linkedAccountID,
                activeAccountIDs: draft.activeAccountIDs
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
