import Foundation
import Observation
import AppRuntime
import CoreModels
import CoreNetworking
import FeatureAuth
import FeatureDiscovery
import FeatureMusic
import FeatureProfiles
import MediaTransportCore
import MediaDownloads
import MediaTransportFTP
import MediaTransportHTTP
import MediaTransportSMB
import MediaTransportWebDAV
import MediaTransportSFTP
import MediaTransportNFS
import ProviderJellyfin
import ProviderPlex
import ProviderShare
import EnginePlozzigen
import RatingsService
import TraktService
import SeerService
import SimklService
import LastFmService
import AniListService
import MALService
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

    /// Provider chosen for the add-account flow currently in progress, so that
    /// cancelling Quick Connect returns to *that* provider's server picker
    /// rather than the provider chooser. `nil` starts the flow at the chooser.
    public private(set) var pendingOnboardingProvider: ProviderKind?

    /// A Jellyfin item id requested via a Top Shelf deep link
    /// (`plozz://item/<id>`) that the signed-in UI should open for playback.
    /// Set when the app is launched/foregrounded from a Top Shelf card and
    /// cleared once the Home tab has routed to it.
    public var pendingPlayItemID: String?

    /// Per-profile settings facet. Owns the settings sub-models rebuilt when the
    /// active profile changes so switching profiles swaps the active
    /// theme/spoiler/caption/diagnostics state cleanly. Views depend on this
    /// narrow collaborator (`appState.profileSettings.themeModel`) rather than
    /// widening `AppState`'s observable surface. When the caller injects models
    /// (tests), they're used as-is and not rebuilt.
    public let profileSettings: ProfileSettingsModel

    /// Opt-in, off-by-default consent for sending anonymised crash reports.
    /// Deliberately **app-wide** (created once, never rebuilt per profile) and
    /// stored under an un-namespaced key — crash reporting is a device/app-level
    /// choice, not a per-profile persona. See `CrashReportingSettings`.
    public let crashReportingModel = CrashReportingSettingsModel()

    /// The household's profiles + active selection. Owned at the app level and
    /// layered on top of the multi-account core.
    public let profilesModel: ProfilesModel

    /// The app-scoped audio playback engine. Created **once** and shared across
    /// profile switches so there's only ever a single `AVQueuePlayer` — otherwise
    /// switching profiles (which rebuilds the tab subtree) would spin up a second
    /// controller and leave the previous profile's track audibly playing. Stopped
    /// on profile switch so a new profile starts silent.
    public let audioController = AudioPlaybackController()

    /// Accounts just added in the current add flow whose libraries the
    /// "choose your libraries" step should offer. `RootView` renders that step
    /// from this; empty when none is pending.
    public private(set) var pendingLibrarySelectionAccountIDs: [String] = []

    /// How to continue onboarding once the library step is confirmed. Carries the
    /// first-run decision (profile-setup detour vs. straight to the app) and
    /// whether a freshly-picked Plex identity still needs applying afterward.
    private struct PendingOnboardingContinuation {
        var isFirstRun: Bool
        var applyPlexIdentity: Bool
    }
    private var pendingOnboardingContinuation: PendingOnboardingContinuation?

    /// When a multi-server Plex sign-in needs a Home-user pick, the chosen
    /// binding is applied to every one of these newly-added Plex accounts (they
    /// share the same Home users). Empty for single-account / Jellyfin adds.
    private var pendingPlexUserApplyToAccountIDs: [String] = []

    /// Provider-agnostic external-ratings enrichment (IMDb/RT/Metacritic via
    /// OMDb when a key is configured; otherwise a no-op). Injected into item
    /// detail so ratings are fetched async without blocking the screen.
    public let ratingsProvider: any ExternalRatingsProviding

    /// Trakt sync: owns the connection lifecycle for Settings and exposes the
    /// scrobbler the player uses to sync watches to the user's Trakt history.
    /// A no-op when no Trakt client credentials are configured.
    public let traktService: TraktService

    /// Simkl sync: device-code OAuth + history scrobble. Mirrors Trakt's pattern.
    public let simklService: SimklService

    /// Seerr (Overseerr / Jellyseerr) discovery: backs the Home hero's featured
    /// seam (`trending`) and the Settings connect flow. Inert until the user
    /// saves a server URL + API key.
    public let seerService: SeerService

    /// AniList sync: token-entry OAuth + GraphQL list update (anime only).
    public let anilistService: AniListService

    /// MyAnimeList sync: device-code OAuth + list update (anime only).
    public let malService: MALService

    /// Last.fm music scrobbling: on-device desktop-auth poll + track.scrobble.
    /// User-scoped (not tied to a media provider); its scrobbler is fanned into
    /// the audio controller so listening in Plozz shows up on the user's Last.fm.
    public let lastfmService: LastFmService

    /// The handler behind every card's press-and-hold context menu. Lazily
    /// created so it can capture `self`; resolves the owning provider per item
    /// and performs watched-state (and future) actions against the server.
    @ObservationIgnored
    public private(set) lazy var mediaItemActionHandler: any MediaItemActionHandling =
        MediaItemActionCoordinator(appState: self)

    /// Durable cross-server watch-state outbox + reconciler. Persists each watch
    /// mutation's intent to disk before the network call and drains it on launch /
    /// foreground / reachability so a watch made while a server was asleep (or the
    /// app offline) still converges every server + Trakt. One reconciler is retained
    /// per profile so a returning profile never creates a competing writer.
    @ObservationIgnored
    private var watchReconcilers: [String: WatchStateReconciler] = [:]
    @ObservationIgnored
    private var trackerProfileGeneration: UInt64 = 0
    public var watchReconciler: WatchStateReconciler {
        let profileID = profilesModel.activeProfileID
        if let existing = watchReconcilers[profileID] { return existing }
        let created = makeWatchReconciler(profileID: profileID)
        watchReconcilers[profileID] = created
        return created
    }

    /// Per-profile offline-download registries (durable, non-evictable), created
    /// lazily and kept per profile so switching profiles never crosses catalogs —
    /// the same isolation discipline as `watchReconcilers`.
    @ObservationIgnored
    private var offlineDownloadRegistries: [String: DownloadedMediaRegistry] = [:]
    @ObservationIgnored
    private let downloadStorageLocator: any DownloadStorageLocating =
        PlatformDownloadStorageLocator()

    /// The offline-playback resolver for the active profile, injected into the
    /// player so a completed download plays from disk. `nil` when durable state is
    /// unavailable (the player then behaves exactly as if offline never existed).
    public var offlinePlaybackResolver: (any OfflinePlaybackResolving)? {
        guard let durableLocalStateStore else { return nil }
        let profileID = profilesModel.activeProfileID
        let registry: DownloadedMediaRegistry
        if let existing = offlineDownloadRegistries[profileID] {
            registry = existing
        } else {
            let store: any DownloadedMediaStoring
            do {
                store = try DurableDownloadedMediaStore(
                    store: durableLocalStateStore,
                    profileID: profileID,
                    onLoadFailure: {
                        PlozzLog.app.error(
                            "Durable download catalog unavailable; preserving corrupt state"
                        )
                    }
                )
            } catch {
                PlozzLog.app.error(
                    "Durable download catalog address invalid; using memory only"
                )
                store = InMemoryDownloadedMediaStore()
            }
            registry = DownloadedMediaRegistry(store: store)
            offlineDownloadRegistries[profileID] = registry
        }
        return RegistryOfflinePlaybackResolver(
            registry: registry,
            storage: downloadStorageLocator
        )
    }

    /// Builds the reconciler with profile-scoped durable state and an applier that
    /// resolves providers / tracker scrobblers live on the main actor.
    private func makeWatchReconciler(
        profileID: String
    ) -> WatchStateReconciler {
        let profile = profilesModel.profiles.first { $0.id == profileID }
            ?? profilesModel.activeProfile
        let trackerNamespace = profile.settingsNamespace(
            isDefault: profilesModel.isDefault(profile)
        )
        let boundTraktScrobbler = TraktServiceFactory.make(
            namespace: trackerNamespace
        ).scrobbler
        let boundSimklScrobbler = SimklServiceFactory.make(
            namespace: trackerNamespace
        ).scrobbler
        let boundAniListScrobbler = AniListServiceFactory.make(
            namespace: trackerNamespace
        ).scrobbler
        let boundMALScrobbler = MALServiceFactory.make(
            namespace: trackerNamespace
        ).scrobbler
        let store: any WatchMutationStoring
        if let durableLocalStateStore {
            do {
                store = try DurableWatchMutationStore(
                    store: durableLocalStateStore,
                    profileID: profileID,
                    onLoadFailure: {
                        PlozzLog.app.error(
                            "Durable watch outbox unavailable; preserving corrupt state"
                        )
                    }
                )
            } catch {
                PlozzLog.app.error(
                    "Durable watch outbox address invalid; using memory only"
                )
                store = InMemoryWatchMutationStore()
            }
        } else {
            store = InMemoryWatchMutationStore()
        }
        let applier = AppShellWatchMutationApplier(
            isActive: { [weak self] in
                await MainActor.run {
                    self?.profilesModel.activeProfileID == profileID
                }
            },
            resolveProvider: { [weak self] accountID in
                await MainActor.run {
                    guard self?.profilesModel.activeProfileID == profileID
                    else { return nil }
                    return self?.accountsProviders.provider(forAccountID: accountID)
                }
            },
            traktScrobbler: {
                boundTraktScrobbler
            },
            simklScrobbler: {
                boundSimklScrobbler
            },
            anilistScrobbler: {
                boundAniListScrobbler
            },
            malScrobbler: {
                boundMALScrobbler
            },
            allAccountIDs: { [weak self] in
                // The set the identity index actually warms and that Home/Search
                // fan out over — `homeAccounts` (the active accounts, with the
                // primary fallback). Using *all* signed-in accounts here would list
                // inactive accounts the index never warms, so `notYetIndexed` could
                // never empty (expansion perpetually "inconclusive" until the retry
                // cap) and episode expansion would probe servers outside the active
                // profile. Scope must match what gets indexed.
                await MainActor.run { self?.accountsProviders.homeAccounts.map(\.account.id) ?? [] }
            },
            indexedSeriesSources: { [identitySnapshotStore = identityIndex.identitySnapshotStore] originSeries in
                identitySnapshotStore.current.sources(for: originSeries).filter { $0.kind == .series }
            },
            indexedSources: { [identitySnapshotStore = identityIndex.identitySnapshotStore] identities, kind, anchorTitle, anchorYear in
                identitySnapshotStore.current.sources(
                    forIdentities: identities,
                    kind: kind,
                    anchorTitle: anchorTitle,
                    anchorYear: anchorYear
                )
            },
            indexedAccountIDs: { [identitySnapshotStore = identityIndex.identitySnapshotStore] in
                identitySnapshotStore.current.indexedAccountIDs
            }
        )
        return WatchStateReconciler(
            store: store,
            applier: applier,
            onPersistenceFailure: {
                PlozzLog.app.error("Durable watch outbox write failed")
            }
        )
    }

    /// Drains the watch-state outbox. Safe to call repeatedly (no-op when empty);
    /// invoked on launch, on foreground, and after a watch mutation is enqueued.
    public func drainWatchOutbox() {
        let reconciler = watchReconciler
        Task { await reconciler.drain() }
    }

    /// The outbox's not-yet-confirmed mutations, so the Home Continue Watching row
    /// can reflect in-app plays the servers haven't recorded yet (r8-cw-outbox-patch).
    public func pendingWatchMutations() async -> [WatchMutation] {
        await watchReconciler.snapshot().pending
    }

    /// Recently-applied in-progress resume writes (keyed by `"accountID:itemID"`),
    /// so Home's Continue Watching overlay can clamp a server's drain-time timestamp
    /// inflation back down to the play's real time — the offline-drained-Plex-resume
    /// re-float fix. Short-lived (see ``WatchStateReconciler`` `resumeRecencyTTL`).
    public func appliedWatchRecency() async -> [String: AppliedResumeRecord] {
        await watchReconciler.snapshot().appliedRecency
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

    /// Durably records a **mid-play convergence checkpoint** without ending the live
    /// session: it enqueues + drains so progress fans out to the **other** servers
    /// (the launch server stays deferred by its still-active live session and is
    /// caught up by the final `finishLiveWatchSession`). Pure local enqueue + drain
    /// — no optimistic UI flip (the user is in the fullscreen player). Coalesces
    /// cleanly with later checkpoints and the final stop via the reconciler's
    /// newest-wins `capturedAt` clock.
    public func checkpointWatchState(mutation: WatchMutation) {
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
    public func finishLiveWatchSession(accountID: String?, itemID: String, watchedPercent: Double, mutation: WatchMutation?) {
        let reconciler = watchReconciler
        // (a) Index state captured at the moment of stop — the value the fan-out
        // actually saw. If crossServer=0 here, the index never warmed a union for
        // any title, so the stop's targets could only be origin-only.
        FanoutDiagnostics.emit(FanoutDiagnostics.indexStateLine(identityIndex.identitySnapshotStore.current, phase: "stop-index"))
        publishOptimisticWatchState(itemID: itemID, mutation: mutation, watchedPercent: watchedPercent)
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

    /// Optimistically reflect the just-ended playback across every visible surface
    /// the instant the player dismisses, so the user never sees a stale card after
    /// Back. The id set is every server's own item id in the shared source of truth
    /// (the mutation's `targets`, already unioned from the eager identity index when
    /// the stop mutation was built) plus the played item id itself. Routed through
    /// the same optimistic ``MediaItemMutation`` path press-and-hold "Mark watched"
    /// uses, so Home/Detail/Search all update immediately. Purely additive: it never
    /// blocks or replaces the durable fan-out enqueued alongside.
    ///
    /// Two cases:
    ///  - **Finish** (`played == true`): flip the watched badge everywhere and clear
    ///    the resume bar (`resumePosition 0`, `playedPercentage 1`).
    ///  - **Partial watch** (a resume position, no `played`): surface the new resume
    ///    position + fraction so the detail "Resume" affordance and the row tile's
    ///    progress bar update in place — the "watched 4 min, pressed Back, page still
    ///    looks untouched" bug. `watchedPercent` (0...100) becomes the `0...1`
    ///    fraction `PosterCardView` reads.
    private func publishOptimisticWatchState(itemID: String, mutation: WatchMutation?, watchedPercent: Double) {
        guard let mutation else { return }
        var ids = Set(mutation.targets.map(\.itemID))
        ids.insert(itemID)
        // Account-scope the optimistic post to the exact (account,item) copies the
        // fan-out targeted. Without this the bare `itemID` set would false-match a
        // different title that happens to share a Plex ratingKey on another server,
        // flipping the wrong card's badge / resume bar / recency.
        let scoped = Set(mutation.targets.map(\.id))
        if mutation.played == true {
            MediaItemMutation(itemIDs: ids, scopedItemIDs: scoped, played: true, resumePosition: 0, playedPercentage: 1).post()
        } else if let resume = mutation.resumePosition {
            let fraction = max(0, min(watchedPercent / 100, 1))
            MediaItemMutation(itemIDs: ids, scopedItemIDs: scoped, resumePosition: resume, playedPercentage: fraction).post()
        }
    }

    // MARK: - Eager identity index (single source of truth for cross-server sources)

    /// The eager cross-server identity index, extracted into its own
    /// single-responsibility facet. Owns the `identity → sources` index, its warm
    /// lifecycle, the persisted store, and the observed `identitySnapshot`. Depends
    /// on `AppState` only through injected closures (active accounts, active
    /// namespace, and a post-publish outbox re-drain). Lazily built so it can
    /// capture `self` for those closures, mirroring `mediaItemActionHandler`.
    @ObservationIgnored
    public private(set) lazy var identityIndex: IdentityIndexModel = IdentityIndexModel(
        activeAccounts: { [weak self] in self?.accountsProviders.homeAccounts ?? [] },
        namespace: { [weak self] in self?.profilesModel.activeNamespace },
        onPublish: { [weak self] in self?.drainWatchOutbox() }
    )

    /// App-lifetime main-thread responsiveness probe (dev-only; nil unless
    /// `PLZXMEM=1`). Held so it lives as long as the app state.
    @ObservationIgnored
    private var perfHitchProbeTask: Task<Void, Never>?
    @ObservationIgnored
    private var perfMemorySamplerTask: Task<Void, Never>?

    private var machine = SessionStateMachine()

    /// The accounts + providers hub — owns the account store, provider registry,
    /// signed-in `accounts`, the active-account subset, and all provider
    /// resolution. The Plex-home-user / media-share / profile-flow / household
    /// concerns sit downstream of this hub. Its Plex-override token/credential
    /// seams and media-share preferred-keys hook are wired in `init`.
    public let accountsProviders: AccountsProvidersModel

    /// The Plex Home users ("Who's watching?") facet — owns per-account Plex
    /// token overrides, the PIN-prompt state, `plexIdentityGeneration`, and the
    /// profile↔Home-user switching. It resolves the accounts hub's token/credential
    /// seams. Lazily built so it can capture `self` for the PIN-cancel
    /// `switchProfile` fallback, mirroring `identityIndex`.
    @ObservationIgnored
    public private(set) lazy var plexHomeUsers: PlexHomeUsersModel = PlexHomeUsersModel(
        accountsProviders: accountsProviders,
        profilesModel: profilesModel,
        switchProfile: { [weak self] id in self?.profileFlow.switchProfile(to: id) }
    )

    /// The profile-flow + household facet — owns the launch-picker state and the
    /// profile switch/create/edit/remove + household-membership orchestration. The
    /// Plex facet's PIN-cancel fallback (above) wires into its `switchProfile`.
    /// Lazily built so it can capture `self` for the tracker-rescope and
    /// watch-reconciler-discard closures (those domains still live on `AppState`).
    @ObservationIgnored
    public private(set) lazy var profileFlow: ProfileFlowModel = ProfileFlowModel(
        profilesModel: profilesModel,
        accountsProviders: accountsProviders,
        plexHomeUsers: plexHomeUsers,
        profileSettings: profileSettings,
        audioController: audioController,
        updateTrackersForActiveProfile: { [weak self] in self?.updateTraktForActiveProfile() },
        discardWatchReconciler: { [weak self] id in self?.watchReconcilers[id] = nil }
    )
    public let authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving

    /// The media-share runtime facet — owns the share runtime/coordinator, its
    /// network-file resolver, the account-lifecycle service, the app-wide scan
    /// status, the active-share set, and the "Scan now" entry point. Built in
    /// `init` once the accounts hub exists (it depends into the hub for rescans).
    public let mediaShare: MediaShareRuntimeFacet
    private let durableLocalStateStore: DurableLocalStateStore?
    /// Optional tvOS system-user seam (default app-owned no-op). See
    /// `SystemProfileBridging`.
    private let systemBridge: SystemProfileBridging


    public init(
        accountStore: AccountPersisting? = nil,
        registry: ProviderRegistry? = nil,
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? = nil,
        mediaShareRuntime: (any MediaShareRuntime)? = nil,
        durableLocalStateStore: DurableLocalStateStore? = nil,
        profilesModel: ProfilesModel? = nil,
        systemBridge: SystemProfileBridging? = nil,
        subtitleBehaviorModel: SubtitleBehaviorModel? = nil,
        subtitleStyleModel: SubtitleStyleModel? = nil,
        spoilerModel: SpoilerSettingsModel? = nil,
        playbackModel: PlaybackSettingsModel? = nil,
        themeModel: ThemeSettingsModel? = nil,
        themeMusicModel: ThemeMusicSettingsModel? = nil,
        diagnosticsModel: DiagnosticsSettingsModel? = nil,
        musicPlayerModel: MusicPlayerSettingsModel? = nil,
        homeLibraryVisibilityModel: HomeLibraryVisibilityModel? = nil,
        uiDensityModel: UIDensitySettingsModel? = nil,
        cardStyleModel: CardStyleSettingsModel? = nil,
        watchStatusIndicatorModel: WatchStatusIndicatorSettingsModel? = nil,
        navigationStyleModel: NavigationStyleSettingsModel? = nil,
        transparencyModel: TransparencyPreferenceModel? = nil,
        nightShiftModel: NightShiftSettingsModel? = nil,
        ratingsProvider: (any ExternalRatingsProviding)? = nil,
        traktService: TraktService? = nil,
        simklService: SimklService? = nil,
        seerService: SeerService? = nil,
        anilistService: AniListService? = nil,
        malService: MALService? = nil,
        lastfmService: LastFmService? = nil
    ) {
        let resolvedAccountStore = accountStore ?? Self.makeDefaultAccountStore()
        let resolvedDurableLocalStateStore: DurableLocalStateStore?
        if let durableLocalStateStore {
            resolvedDurableLocalStateStore = durableLocalStateStore
        } else if accountStore == nil {
            do {
                resolvedDurableLocalStateStore =
                    try DurableLocalStateStoreFactory.userIndependent()
            } catch {
                PlozzLog.app.error(
                    "Durable local media state unavailable for this launch"
                )
                resolvedDurableLocalStateStore = nil
            }
        } else {
            resolvedDurableLocalStateStore = nil
        }
        self.durableLocalStateStore = resolvedDurableLocalStateStore
        let resolvedRuntime: any MediaShareRuntime = mediaShareRuntime
            ?? AppShellMediaShareRuntimeFactory.make(accountStore: resolvedAccountStore)
        let defaultAuthenticatedHTTPResolver: ManagedAuthenticatedHTTPResolver?
        let resolvedAuthenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
        if let authenticatedHTTPResolver {
            self.authenticatedHTTPResolver = authenticatedHTTPResolver
            resolvedAuthenticatedHTTPResolver = authenticatedHTTPResolver
            defaultAuthenticatedHTTPResolver = nil
        } else {
            let resolver = ManagedAuthenticatedHTTPResolver()
            self.authenticatedHTTPResolver = resolver
            resolvedAuthenticatedHTTPResolver = resolver
            defaultAuthenticatedHTTPResolver = resolver
        }
        let resolvedRegistry = registry ?? Self.makeDefaultRegistry(
            runtime: resolvedRuntime,
            authenticatedHTTPResolver: resolvedAuthenticatedHTTPResolver,
            durableLocalStateStore: resolvedDurableLocalStateStore
        )
        let resolvedProfilesModel = profilesModel ?? Self.makeDefaultProfilesModel()
        self.profilesModel = resolvedProfilesModel
        // The accounts + providers hub. Its Plex-override token/credential seams
        // and media-share preferred-keys hook are wired below, once `self` is
        // fully initialized (phase 2).
        self.accountsProviders = AccountsProvidersModel(
            accountStore: resolvedAccountStore,
            registry: resolvedRegistry,
            profilesModel: resolvedProfilesModel
        )
        // The media-share runtime facet, built once the hub exists (it depends
        // into the hub for the rescan path). Owns the runtime, account service,
        // scan status, and the scan-reporter wiring.
        self.mediaShare = MediaShareRuntimeFacet(
            runtime: resolvedRuntime,
            accountsProviders: self.accountsProviders
        )
        self.systemBridge = systemBridge ?? Self.makeDefaultSystemBridge()
        self.ratingsProvider = ratingsProvider ?? RatingsServiceFactory.make()

        // If the caller supplied any settings model, treat them all as injected
        // (test path) and don't rebuild them on profile switch. Otherwise build
        // them scoped to the active profile's namespace. Ownership of the
        // per-profile settings sub-models + this rebuild lifecycle lives in
        // `ProfileSettingsModel`.
        let ns = (profilesModel ?? self.profilesModel).activeNamespace
        self.profileSettings = ProfileSettingsModel(
            namespace: ns,
            subtitleBehaviorModel: subtitleBehaviorModel,
            subtitleStyleModel: subtitleStyleModel,
            spoilerModel: spoilerModel,
            playbackModel: playbackModel,
            themeModel: themeModel,
            themeMusicModel: themeMusicModel,
            diagnosticsModel: diagnosticsModel,
            musicPlayerModel: musicPlayerModel,
            homeLibraryVisibilityModel: homeLibraryVisibilityModel,
            uiDensityModel: uiDensityModel,
            cardStyleModel: cardStyleModel,
            watchStatusIndicatorModel: watchStatusIndicatorModel,
            navigationStyleModel: navigationStyleModel,
            transparencyModel: transparencyModel,
            nightShiftModel: nightShiftModel
        )
        // Seed Trakt with the active profile's namespace so its scrobbler and the
        // Settings connection model read that profile's own Trakt tokens.
        self.traktService = traktService ?? TraktServiceFactory.make(namespace: ns)
        // Seed other trackers with the same profile namespace.
        self.simklService = simklService ?? SimklServiceFactory.make(namespace: ns)
        // Seerr uses ONE shared household connection (user-independent Keychain);
        // profiles differ only by which Seerr user they request as (per request).
        self.seerService = seerService ?? Self.makeDefaultSeerService()
        self.anilistService = anilistService ?? AniListServiceFactory.make(namespace: ns)
        self.malService = malService ?? MALServiceFactory.make(namespace: ns)
        // Last.fm is user-scoped like the trackers; seed it with the active
        // profile's namespace so each profile links its own Last.fm account.
        self.lastfmService = lastfmService ?? LastFmServiceFactory.make(namespace: ns)

        // Fan the Last.fm scrobbler into the audio controller's reporting seam.
        // The scrobbler is a stable handle (never rebuilt on profile switch — only
        // its token store's namespace changes), so capturing it once here is safe
        // across profile changes. It runs alongside the provider-bound reporter;
        // the scrobbler itself applies Last.fm's own eligibility rule and no-ops
        // when Last.fm is unconfigured/disconnected.
        let lastfmScrobbler = self.lastfmService.scrobbler
        self.audioController.scrobbleObserver = { track, event, position, duration in
            await lastfmScrobbler.handle(
                track: track, event: event, position: position, duration: duration
            )
        }

        defaultAuthenticatedHTTPResolver?.configure { [weak self] locator in
            guard let self,
                  let account = self.accountsProviders.accountStore.loadAccounts().first(where: {
                      $0.id == locator.accountID
                  }),
                  account.server.provider == locator.provider,
                  self.plexHomeUsers.effectiveCredentialRevision(for: account)
                    == locator.credentialRevision,
                  let token = self.plexHomeUsers.resolvedToken(for: account.id),
                  !token.isEmpty else {
                throw MediaTransportError.authentication(
                    reason: "inactive authenticated HTTP identity"
                )
            }
            let baseURL: URL
            if account.server.provider == .plex {
                let provider = try self.accountsProviders.registry.provider(
                    for: self.accountsProviders.providerResolutionContext(for: account, token: token)
                )
                guard let originProvider = provider as? AuthenticatedHTTPOriginProviding else {
                    throw MediaTransportError.unsupportedCapability(
                        "dynamic authenticated HTTP origin"
                    )
                }
                baseURL = originProvider.authenticatedHTTPOrigin
            } else {
                baseURL = account.server.baseURL
            }
            return ManagedAuthenticatedHTTPResolver.Context(
                provider: account.server.provider,
                accountID: account.id,
                credentialRevision: self.plexHomeUsers.effectiveCredentialRevision(for: account),
                baseURL: baseURL,
                token: token
            )
        }

        // Wire the accounts hub's Plex-override token/credential seams and its
        // media-share preferred-keys hook now that `self` is fully initialized.
        // These keep Plex-home-user and media-share state out of the hub while
        // preserving exact resolution behavior.
        accountsProviders.tokenResolver = { [weak self] accountID in
            self?.plexHomeUsers.resolvedToken(for: accountID)
        }
        accountsProviders.credentialRevision = { [weak self] account in
            self?.plexHomeUsers.effectiveCredentialRevision(for: account) ?? account.credentialRevision
        }
        accountsProviders.onActiveAccountsChanged = { [weak self] resolved, accounts in
            self?.mediaShare.setActiveShareAccounts(resolved, accounts: accounts)
        }
    }

    private static func makeDefaultAccountStore() -> AccountPersisting {
        do {
            return try DefaultAccountStoreFactory.make()
        } catch {
            reportMediaSharePersistenceFailure(
                error,
                operation: "credential-infrastructure-init"
            )
            return DefaultAccountStoreFactory.makeCredentialOnlyFallback()
        }
    }

    /// Builds the shared-household `SeerService`. The connection (URL + admin key)
    /// is persisted via the **user-independent household Keychain** (same store as
    /// the profile set) so every Apple TV system user shares one Seerr connection;
    /// the acting Seerr user is per-profile and applied per request.
    @MainActor
    private static func makeDefaultSeerService() -> SeerService {
        #if canImport(Security)
        let store = HouseholdSeerConnectionStore(secureStore: KeychainStore(service: "com.plozz.app.household"))
        return SeerServiceFactory.make(connectionStore: store)
        #else
        return SeerServiceFactory.make()
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

    /// Registers the providers this build links. Jellyfin/Emby/Plex are each a
    /// single `register(kind, …)` line; the media-share provider is registered
    /// by the runtime, which owns the transport composition and coordinator.
    private static func makeDefaultRegistry(
        runtime: any MediaShareRuntime,
        authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving,
        durableLocalStateStore: DurableLocalStateStore?
    ) -> ProviderRegistry {
        let registry = ProviderRegistry()
        registry.register(.jellyfin) { context in
            JellyfinProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive),
                hybridEngineEnabled: HybridPlayback.enabled
            )
        }
        registry.register(.emby) { context in
            JellyfinProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive),
                hybridEngineEnabled: HybridPlayback.enabled,
                authenticatedStreamProber: PlozzigenAuthenticatedHTTPStreamProber(
                    resolver: authenticatedHTTPResolver
                )
            )
        }
        registry.register(.plex) { context in
            PlexProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive),
                hybridEngineEnabled: HybridPlayback.enabled,
                connectionRefresh: PlexProvider.connectionRefresh(for: context.session)
            )
        }
        runtime.registerProvider(
            into: registry,
            durableLocalStateStore: durableLocalStateStore
        )
        return registry
    }

    /// Restores stored accounts on launch (relaunch without re-login). Shows the
    /// profile picker when the household has opted into "ask on startup".
    public func bootstrap() {
        // Dev-only: start the main-thread responsiveness probe (no-op unless
        // PLZXMEM=1) so we can measure whether background share scans stall the UI.
        if perfHitchProbeTask == nil {
            perfHitchProbeTask = BrowseDiagnostics.startMainThreadHitchProbe()
        }
        if perfMemorySamplerTask == nil {
            perfMemorySamplerTask = BrowseDiagnostics.startSampler(label: "app")
        }
        do {
            try accountsProviders.accountStore.recoverCredentialMutations()
        } catch {
            PlozzLog.auth.error("Credential recovery failed; incomplete shares remain hidden")
        }
        accountsProviders.reloadAccounts()
        PlozzLog.boot("bootstrap accountsProviders.accounts=\(accountsProviders.accounts.count) activeIDs=\(accountsProviders.activeAccountIDs.count)")
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
        profileFlow.prepareLaunchPicker()
        apply(.restored(accountsProviders.accounts))
        // Honor a remembered/auto-landed profile's Plex Home-user mapping at
        // launch. When the picker is shown, the switch happens once the user
        // picks instead.
        if !profileFlow.isChoosingProfile {
            plexHomeUsers.ensurePlexIdentityForActiveProfile()
        }

        // One-time migration of any legacy per-profile Seerr connection into the
        // shared household slot, then an initial reachability probe. Runs on the
        // main actor (inherited); safe because migration no-ops once the household
        // slot is set. The result's `promotedUserID` is intentionally not applied:
        // the legacy per-profile `userId` was off-by-default and never set by the
        // connect UI, so it's always nil in practice; per-profile acting users are
        // established via the (upcoming) Settings mapping, not migration.
        let seerNamespaces: [String?] = [nil] + profilesModel.profiles.map { $0.id }
        Task { [seerService] in
            await seerService.migrateLegacyConnectionIfNeeded(namespaces: seerNamespaces)
            await seerService.refreshStatus()
        }
    }

    /// Whether the environment permits remembering the selected profile for the
    /// current Apple TV system user (see `SystemProfileBridging`). Wired in
    /// Phase 1: combined with `ProfilesModel.hasRememberedSelection`, it lets the
    /// launch picker auto-skip for a system user who already chose a profile.
    public var mayRememberProfileSelection: Bool { systemBridge.mayRememberProfileSelection }

    public var lastServerStore: LastServerStoring { UserDefaultsLastServerStore() }

    /// Maps a household **profile** to a Seerr user (or clears the mapping when
    /// `user` is `nil`, reverting to requesting as admin). Non-secret metadata,
    /// persisted on the profile — mirrors `setPlexHomeUserForActiveProfile`, but
    /// operates on any profile by id so the Settings list can map every member.
    /// No re-probe needed: the acting user is read per-request from the active
    /// profile, so a mapping change takes effect on the next request.
    public func setSeerrUserForProfile(profileID: String, user: SeerUser?) {
        guard let profile = profilesModel.profiles.first(where: { $0.id == profileID }) else { return }
        let updated = profile.settingSeerrUser(
            id: user?.id,
            name: user?.name,
            avatarURL: user?.avatarURL?.absoluteString
        )
        profilesModel.update(updated)
    }


    // MARK: Events

    /// Handles an incoming deep link. Recognised `plozz://item/<id>` links queue
    /// the item for playback once the user is signed in.
    public func handle(url: URL) {
        if let id = TopShelf.itemID(from: url) {
            pendingPlayItemID = id
        }
    }

    /// Servers this device already has accounts on, grouped for the picker's
    /// one-tap "add another user" targets. Order follows the accounts list
    /// (first-added first); users are listed per server in that same order.
    public var signedInServers: [SignedInServer] {
        var order: [String] = []
        var byKey: [String: (server: MediaServer, users: [String])] = [:]
        for account in accountsProviders.accounts {
            let key = account.server.identityKey
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = (account.server, [])
            }
            byKey[key]?.users.append(account.userName)
        }
        return order.compactMap { key in
            byKey[key].map { SignedInServer(server: $0.server, userNames: $0.users) }
        }
    }

    public func selectServer(_ server: MediaServer) {
        // Remember which provider's flow we're in so a later cancel returns to
        // this picker instead of the chooser.
        pendingOnboardingProvider = server.provider
        apply(.serverSelected(server))
    }

    /// Persists a freshly-authenticated account and advances the machine.
    ///
    /// On a brand-new install (no prior accounts and the one-time first-run
    /// setup not yet done) this seeds the always-present default profile from
    /// the sign-in identity and detours through the profile confirm step;
    /// otherwise it enters the app directly.
    public func didAuthenticate(_ session: UserSession) {
        let isFirstRun = accountsProviders.accounts.isEmpty && !profilesModel.firstRunProfileSetupComplete
        // Media shares are identified by their share path (host/port/share), not a
        // random UUID, so re-adding the same share — e.g. to fix its password —
        // updates the existing account in place (new credential revision, old one
        // retired) instead of forking a duplicate account. Other providers keep a
        // freshly-minted UUID identity.
        let account = session.server.provider == .mediaShare
            ? Account(id: session.server.id, from: session)
            : Account(from: session)
        let previousAccount = accountsProviders.accounts.first { $0.id == account.id }
        do {
            try accountsProviders.accountStore.add(account, token: session.accessToken)
        } catch {
            apply(.authenticationFailed(.unknown("")))
            return
        }
        finalizeAddedAccount(
            session: session,
            account: account,
            previousAccount: previousAccount,
            isFirstRun: isFirstRun
        )
    }

    /// Shared onboarding tail once an account has been persisted: retire the old
    /// credential revision if it actually rotated, refresh state, and hand off to
    /// the library-selection / first-run continuation. Kept separate so the SMB
    /// (token) and WebDAV (credential-envelope) persistence paths converge here.
    private func finalizeAddedAccount(
        session: UserSession,
        account: Account,
        previousAccount: Account?,
        isFirstRun: Bool
    ) {
        // Tear down the OLD credential revision's transport sessions only when the
        // store actually moved to a new revision (a real credential change). An
        // identical re-add is a no-op that keeps the existing revision, so read the
        // persisted revision back rather than trusting the freshly-minted one.
        if let previousAccount,
           let persisted = accountsProviders.accountStore.loadAccounts().first(where: { $0.id == account.id }),
           previousAccount.credentialRevision != persisted.credentialRevision {
            mediaShare.accountService.retireCredential(for: previousAccount)
        }
        accountsProviders.reloadAccounts()
        // Flow finished — next add-account starts at the chooser.
        pendingOnboardingProvider = nil
        pendingLibrarySelectionAccountIDs = [account.id]
        pendingPlexUserApplyToAccountIDs = session.server.provider == .plex ? [account.id] : []
        finishAuthentication(session: session, accountID: account.id, isFirstRun: isFirstRun)
    }

    /// Batch sibling of `didAuthenticate` for a multi-server Plex sign-in: adds
    /// one account per selected server, then runs the onboarding continuation a
    /// single time so the library step / profile setup happen once for the whole
    /// batch. The first server drives the identity used downstream.
    public func didAuthenticatePlexMany(_ sessions: [UserSession]) {
        guard let first = sessions.first else { return }

        let isFirstRun = accountsProviders.accounts.isEmpty && !profilesModel.firstRunProfileSetupComplete
        var addedIDs: [String] = []
        for session in sessions {
            let account = Account(from: session)
            let previousAccount = accountsProviders.accounts.first { $0.id == account.id }
            do {
                try accountsProviders.accountStore.add(account, token: session.accessToken)
                if let previousAccount,
                   previousAccount.credentialRevision != account.credentialRevision {
                    mediaShare.accountService.retireCredential(for: previousAccount)
                }
                addedIDs.append(account.id)
            } catch {
                continue // Skip a failed add; keep the rest of the batch.
            }
        }
        accountsProviders.reloadAccounts()
        pendingOnboardingProvider = nil
        guard !addedIDs.isEmpty else {
            apply(.authenticationFailed(.unknown("")))
            return
        }
        pendingLibrarySelectionAccountIDs = addedIDs
        pendingPlexUserApplyToAccountIDs = addedIDs
        finishAuthentication(session: first, accountID: addedIDs[0], isFirstRun: isFirstRun)
    }

    /// After an account is persisted, decides the next onboarding step. A Plex
    /// account with 2+ Home users that this profile hasn't bound yet detours
    /// through the "Which Plex user are you?" picker first; otherwise we proceed
    /// straight to the "choose your libraries" step.
    private func finishAuthentication(session: UserSession, accountID: String, isFirstRun: Bool) {
        // A media share exposes exactly one browsable "library" (its root
        // folder), so the "choose your libraries" opt-out step is pure friction —
        // there's nothing to choose between. Skip straight past it (the single
        // library stays visible by default) while still doing the first-run
        // profile seeding the step would have done.
        if session.server.provider == .mediaShare {
            beginLibrarySelection(
                isFirstRun: isFirstRun,
                seedName: session.userName,
                seedAvatar: session.avatarURL?.absoluteString,
                applyPlexIdentity: false,
                skipSelectionStep: true
            )
            return
        }
        if session.server.provider == .plex,
           profilesModel.activeProfile.homeUserBinding(forPlexAccount: accountID) == nil {
            Task { [weak self] in
                guard let self else { return }
                let users = await self.plexHomeUsers.plexHomeUsers(forAccountID: accountID)
                if users.count >= 2 {
                    self.plexHomeUsers.presentUserSelection(PlexHomeUsersModel.PendingPlexUserSelection(
                        accountID: accountID,
                        serverName: session.server.name,
                        users: users,
                        isFirstRun: isFirstRun
                    ))
                    self.apply(.plexUserSelectionRequired)
                } else {
                    self.beginLibrarySelection(
                        isFirstRun: isFirstRun,
                        seedName: session.userName,
                        seedAvatar: session.avatarURL?.absoluteString,
                        applyPlexIdentity: false
                    )
                }
            }
        } else {
            beginLibrarySelection(
                isFirstRun: isFirstRun,
                seedName: session.userName,
                seedAvatar: session.avatarURL?.absoluteString,
                applyPlexIdentity: false
            )
        }
    }

    /// Enters the "choose your libraries" step. On first run this also seeds the
    /// always-present default profile from the signed-in identity so the later
    /// confirm screen shows who's watching. `applyPlexIdentity` records whether a
    /// freshly-picked Plex Home user still needs applying once the step completes
    /// (deferred so the PIN prompt doesn't interrupt onboarding).
    private func beginLibrarySelection(isFirstRun: Bool, seedName: String, seedAvatar: String?, applyPlexIdentity: Bool, skipSelectionStep: Bool = false) {
        if isFirstRun {
            profilesModel.seedDefaultProfileIdentity(name: seedName, avatarImageURL: seedAvatar)
        }
        pendingOnboardingContinuation = PendingOnboardingContinuation(
            isFirstRun: isFirstRun,
            applyPlexIdentity: applyPlexIdentity
        )
        // Providers with a single implicit library (media shares) skip the
        // "choose your libraries" screen and go straight to the continuation.
        if skipSelectionStep {
            confirmLibrarySelection()
        } else {
            apply(.librarySelectionRequired)
        }
    }

    /// Completes the "choose your libraries" step and continues onboarding: a
    /// first-ever account detours through the profile-setup sub-flow, a later add
    /// drops straight into the app (applying any freshly-picked Plex identity).
    public func confirmLibrarySelection() {
        let continuation = pendingOnboardingContinuation
        pendingOnboardingContinuation = nil
        pendingLibrarySelectionAccountIDs = []
        pendingPlexUserApplyToAccountIDs = []
        if continuation?.isFirstRun == true {
            apply(.accountAuthenticatedNeedsProfile)
        } else {
            apply(.accountAuthenticated)
            if continuation?.applyPlexIdentity == true {
                plexHomeUsers.ensurePlexIdentityForActiveProfile()
            }
        }
    }

    /// Handles the "Which Plex user are you?" pick. Binds the chosen Home user to
    /// the active profile, and on first run re-seeds the profile identity from
    /// that user (so the confirm screen shows *who's watching*, not the account
    /// owner). Then continues to the profile-setup sub-flow (first run) or the
    /// app, applying the binding so the Plex identity switches.
    public func selectPlexUserDuringOnboarding(_ user: PlexHomeUser?) {
        guard let pending = plexHomeUsers.pendingPlexUserSelection else { return }
        if let user {
            let binding = PlexHomeUserBinding(
                homeUserID: user.id,
                name: user.name,
                avatarURL: user.avatarURL?.absoluteString,
                requiresPIN: user.requiresPIN
            )
            // Apply the chosen Home user to every newly-added Plex account in the
            // batch (they belong to the same Plex account and share Home users),
            // falling back to just the one that triggered the pick.
            let targets = pendingPlexUserApplyToAccountIDs.isEmpty
                ? [pending.accountID]
                : pendingPlexUserApplyToAccountIDs
            var updated = profilesModel.activeProfile
            for accountID in targets {
                updated = updated.settingHomeUserBinding(binding, forPlexAccount: accountID)
            }
            profilesModel.update(updated)
        }
        plexHomeUsers.clearUserSelection()
        // Continue to the "choose your libraries" step. First run seeds the
        // profile identity from the picked user; a later add applies the Plex
        // identity once the library step completes.
        beginLibrarySelection(
            isFirstRun: pending.isFirstRun,
            seedName: user?.name ?? "",
            seedAvatar: user?.avatarURL?.absoluteString,
            applyPlexIdentity: !pending.isFirstRun
        )
    }

    /// First-run "Set Up Profiles": turns on the profiles feature (making it
    /// visible in Settings + Apple-TV-user aware) and advances to the confirm
    /// screen so they can keep or edit the seeded profile.
    public func enableProfilesForFirstRun() {
        profilesModel.enableProfiles()
        apply(.profilesEnabled)
    }

    /// First-run "Not Now — Just Me": keeps profiles hidden/disabled, marks
    /// first-run setup done, and continues to the one-time theme picker before
    /// the app.
    public func declineProfilesForFirstRun() {
        profilesModel.markFirstRunProfileSetupComplete()
        apply(.profilesDeclined)
    }

    /// Completes the one-time first-run profile confirm step and continues to the
    /// one-time theme picker. Marks the setup done so re-adding a server later
    /// never re-runs it.
    public func confirmFirstRunProfile() {
        profilesModel.markFirstRunProfileSetupComplete()
        apply(.profileConfirmed)
    }

    /// Completes the one-time first-run theme picker and enters the app. Applying
    /// any Plex Home-user binding (which can raise a PIN prompt) is deferred to
    /// here so it surfaces as the user actually enters the app — not over the
    /// theme screen.
    public func finishThemeSelection() {
        apply(.themeSelected)
        plexHomeUsers.ensurePlexIdentityForActiveProfile()
    }

    /// Dismisses the one-time theme picker shown after creating a profile in-app
    /// and applies the (now active) new profile's Plex identity — raising a PIN
    /// prompt if it maps to a protected Home user. Guarded so it's safe to call
    /// from both the Continue button and the cover's dismissal binding.
    public func finishNewProfileThemeSelection() {
        guard profileFlow.finishPickingThemeForNewProfile() else { return }
        plexHomeUsers.ensurePlexIdentityForActiveProfile()
    }

    /// Completes a Plex sign-in started from the provider chooser.
    ///
    /// The Plex PIN-link flow resolves the chosen server inside the provider
    /// picker. Keep that picker onscreen while the account and Home users resolve,
    /// then transition directly to the real next step; materialising the generic
    /// `.authenticating` page here produced two rapid full-page transitions.
    public func didAuthenticatePlex(_ session: UserSession) {
        didAuthenticate(session)
    }

    /// Persist a newly-configured local media share as an account. Builds a
    /// synthetic `MediaServer` (`smb://host[:port]/share`) + `UserSession` whose
    /// `accessToken` carries the SMB password (Keychain-backed like any other
    /// account) and runs it through the normal authenticated-account path, so a
    /// share joins the multi-account list and the library-selection step exactly
    /// like Plex/Jellyfin. There's no network round-trip — the share is validated
    /// lazily when its library is first scanned.
    public func didConfigureShare(
        host: String,
        port: Int?,
        share: String,
        username: String,
        password: String,
        displayName: String
    ) {
        let service = MediaShareAccountConfigurationService(
            accountStore: accountsProviders.accountStore
        )
        let prepared: PreparedMediaShareAccount
        do {
            prepared = try service.prepareSMB(
                host: host,
                port: port,
                share: share,
                username: username,
                password: password,
                displayName: displayName
            )
        } catch {
            apply(.authenticationFailed(.unknown("Invalid share address")))
            return
        }
        let isFirstRun =
            accountsProviders.accounts.isEmpty
            && !profilesModel.firstRunProfileSetupComplete
        apply(.serverSelected(prepared.session.server))
        do {
            try service.persist(prepared)
        } catch {
            Self.reportMediaSharePersistenceFailure(
                error,
                operation: "media-share-save"
            )
            apply(.authenticationFailed(.unknown("Couldn’t save this SMB share")))
            return
        }
        finalizeAddedAccount(
            session: prepared.session,
            account: prepared.account,
            previousAccount: prepared.previousAccount,
            isFirstRun: isFirstRun
        )
    }

    /// The stable identity for a media share, used as BOTH the `MediaServer.id`
    /// and (via `didAuthenticate`) the `Account.id`, so re-adding the same share
    /// — e.g. to update its password — updates the existing account in place
    /// instead of creating a duplicate.
    ///
    /// Identity = host + port + share + user, all case-folded, because SMB treats
    /// host, share, and username as case-insensitive. Folding to lowercase means
    /// `//NAS/Media` and `//nas/media`, and `COPILOT2` vs `Copilot2`, resolve to
    /// the same account (no accidental fork). The username IS part of the identity
    /// so genuinely different users on the SAME share (e.g. `brandon` and `sister`,
    /// who may see different files) can both be added as separate accounts. An
    /// empty username is a guest/anonymous share and folds to a stable `guest`
    /// identity. Only the identity is normalized; the display name and the
    /// connection `baseURL` keep the user's original casing (SMB ignores case on
    /// the wire).
    static func mediaShareServerID(
        host: String,
        port: Int?,
        share: String,
        username: String
    ) -> String {
        MediaShareAccountConfigurationService.smbID(
            host: host,
            port: port,
            share: share,
            username: username
        )
    }

    /// The credential a WebDAV share is being added with. Mirrors the vault's
    /// `MediaShareAuthentication` cases WebDAV permits, kept as a small onboarding
    /// input type so the UI (Phase 3) doesn't depend on FeatureAuth internals.
    public typealias WebDAVShareAuth = MediaShareWebDAVAuth

    /// Stable identity for a WebDAV share. Unlike SMB, WebDAV paths are
    /// case-sensitive and http vs https are genuinely different origins, so both
    /// the scheme and the exact-case path are part of the identity; the host is
    /// folded (DNS is case-insensitive) and the port is explicit. The principal
    /// distinguishes different users on the same URL.
    static func webDAVShareID(
        scheme: String,
        host: String,
        port: Int?,
        path: String,
        principal: String
    ) -> String {
        MediaShareAccountConfigurationService.webDAVID(
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            principal: principal
        )
    }

    /// Secret-safe persistence failure identity for device diagnostics. Never
    /// includes URLs, account ids, usernames, or credential values.
    static func mediaSharePersistenceDiagnostic(_ error: any Error) -> String {
        if let error = error as? AccountStoreError {
            return "AccountStoreError.\(error)"
        }
        if let error = error as? CredentialMutationJournalError {
            return "CredentialMutationJournalError.\(error)"
        }
        if let error = error as? MediaCredentialError {
            return "MediaCredentialError.\(error)"
        }
        if let error = error as? DurableLocalStateError {
            return "DurableLocalStateError.\(error)"
        }
        #if canImport(Security)
        if let error = error as? KeychainError {
            switch error {
            case .unexpectedStatus(let status):
                return "KeychainError.unexpectedStatus(\(status))"
            case .encodingFailed:
                return "KeychainError.encodingFailed"
            }
        }
        #endif
        return "Error.\(String(reflecting: type(of: error)))"
    }

    private static func reportMediaSharePersistenceFailure(
        _ error: any Error,
        operation: String
    ) {
        let diagnostic = mediaSharePersistenceDiagnostic(error)
        PlozzLog.auth.error(
            "Media-share persistence failed operation=\(operation) error=\(diagnostic)"
        )
        BrowseDiagnostics.emit(
            "mediaSharePersistenceFailed operation=\(operation) error=\(diagnostic)"
        )
    }

    /// Adds (or updates in place) a WebDAV media share. Persists through the
    /// credential-envelope path — NOT the SMB token path — because a single
    /// access-token string can't carry a bearer token plus a TLS leaf pin, and
    /// `AccountStore`'s legacy token path is SMB-only. The credential bytes live
    /// only in the vault; the account record stays secret-free.
    public func didConfigureWebDAVShare(
        baseURL: URL,
        auth: WebDAVShareAuth,
        trustPin: SHA256Fingerprint? = nil,
        displayName: String
    ) {
        if trustPin != nil, baseURL.scheme?.lowercased() != "https" {
            apply(.authenticationFailed(.unknown("A certificate pin requires HTTPS")))
            return
        }
        let service = MediaShareAccountConfigurationService(
            accountStore: accountsProviders.accountStore
        )
        let prepared: PreparedMediaShareAccount
        do {
            prepared = try service.prepareWebDAV(
                baseURL: baseURL,
                auth: auth,
                trustPin: trustPin,
                displayName: displayName
            )
        } catch is MediaShareAccountConfigurationError {
            apply(.authenticationFailed(.unknown("Invalid WebDAV address")))
            return
        } catch {
            apply(.authenticationFailed(.unknown("Invalid WebDAV credentials")))
            return
        }
        let isFirstRun = accountsProviders.accounts.isEmpty && !profilesModel.firstRunProfileSetupComplete
        apply(.serverSelected(prepared.session.server))
        do {
            try service.persist(prepared)
        } catch {
            Self.reportMediaSharePersistenceFailure(error, operation: "webdav-save")
            apply(.authenticationFailed(.unknown("Couldn’t save this WebDAV share")))
            return
        }
        finalizeAddedAccount(
            session: prepared.session,
            account: prepared.account,
            previousAccount: prepared.previousAccount,
            isFirstRun: isFirstRun
        )
    }

    // MARK: - NFS / SFTP / FTP media shares (unified onboarding)

    /// The default share name when the user leaves the nickname blank: the last
    /// meaningful path component (the folder/share they picked) with the transport
    /// label appended, e.g. "Media (SFTP)" or "appledemo (WebDAV)". Far more
    /// readable than the raw `host/path`, and the transport suffix disambiguates
    /// the same folder added over two protocols. Falls back to the host when the
    /// path is the root.
    static func defaultShareName(
        path: String,
        host: String,
        transport: MediaShareTransportKind
    ) -> String {
        MediaShareAccountConfigurationService.defaultShareName(
            path: path,
            host: host,
            transport: transport
        )
    }

    /// Stable identity for a filesystem media share whose paths are case-sensitive
    /// (NFS/SFTP/FTP run over POSIX servers, unlike SMB). Scheme, host (folded —
    /// DNS is case-insensitive), explicit port, exact-case path, and principal all
    /// participate so `sftp://h/a` and `sftp://h/b`, or two different users on one
    /// server, are distinct accounts, while re-adding the same share updates it in
    /// place. No default-port folding: NFS/SFTP/FTP have no http-style implicit
    /// default that changes the origin.
    static func mediaShareFilesystemID(
        scheme: String,
        host: String,
        port: Int?,
        path: String,
        principal: String
    ) -> String {
        MediaShareAccountConfigurationService.filesystemID(
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            principal: principal
        )
    }

    /// Adds (or updates in place) an NFS export as a media share. NFS is
    /// credential-free (`AUTH_UNIX`, no password), so the vault stores
    /// `.noCredentials`; the export path is the share root.
    public func didConfigureNFSShare(
        host: String,
        port: Int?,
        exportPath: String,
        displayName: String
    ) {
        let service = MediaShareAccountConfigurationService(
            accountStore: accountsProviders.accountStore
        )
        let prepared: PreparedMediaShareAccount
        do {
            prepared = try service.prepareNFS(
                host: host,
                port: port,
                exportPath: exportPath,
                displayName: displayName
            )
        } catch {
            apply(.authenticationFailed(.unknown("Invalid NFS address")))
            return
        }
        let isFirstRun =
            accountsProviders.accounts.isEmpty
            && !profilesModel.firstRunProfileSetupComplete
        apply(.serverSelected(prepared.session.server))
        do {
            try service.persist(prepared)
        } catch {
            Self.reportMediaSharePersistenceFailure(
                error,
                operation: "media-share-save"
            )
            apply(.authenticationFailed(.unknown("Couldn’t save this NFS share")))
            return
        }
        finalizeAddedAccount(
            session: prepared.session,
            account: prepared.account,
            previousAccount: prepared.previousAccount,
            isFirstRun: isFirstRun
        )
    }

    /// Adds (or updates in place) an SFTP media share. Password auth (SSH requires
    /// a username); the vault mandates a host-key pin, captured during onboarding
    /// and passed here.
    public func didConfigureSFTPShare(
        host: String,
        port: Int?,
        path: String,
        username: String,
        password: String,
        hostKeyPin: SHA256Fingerprint,
        displayName: String
    ) {
        let service = MediaShareAccountConfigurationService(
            accountStore: accountsProviders.accountStore
        )
        let prepared: PreparedMediaShareAccount
        do {
            prepared = try service.prepareSFTP(
                host: host,
                port: port,
                path: path,
                username: username,
                password: password,
                hostKeyPin: hostKeyPin,
                displayName: displayName
            )
        } catch {
            apply(.authenticationFailed(.unknown("Invalid SFTP address or credentials")))
            return
        }
        let isFirstRun =
            accountsProviders.accounts.isEmpty
            && !profilesModel.firstRunProfileSetupComplete
        apply(.serverSelected(prepared.session.server))
        do {
            try service.persist(prepared)
        } catch {
            Self.reportMediaSharePersistenceFailure(
                error,
                operation: "media-share-save"
            )
            apply(.authenticationFailed(.unknown("Couldn’t save this SFTP share")))
            return
        }
        finalizeAddedAccount(
            session: prepared.session,
            account: prepared.account,
            previousAccount: prepared.previousAccount,
            isFirstRun: isFirstRun
        )
    }

    /// How an FTP share authenticates, as the onboarding UI collects it. FTP is
    /// plaintext by nature (or implicit TLS via the `ftps` scheme); a TLS leaf pin
    /// is only meaningful over `ftps`.
    public enum FTPShareAuth: Equatable, Sendable {
        case anonymous
        case password(username: String, password: String)

        fileprivate var principal: String {
            switch self {
            case .anonymous: return "anon"
            case .password(let username, _):
                // POSIX usernames are case-sensitive, so distinct server users
                // (`Admin` vs `admin`) must stay distinct accounts — preserve
                // case, matching the WebDAV principal convention.
                let trimmed = username.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? "anon" : trimmed
            }
        }

        fileprivate var accountUserName: String {
            switch self {
            case .anonymous: return ""
            case .password(let username, _): return username.trimmingCharacters(in: .whitespaces)
            }
        }
    }

    /// Adds (or updates in place) an FTP/FTPS media share. `baseURL` carries the
    /// real scheme (`ftp` plaintext / `ftps` implicit TLS); a TLS pin requires
    /// `ftps`.
    public func didConfigureFTPShare(
        baseURL: URL,
        auth: FTPShareAuth,
        trustPin: SHA256Fingerprint? = nil,
        displayName: String
    ) {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "ftp" || scheme == "ftps",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            apply(.authenticationFailed(.unknown("Invalid FTP address")))
            return
        }
        if trustPin != nil, scheme != "ftps" {
            apply(.authenticationFailed(.unknown("A certificate pin requires FTPS")))
            return
        }
        let envelope: MediaShareCredentialEnvelope
        do {
            let authentication: MediaShareAuthentication
            switch auth {
            case .anonymous:
                authentication = .anonymous
            case let .password(username, password):
                authentication = .password(
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password
                )
            }
            let trust = MediaShareTrustMaterial(tlsLeafCertificateSHA256: trustPin)
            envelope = try MediaShareCredentialEnvelope(
                transport: .ftp,
                authentication: authentication,
                trust: trust
            )
        } catch {
            apply(.authenticationFailed(.unknown("Invalid FTP credentials")))
            return
        }
        let normalizedPath = Self.normalizedFilesystemPath(components.path)
        let serverID = Self.mediaShareFilesystemID(
            scheme: scheme,
            host: host,
            port: components.port,
            path: normalizedPath,
            principal: auth.principal
        )
        persistMediaShare(
            serverID: serverID,
            baseURL: baseURL,
            envelope: envelope,
            userID: auth.accountUserName.isEmpty ? "anon" : auth.accountUserName,
            userName: auth.accountUserName,
            defaultName: Self.defaultShareName(path: normalizedPath, host: host, transport: .ftp),
            displayName: displayName,
            invalidMessage: "Couldn’t save this FTP share"
        )
    }

    private static func normalizedFilesystemPath(_ raw: String) -> String {
        MediaShareAccountConfigurationService.normalizedFilesystemPath(raw)
    }

    /// Shared persistence tail for the credential-envelope transports (NFS/SFTP/
    /// FTP): build the `MediaServer`/`Account`, store the envelope in the vault,
    /// and run the common onboarding finalize — mirroring `didConfigureWebDAVShare`
    /// without repeating it per transport.
    private func persistMediaShare(
        serverID: String,
        baseURL: URL,
        envelope: MediaShareCredentialEnvelope,
        userID: String,
        userName: String,
        defaultName: String,
        displayName: String,
        invalidMessage: String
    ) {
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let name = trimmedName.isEmpty ? defaultName : trimmedName
        let server = MediaServer(
            id: serverID,
            name: name,
            baseURL: baseURL,
            provider: .mediaShare
        )
        let isFirstRun = accountsProviders.accounts.isEmpty && !profilesModel.firstRunProfileSetupComplete
        let session = UserSession(
            server: server,
            userID: userID,
            userName: userName,
            deviceID: accountsProviders.accountStore.deviceID(),
            accessToken: ""
        )
        let account = Account(id: server.id, from: session)
        let previousAccount = accountsProviders.accounts.first { $0.id == account.id }
        apply(.serverSelected(server))
        do {
            try accountsProviders.accountStore.addMediaShare(account, credential: envelope, generatedPrivateKey: nil)
        } catch {
            Self.reportMediaSharePersistenceFailure(
                error,
                operation: "media-share-save"
            )
            apply(.authenticationFailed(.unknown(invalidMessage)))
            return
        }
        finalizeAddedAccount(
            session: session,
            account: account,
            previousAccount: previousAccount,
            isFirstRun: isFirstRun
        )
    }

    /// Begins adding another account from inside the signed-in app.
    public func addAccount() {
        // A fresh add-account flow always starts at the provider chooser.
        pendingOnboardingProvider = nil
        apply(.addAccountRequested)
    }

    public func cancelAuthentication() {
        // Stepping back from Quick Connect keeps the provider so we land on that
        // provider's server list; any other cancel backs out to the chooser.
        let wasAuthenticating: Bool
        if case .onboarding(.authenticating, _) = state {
            wasAuthenticating = true
        } else {
            wasAuthenticating = false
        }
        apply(.cancelOnboarding)
        if !wasAuthenticating {
            pendingOnboardingProvider = nil
        }
        pendingLibrarySelectionAccountIDs = []
        pendingOnboardingContinuation = nil
        pendingPlexUserApplyToAccountIDs = []
    }

    /// Removes one account; drops to onboarding if it was the last.
    public func removeAccount(id: String) {
        let removedAccount = accountsProviders.accounts.first { $0.id == id }
        let shareAccountKey = mediaShare.accountService.mediaShareAccountKey(for: removedAccount)
        do {
            try accountsProviders.accountStore.remove(id: id)
        } catch {
            PlozzLog.auth.error("Account removal failed; account remains signed in")
        }
        accountsProviders.reloadAccounts()
        guard !accountsProviders.accounts.contains(where: { $0.id == id }) else {
            apply(.accountsChanged(accountsProviders.accounts))
            return
        }
        if let removedAccount {
            mediaShare.accountService.retireCredential(for: removedAccount)
        }
        if let shareAccountKey {
            mediaShare.scanStatus.removeShare(shareID: shareAccountKey)
            mediaShare.accountService.invalidate(shareAccountKey: shareAccountKey)
        }
        plexHomeUsers.forgetAccount(id)
        apply(.accountsChanged(accountsProviders.accounts))
    }

    /// Signs out of the primary active account (the one Settings currently shows).
    public func signOut() {
        if let account = accountsProviders.primaryActiveAccount {
            removeAccount(id: account.id)
        }
    }

    /// Removes every account (full reset).
    public func signOutAll() {
        let removedAccounts = accountsProviders.accounts
        let shareAccountKeys = mediaShare.accountService.mediaShareAccountKeys(in: removedAccounts)
        do {
            try accountsProviders.accountStore.clearAll()
        } catch {
            PlozzLog.auth.error("Sign out all was incomplete; retained accounts remain signed in")
        }
        accountsProviders.reloadAccounts()
        let retainedAccountIDs = Set(accountsProviders.accounts.map(\.id))
        let confirmedRemovedAccounts = removedAccounts.filter {
            !retainedAccountIDs.contains($0.id)
        }
        let confirmedShareAccountKeys = shareAccountKeys.filter {
            !retainedAccountIDs.contains($0)
        }
        confirmedRemovedAccounts.forEach(mediaShare.accountService.retireCredential)
        confirmedShareAccountKeys.forEach {
            mediaShare.scanStatus.removeShare(shareID: $0)
        }
        for accountKey in confirmedShareAccountKeys {
            mediaShare.accountService.invalidate(shareAccountKey: accountKey)
        }
        for account in confirmedRemovedAccounts {
            plexHomeUsers.forgetAccount(account.id)
        }
        apply(.accountsChanged(accountsProviders.accounts))
    }

    /// Debug-only: wipes everything that gates the first-run experience —
    /// accounts, profiles (collapsed to a single pristine default), the
    /// first-run flag, and the recent-servers list — so the next server add
    /// reproduces a genuine first run. Surfaced from a DEBUG-only Settings row.
    public func resetToFirstRunForDebugging() {
        let removedAccounts = accountsProviders.accounts
        let shareAccountKeys = mediaShare.accountService.mediaShareAccountKeys(in: removedAccounts)
        do {
            try accountsProviders.accountStore.clearAll()
        } catch {
            PlozzLog.auth.error("First-run reset could not remove every account")
        }
        accountsProviders.reloadAccounts()
        let retainedAccountIDs = Set(accountsProviders.accounts.map(\.id))
        let confirmedRemovedAccounts = removedAccounts.filter {
            !retainedAccountIDs.contains($0.id)
        }
        let confirmedShareAccountKeys = shareAccountKeys.filter {
            !retainedAccountIDs.contains($0)
        }
        confirmedRemovedAccounts.forEach(mediaShare.accountService.retireCredential)
        confirmedShareAccountKeys.forEach {
            mediaShare.scanStatus.removeShare(shareID: $0)
        }
        for accountKey in confirmedShareAccountKeys {
            mediaShare.accountService.invalidate(shareAccountKey: accountKey)
        }
        guard accountsProviders.accounts.isEmpty else {
            apply(.accountsChanged(accountsProviders.accounts))
            return
        }
        plexHomeUsers.resetAllForDebug()
        profilesModel.resetToPristineDefaultForDebugging()
        var recents = lastServerStore
        recents.recentServers = []
        pendingLibrarySelectionAccountIDs = []
        pendingOnboardingContinuation = nil
        pendingPlexUserApplyToAccountIDs = []
        profileFlow.dismissPicker()
        rebuildSettingsModels()
        apply(.accountsChanged(accountsProviders.accounts))
    }

    public func retry() {
        apply(.retry)
    }

    // MARK: Internals

    /// Rebuilds the settings models scoped to the active profile's
    /// namespace. Delegates to `profileSettings`; a no-op there when settings
    /// models were injected (tests).
    private func rebuildSettingsModels() {
        profileSettings.rebuild(namespace: profilesModel.activeNamespace)
    }

    /// Repoints Trakt (and its shared scrobbler) at the active profile's own
    /// connection so each household profile scrobbles to its own Trakt account.
    /// Also repoints Simkl, AniList, and MAL. Fire-and-forget: the status refresh
    /// is async and best-effort.
    private func updateTraktForActiveProfile() {
        let ns = profilesModel.activeNamespace
        trackerProfileGeneration &+= 1
        let generation = trackerProfileGeneration
        identityIndex.reset()
        Task {
            guard generation == trackerProfileGeneration else { return }
            await traktService.setActiveProfile(namespace: ns)
            guard generation == trackerProfileGeneration else { return }
            await simklService.setActiveProfile(namespace: ns)
            guard generation == trackerProfileGeneration else { return }
            await seerService.setActiveProfile(namespace: ns)
            guard generation == trackerProfileGeneration else { return }
            await anilistService.setActiveProfile(namespace: ns)
            guard generation == trackerProfileGeneration else { return }
            await malService.setActiveProfile(namespace: ns)
            guard generation == trackerProfileGeneration else { return }
            await lastfmService.setActiveProfile(namespace: ns)
        }
    }

    private func apply(_ event: SessionEvent) {
        machine.apply(event)
        state = machine.state
    }
}
