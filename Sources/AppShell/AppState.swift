import Foundation
import Observation
import CoreModels
import CoreNetworking
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

    /// Provider-agnostic external-ratings enrichment (IMDb/RT/Metacritic via
    /// OMDb when a key is configured; otherwise a no-op). Injected into item
    /// detail so ratings are fetched async without blocking the screen.
    public let ratingsProvider: any ExternalRatingsProviding

    /// Trakt sync: owns the connection lifecycle for Settings and exposes the
    /// scrobbler the player uses to sync watches to the user's Trakt history.
    /// A no-op when no Trakt client credentials are configured.
    public let traktService: TraktService

    /// The handler behind every card's press-and-hold context menu. Lazily
    /// created so it can capture `self`; resolves the owning provider per item
    /// and performs watched-state (and future) actions against the server.
    @ObservationIgnored
    public private(set) lazy var mediaItemActionHandler: any MediaItemActionHandling =
        MediaItemActionCoordinator(appState: self)

    /// Durable cross-server watch-state outbox + reconciler. Persists each watch
    /// mutation's intent to disk before the network call and drains it on launch /
    /// foreground / reachability so a watch made while a server was asleep (or the
    /// app offline) still converges every server + Trakt. Profile-scoped store, so
    /// it is rebuilt (and the old one flushed) when the active profile changes.
    @ObservationIgnored
    private var _watchReconciler: WatchStateReconciler?
    public var watchReconciler: WatchStateReconciler {
        if let existing = _watchReconciler { return existing }
        let created = makeWatchReconciler()
        _watchReconciler = created
        return created
    }

    /// Builds the reconciler with a profile-scoped file store and an applier that
    /// resolves providers / the Trakt scrobbler live on the main actor.
    private func makeWatchReconciler() -> WatchStateReconciler {
        let store = FileWatchMutationStore(namespace: profilesModel.activeNamespace)
        let applier = AppShellWatchMutationApplier(
            resolveProvider: { [weak self] accountID in
                await MainActor.run { self?.provider(forAccountID: accountID) }
            },
            traktScrobbler: { [weak self] in
                await MainActor.run { self?.traktService.scrobbler ?? DisabledTraktScrobbler() }
            },
            allAccountIDs: { [weak self] in
                await MainActor.run { self?.accounts.map(\.id) ?? [] }
            },
            indexedSeriesSources: { [identitySnapshotStore] originSeries in
                identitySnapshotStore.current.sources(for: originSeries).filter { $0.kind == .series }
            }
        )
        return WatchStateReconciler(store: store, applier: applier)
    }

    /// Flushes and drops the current reconciler so the next access rebuilds it for
    /// the now-active profile's namespace.
    private func resetWatchReconciler() {
        guard let old = _watchReconciler else { return }
        _watchReconciler = nil
        Task { await old.drain() }
    }

    /// Drains the watch-state outbox. Safe to call repeatedly (no-op when empty);
    /// invoked on launch, on foreground, and after a watch mutation is enqueued.
    public func drainWatchOutbox() {
        let reconciler = watchReconciler
        Task { await reconciler.drain() }
    }

    /// Records a watch mutation's intent durably (stale-suppressed + coalesced) and
    /// immediately attempts to drain it. The single entry point the action
    /// coordinator and player use so every watch fans out to all servers + Trakt and
    /// survives relaunch.
    public func enqueueWatchMutation(_ mutation: WatchMutation) {
        let reconciler = watchReconciler
        Task {
            await reconciler.enqueue(mutation)
            await reconciler.drain()
        }
    }

    /// Registers `(accountID, itemID)` as the live in-app playback session so the
    /// reconciler defers convergence writes against that exact server while it is
    /// playing — a mid-play drain can never disturb/zero the now-playing session.
    public func beginLiveWatchSession(accountID: String, itemID: String) {
        let reconciler = watchReconciler
        Task { await reconciler.beginLiveSession(accountID: accountID, itemID: itemID) }
    }

    /// Ends the live session for `(accountID, itemID)` and enqueues the optional
    /// final convergence `mutation`, **in that order**, so the just-played server
    /// is no longer deferred and its final resume/played write goes out. Sequenced
    /// in a single task so the end always precedes the enqueue's drain. `accountID`
    /// is optional so a barely-started/untargeted stop still flushes deferred work.
    public func finishLiveWatchSession(accountID: String?, itemID: String, mutation: WatchMutation?) {
        let reconciler = watchReconciler
        publishOptimisticWatchedFlip(itemID: itemID, mutation: mutation)
        Task {
            if let accountID {
                await reconciler.endLiveSession(accountID: accountID, itemID: itemID)
            }
            if let mutation {
                await reconciler.enqueue(mutation)
                await reconciler.drain()
            }
        }
    }

    /// On a real *finish* — the convergence `mutation` marks the title played —
    /// optimistically flip its watched badge across every visible surface the
    /// instant the player dismisses, fixing the "tile still reads unwatched after
    /// Back" bug that previously required a full reload. The id set is every
    /// server's own item id in the shared source of truth (the mutation's
    /// `targets`, already unioned from the eager identity index when the stop
    /// mutation was built) plus the played item id itself. Routed through the same
    /// optimistic ``MediaItemMutation`` path press-and-hold "Mark watched" uses, so
    /// Home/Detail/Search all flip immediately. Purely additive: it never blocks or
    /// replaces the durable fan-out enqueued above. A mid-watch resume (no `played`)
    /// leaves the badge alone — resume tiles refresh on the next Home load.
    private func publishOptimisticWatchedFlip(itemID: String, mutation: WatchMutation?) {
        guard let mutation, mutation.played == true else { return }
        var ids = Set(mutation.targets.map(\.itemID))
        ids.insert(itemID)
        MediaItemMutation(itemIDs: ids, played: true).post()
    }

    // MARK: - Eager identity index (single source of truth for cross-server sources)

    /// The eager `identity → sources` index built at sign-in / sync. The single
    /// shared store every surface reads (Home/Browse/Search merge, the detail
    /// server-picker, and the watch fan-out) so a title's cross-server/cross-account
    /// set is identical regardless of entry path. Profile-scoped: rebuilt when the
    /// active profile changes so one profile's catalogue never leaks into another.
    @ObservationIgnored
    private var _identityIndex = IdentityIndex()

    /// In-flight warming task, cancelled and replaced when the active accounts /
    /// profile change so a stale scan can't clobber a newer one.
    @ObservationIgnored
    private var identityWarmTask: Task<Void, Never>?

    /// An immutable snapshot of ``_identityIndex`` that synchronous callers read.
    /// `.empty` until the first account warms — every lookup then returns `[]`, so
    /// callers degrade to their existing on-demand discovery and never drop a write.
    public private(set) var identitySnapshot: IdentityIndexSnapshot = .empty

    /// Thread-safe mirror of ``identitySnapshot`` so the `@Sendable` lookup closure
    /// handed to Home/Browse/Search merging and the off-main player stop hook can
    /// read the live source-of-truth without hopping to the main actor.
    @ObservationIgnored
    private let identitySnapshotStore = IdentityIndexSnapshotStore()

    /// A `@Sendable` identity → cross-server sources lookup over the live index.
    /// The single accessor every surface (merge enrichment, detail picker, watch
    /// fan-out) uses to read the shared source of truth.
    public var identitySourcesProvider: @Sendable (MediaItem) -> [MediaSourceRef] {
        identitySnapshotStore.sourcesProvider()
    }

    /// How long an account's index stays fresh before an opportunistic re-warm.
    private let identityIndexTTL: TimeInterval = 600

    /// Per-library scan caps so building the index can never become an unbounded
    /// full-library walk that stalls launch on a huge catalogue.
    private let identityChunkSize = 200
    private let identityMaxItemsPerLibrary = 10_000

    /// Warms (or incrementally refreshes) the identity index for the currently
    /// active accounts. Cold and stale accounts are (re)scanned; removed accounts
    /// are pruned. Bounded and fully best-effort: a failing/asleep server simply
    /// contributes nothing and is retried on the next warm, so the index only ever
    /// grows toward completeness and never blocks playback or watch writes.
    public func warmIdentityIndex(force: Bool = false) {
        let resolved = homeAccounts
        guard !resolved.isEmpty else { return }
        let activeIDs = Set(resolved.map(\.account.id))
        let serverInfo = resolved.sourceServerInfo()
        let index = _identityIndex
        let ttl = identityIndexTTL
        let chunkSize = identityChunkSize
        let maxPerLibrary = identityMaxItemsPerLibrary

        identityWarmTask?.cancel()
        identityWarmTask = Task { [weak self] in
            await index.retainAccounts(activeIDs)
            let stale = await index.staleAccounts(olderThan: ttl)
            for resolvedAccount in resolved {
                if Task.isCancelled { break }
                let accountID = resolvedAccount.account.id
                let warm = await index.isWarm(accountID)
                if warm && !force && !stale.contains(accountID) { continue }
                await Self.indexAccount(
                    resolvedAccount,
                    into: index,
                    serverInfo: serverInfo[accountID],
                    chunkSize: chunkSize,
                    maxPerLibrary: maxPerLibrary
                )
                // Publish progressively so surfaces see each warmed account.
                let snapshot = await index.snapshot()
                await MainActor.run {
                    self?.identitySnapshot = snapshot
                    self?.identitySnapshotStore.update(snapshot)
                }
            }
        }
    }

    /// Scans one account's movie + series libraries in bounded pages and ingests
    /// every catalogue entry's identity → source into the index.
    private static func indexAccount(
        _ resolved: ResolvedAccount,
        into index: IdentityIndex,
        serverInfo: SourceServerInfo?,
        chunkSize: Int,
        maxPerLibrary: Int
    ) async {
        let provider = resolved.provider
        let accountID = resolved.account.id
        guard let libraries = try? await provider.libraries() else { return }

        await index.beginRebuild(for: accountID)
        // `true` if any page needed an enrichment fetch that failed, so we leave
        // the account un-finished (cold) and a later warm retries it — the index
        // grows toward completeness and never drops a server permanently.
        var inconclusive = false
        for library in libraries where library.kind == .movie || library.kind == .series {
            if Task.isCancelled { return }
            var offset = 0
            while offset < maxPerLibrary {
                if Task.isCancelled { return }
                guard let page = try? await provider.items(
                    in: library.id,
                    kind: library.kind,
                    page: PageRequest(startIndex: offset, limit: chunkSize, sort: .default)
                ) else { break }
                if page.items.isEmpty { break }
                // Enrich any guid-less movie/series (e.g. a Plex series whose list
                // response omitted its Guid array) via its fuller per-item record,
                // so the store is keyed on real strong ids — origin-agnostic and
                // complete with Plex as a destination, not just a source.
                let prepared = await IdentityEnrichment.prepare(page.items) { item in
                    try? await provider.item(id: item.id)
                }
                inconclusive = inconclusive || prepared.inconclusive
                await index.ingest(prepared.indexable, accountID: accountID, serverInfo: serverInfo)
                offset += page.items.count
                if offset >= page.totalCount { break }
            }
        }
        // Only mark conclusively built when every guid-less item was resolved; an
        // inconclusive scan stays cold so the next warm retries it (never warm-and-
        // forget with a missing Plex copy).
        if !inconclusive {
            await index.finishRebuild(for: accountID)
        }
    }

    /// Flushes the identity index when the active profile changes so the next warm
    /// rebuilds it for the now-active profile's accounts.
    private func resetIdentityIndex() {
        identityWarmTask?.cancel()
        identityWarmTask = nil
        _identityIndex = IdentityIndex()
        identitySnapshot = .empty
        identitySnapshotStore.update(.empty)
    }

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

    /// For each account, the Plex Home-user UUID the current override resolves to.
    /// Lets the reconciler tell an already-satisfied protected switch apart from a
    /// stale override left by a previous profile, so a just-entered PIN isn't
    /// re-armed into an infinite prompt/re-prompt loop.
    private var plexResolvedHomeUser: [String: String] = [:]

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
        ratingsProvider: (any ExternalRatingsProviding)? = nil,
        traktService: TraktService? = nil
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
        // Seed Trakt with the active profile's namespace so its scrobbler and the
        // Settings connection model read that profile's own Trakt tokens.
        self.traktService = traktService ?? TraktServiceFactory.make(namespace: ns)
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
            JellyfinProvider(
                session: session,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive),
                hybridEngineEnabled: HybridPlayback.enabled
            )
        }
        registry.register(.plex) { session in
            PlexProvider(
                session: session,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive),
                hybridEngineEnabled: HybridPlayback.enabled,
                connectionRefresh: PlexProvider.connectionRefresh(for: session)
            )
        }
        return registry
    }

    /// Restores stored accounts on launch (relaunch without re-login), migrating
    /// any legacy single session first. Shows the profile picker when the
    /// household has opted into "ask on startup".
    public func bootstrap() {
        accountStore.migrateLegacySessionIfNeeded()
        reloadAccounts()
        // The "Ask which profile on startup" toggle is the single source of
        // truth for whether the launch picker appears. When it's ON we MUST
        // show the picker even if the Apple TV system user has a remembered
        // selection — the remembered pick becomes the picker's initial focus,
        // not a reason to skip the picker entirely. Otherwise an already-
        // selected household would never see the picker again, which
        // contradicts what the toggle promises.
        //
        // When the toggle is OFF, the remembered selection (or default
        // profile) is used silently and the picker stays hidden.
        isChoosingProfile = profilesModel.askProfileOnStartup
            && profilesModel.profiles.count > 1
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

    /// The active accounts paired with their resolved providers. Multi-account
    /// Home/Search fan out over this list (one provider call per account,
    /// merged by the view model). Tokens are resolved on demand and never
    /// stored on the value.
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

    /// Aligns the in-memory Plex identity for **every** signed-in Plex account
    /// with the active profile's per-account Home-user bindings:
    /// - Unprotected bindings switch silently on each account.
    /// - The first protected binding (in account order) raises a PIN prompt;
    ///   subsequent ones are processed after the user submits or cancels.
    /// - An account with no binding drops any existing override for that
    ///   account (back to the admin user).
    private func ensurePlexIdentityForActiveProfile() {
        let profile = profilesModel.activeProfile
        let plexAccounts = accounts.filter { $0.server.provider == .plex }

        var pinTarget: (accountID: String, binding: PlexHomeUserBinding)?

        for account in plexAccounts {
            if let binding = profile.homeUserBinding(forPlexAccount: account.id) {
                if binding.requiresPIN == true {
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
                        plexTokenOverrides[account.id] = nil
                        plexResolvedHomeUser[account.id] = nil
                        plexIdentityGeneration += 1
                    }
                    if pinTarget == nil {
                        pinTarget = (account.id, binding)
                    }
                } else {
                    Task { await performPlexSwitch(accountID: account.id, homeUserID: binding.homeUserID, pin: nil) }
                }
            } else {
                if plexTokenOverrides[account.id] != nil {
                    plexTokenOverrides[account.id] = nil
                    plexResolvedHomeUser[account.id] = nil
                    plexIdentityGeneration += 1
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
            plexTokenOverrides.removeAll()
            plexResolvedHomeUser.removeAll()
            plexIdentityGeneration += 1
        }
    }

    /// Performs the Plex Home-user switch and installs the resulting token as the
    /// account's override, bumping the identity generation so content reloads.
    private func performPlexSwitch(accountID: String, homeUserID: String, pin: String?) async {
        PlozzLog.auth.debug("performPlexSwitch acct=\(accountID) home=\(homeUserID) pin?=\(pin != nil)")
        guard let adminToken = accountStore.token(for: accountID) else {
            // Surface a user-visible error instead of silently returning; otherwise a
            // PIN submission with no cached admin token vanishes (no dismissal, no error)
            // and the user can't tell whether the PIN was accepted.
            PlozzLog.auth.error("no admin token cached for acct=\(accountID) — surfacing error")
            if pin != nil { plexPINError = "Couldn’t reach this Plex account. Try signing in again." }
            return
        }
        do {
            let token = try await plexHomeUserSwitch(homeUserID, pin, adminToken, deviceID)
            PlozzLog.auth.debug("Plex Home-user switch OK — clearing pendingPlexPINRequest")
            plexTokenOverrides[accountID] = token
            plexResolvedHomeUser[accountID] = homeUserID
            pendingPlexPINRequest = nil
            plexPINError = nil
            plexIdentityGeneration += 1
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
        plexTokenOverrides[id] = nil
        plexResolvedHomeUser[id] = nil
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
        updateTraktForActiveProfile()
        reloadAccounts()
        isChoosingProfile = false
        ensurePlexIdentityForActiveProfile()
    }

    /// Creates or updates a profile from an editor draft. Updating the active
    /// profile re-applies its settings + account scope immediately.
    ///
    /// A cosmetic-only edit (the new Settings → Profile editor) passes an
    /// empty `activeAccountIDs` to mean "leave membership alone." Settings →
    /// Servers & Libraries is the authoritative surface for membership now and
    /// writes through `setAccount(_, includedInActiveProfile:)`.
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
                profile.plexHomeUserAvatarURL = draft.plexHomeUserAvatarURL
                profile.plexHomeUserBindings = draft.plexHomeUserBindings
                profile.avatarImageURL = draft.avatarImageURL
                profilesModel.update(profile)
            }
            if !draft.activeAccountIDs.isEmpty {
                profilesModel.setActiveAccountIDs(draft.activeAccountIDs, for: id)
            }
            if id == profilesModel.activeProfileID {
                rebuildSettingsModels()
                updateTraktForActiveProfile()
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
                plexHomeUserRequiresPIN: draft.plexHomeUserRequiresPIN,
                plexHomeUserAvatarURL: draft.plexHomeUserAvatarURL,
                plexHomeUserBindings: draft.plexHomeUserBindings,
                avatarImageURL: draft.avatarImageURL
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
            updateTraktForActiveProfile()
            reloadAccounts()
        }
    }

    // MARK: Household preferences

    /// Opt the household into the profile UX (shows the "Enable Profiles"
    /// affordance in Settings, surfaces profile management). Idempotent.
    public func enableProfiles() {
        profilesModel.enableProfiles()
    }

    /// Opt the household out of the profile UX. Only honored with a single
    /// profile — `ProfilesModel.disableProfiles()` refuses when there are
    /// multiple profiles so they don't become unreachable.
    public func disableProfiles() {
        profilesModel.disableProfiles()
    }

    /// Persists the "Ask which profile on startup" launch-picker toggle.
    public func setAskProfileOnStartup(_ value: Bool) {
        profilesModel.setAskProfileOnStartup(value)
    }

    /// Whether `accountID` is included in the active profile's "Use this
    /// server" set. Used by Settings to drive the per-server toggle.
    public func isAccountIncludedInActiveProfile(_ accountID: String) -> Bool {
        activeAccountIDs.contains(accountID)
    }

    /// Toggles inclusion of `accountID` in the active profile's account set
    /// ("Use this server" toggle on Settings → Servers & Libraries → server).
    public func setAccount(_ accountID: String, includedInActiveProfile included: Bool) {
        let profileID = profilesModel.activeProfileID
        let current = Set(profilesModel.activeAccountIDs(
            for: profileID,
            fallback: accountStore.activeAccountIDs()
        ))
        var next = current
        if included { next.insert(accountID) } else { next.remove(accountID) }
        profilesModel.setActiveAccountIDs(Array(next), for: profileID)
        reloadAccounts()
    }

    /// The account subset currently stored for a profile (for the editor), or
    /// the resolved fallback when it never chose one.
    public func activeAccountIDs(forProfile id: String) -> [String] {
        Array(profilesModel.activeAccountIDs(for: id, fallback: accountStore.activeAccountIDs()))
    }

    // MARK: Internals

    private func reloadAccounts() {
        registry.invalidateCache()
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

    /// Repoints Trakt (and its shared scrobbler) at the active profile's own
    /// connection so each household profile scrobbles to its own Trakt account.
    /// Fire-and-forget: the status refresh is async and best-effort.
    private func updateTraktForActiveProfile() {
        let ns = profilesModel.activeNamespace
        resetWatchReconciler()
        resetIdentityIndex()
        Task { await traktService.setActiveProfile(namespace: ns) }
    }

    private func apply(_ event: SessionEvent) {
        machine.apply(event)
        state = machine.state
    }
}
