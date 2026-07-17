import Foundation
import Observation
import CoreModels
import CoreNetworking
import FeatureAuth
import FeatureDiscovery
import FeatureMusic
import FeatureProfiles
import MediaTransportCore
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
    /// Subtitle behaviour + appearance split out of the retired `CaptionSettings`.
    /// Behaviour (mode / language / auto-download) is the policy base input;
    /// appearance (`SubtitleStyle`) is the persisted look. Rebuilt on profile switch.
    public private(set) var subtitleBehaviorModel: SubtitleBehaviorModel
    public private(set) var subtitleStyleModel: SubtitleStyleModel
    public private(set) var spoilerModel: SpoilerSettingsModel
    public private(set) var playbackModel: PlaybackSettingsModel
    /// Per-profile per-content-type subtitle policy overrides (forced-only on
    /// movies, full subs on anime, …). The profile base mode/language lives in
    /// `subtitleBehaviorModel`; this only owns the overrides. Rebuilt on profile switch.
    public private(set) var subtitlePolicyModel: SubtitlePolicyModel
    /// Per-profile per-content-type audio-language overrides ("original audio for
    /// anime, device language for everything else"). The profile base preference
    /// lives in `playbackModel`; this only owns the overrides. Rebuilt on profile
    /// switch, mirroring `subtitlePolicyModel`.
    public private(set) var audioPolicyModel: AudioPolicyModel
    public private(set) var themeModel: ThemeSettingsModel
    /// Opt-in background theme music for movie and series detail pages.
    public private(set) var themeMusicModel: ThemeMusicSettingsModel
    public private(set) var diagnosticsModel: DiagnosticsSettingsModel
    /// The full-screen music player's per-profile look + "show extra info"
    /// preference. Scoped per profile (rebuilt on profile switch) like the theme.
    public private(set) var musicPlayerModel: MusicPlayerSettingsModel
    /// Which discovered libraries appear on the unified Home (opt-out). Shared
    /// live between the Settings checklist and Home so toggles take effect
    /// without a reload, and scoped per profile (rebuilt on profile switch) so
    /// each profile keeps its own Home customization.
    public private(set) var homeLibraryVisibilityModel: HomeLibraryVisibilityModel
    /// The active profile's UI density (Compact / Standard / Spacious / Extra
    /// Large). Scaled into `PlozzMetrics` and injected into the environment at the
    /// app root, and rebuilt on profile switch like the other per-profile models.
    public private(set) var uiDensityModel: UIDensitySettingsModel
    /// The active profile's media card style (framed glass cards vs borderless
    /// artwork-only "posters"). Injected into the environment at the app root like
    /// `uiDensityModel`, and rebuilt on profile switch like the other per-profile
    /// models.
    public private(set) var cardStyleModel: CardStyleSettingsModel
    /// The active profile's watch-status indicator (a "watched" check badge vs an
    /// "unwatched" corner flag on media cards). Injected into the environment at
    /// the app root like `cardStyleModel`, and rebuilt on profile switch like the
    /// other per-profile models.
    public private(set) var watchStatusIndicatorModel: WatchStatusIndicatorSettingsModel
    /// The active profile's navigation chrome (top bar vs. collapsible sidebar).
    /// Injected into the environment at the app root like `cardStyleModel`, and
    /// rebuilt on profile switch like the other per-profile models.
    public private(set) var navigationStyleModel: NavigationStyleSettingsModel
    /// The active profile's transparency (liquid-glass) preference. Injected into
    /// the environment at the app root like `cardStyleModel`, and rebuilt on
    /// profile switch. Its `.system` option still defers to the device
    /// Accessibility "Reduce Transparency" setting.
    public private(set) var transparencyModel: TransparencyPreferenceModel
    /// The active profile's Home hero (featured carousel) settings: which sources
    /// feed it, how many items, Random library scope, trailers, and auto-advance.
    /// Scoped per profile (rebuilt on profile switch) like `cardStyleModel`.
    public private(set) var heroSettingsModel: HeroSettingsModel
    /// The active profile's Night Shift (warm/dim screen tint) settings + live
    /// schedule. Scoped per profile (rebuilt on profile switch) like the theme;
    /// its overlay is installed at the app root in `RootView`.
    public private(set) var nightShiftModel: NightShiftSettingsModel

    /// Opt-in, off-by-default consent for sending anonymised crash reports.
    /// Deliberately **app-wide** (created once, never rebuilt per profile) and
    /// stored under an un-namespaced key — crash reporting is a device/app-level
    /// choice, not a per-profile persona. See `CrashReportingSettings`.
    public let crashReportingModel = CrashReportingSettingsModel()

    /// Live status of media-share background scans/enrichment, so Home can show an
    /// "Updating library…" banner and Settings can show last-scanned / Scan now.
    /// App-wide (a share and its scan are household-global, not per-profile). Its
    /// reporter is wired into the share catalog registry in `configureShareScanReporting()`.
    public let shareScanStatusModel = ShareScanStatusModel()

    /// The household's profiles + active selection. Owned at the app level and
    /// layered on top of the multi-account core.
    public let profilesModel: ProfilesModel

    /// The app-scoped audio playback engine. Created **once** and shared across
    /// profile switches so there's only ever a single `AVQueuePlayer` — otherwise
    /// switching profiles (which rebuilds the tab subtree) would spin up a second
    /// controller and leave the previous profile's track audibly playing. Stopped
    /// on profile switch so a new profile starts silent.
    public let audioController = AudioPlaybackController()
    /// When `true`, `RootView` shows the profile picker instead of the signed-in
    /// UI (shown at launch with >1 profile, and from "Switch Profile").
    public private(set) var isChoosingProfile = false
    /// Whether the current profile picker can be dismissed without choosing.
    /// `false` for the mandatory launch picker (Back / Cancel must not bail out
    /// of it), `true` when opened from Settings → "Switch Profile" over an
    /// already-active profile.
    public private(set) var isProfileSelectionCancelable = false

    /// When `true`, `RootView` presents the one-time theme picker (as a
    /// full-screen cover) for a profile just created in-app. Set right after
    /// Settings → "Add Profile" switches to the new profile; cleared by
    /// `finishNewProfileThemeSelection()`.
    public private(set) var isPickingThemeForNewProfile = false

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

    /// Context for the "Which Plex user are you?" onboarding step.
    public struct PendingPlexUserSelection: Equatable, Sendable {
        public let accountID: String
        public let serverName: String
        public let users: [PlexHomeUser]
        /// Whether this selection is happening during a brand-new-install first
        /// run (drives whether we continue to profile-setup or the app).
        public let isFirstRun: Bool
    }

    @MainActor
    private final class AppAuthenticatedHTTPResourceResolver: AuthenticatedHTTPResourceResolving {
        struct Context {
            let provider: ProviderKind
            let accountID: String
            let credentialRevision: CredentialRevision
            let baseURL: URL
            let token: String
        }

        typealias ContextProvider = @MainActor @Sendable (
            AuthenticatedHTTPPlaybackLocator
        ) throws -> Context

        private var contextProvider: ContextProvider?

        func configure(contextProvider: @escaping ContextProvider) {
            self.contextProvider = contextProvider
        }

        func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
            guard let contextProvider else {
                throw MediaTransportError.unsupportedCapability(
                    "authenticated HTTP resolver"
                )
            }
            let context = try contextProvider(locator)
            guard context.provider == locator.provider,
                  context.accountID == locator.accountID,
                  context.credentialRevision == locator.credentialRevision,
                  var components = URLComponents(
                      url: context.baseURL,
                      resolvingAgainstBaseURL: false
                  ) else {
                throw MediaTransportError.authentication(
                    reason: "authenticated HTTP identity mismatch"
                )
            }

            let encodedPath = locator.resource.path
            switch locator.resource.pathBase {
            case .configuredBaseURL:
                let basePath = components.percentEncodedPath.hasSuffix("/")
                    ? String(components.percentEncodedPath.dropLast())
                    : components.percentEncodedPath
                components.percentEncodedPath = basePath + "/" + encodedPath
            case .serverRoot:
                components.percentEncodedPath = encodedPath
            }

            var queryItems = locator.resource.queryItems.map {
                URLQueryItem(name: $0.name, value: $0.value)
            }
            switch locator.provider {
            case .jellyfin, .emby:
                queryItems.append(URLQueryItem(name: "api_key", value: context.token))
                if let playSessionID = locator.playSessionID {
                    queryItems.append(
                        URLQueryItem(name: "playSessionId", value: playSessionID)
                    )
                }
            case .plex:
                queryItems.append(URLQueryItem(name: "X-Plex-Token", value: context.token))
                if let playSessionID = locator.playSessionID {
                    queryItems.append(URLQueryItem(name: "session", value: playSessionID))
                    queryItems.append(
                        URLQueryItem(
                            name: "X-Plex-Session-Identifier",
                            value: playSessionID
                        )
                    )
                }
            case .mediaShare:
                throw MediaTransportError.invalidInput(
                    reason: "media shares cannot resolve authenticated HTTP resources"
                )
            }
            components.queryItems = queryItems
            guard let url = components.url else {
                throw MediaTransportError.invalidInput(
                    reason: "invalid authenticated HTTP resource"
                )
            }
            return url
        }
    }

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
                    return self?.provider(forAccountID: accountID)
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
                await MainActor.run { self?.homeAccounts.map(\.account.id) ?? [] }
            },
            indexedSeriesSources: { [identitySnapshotStore] originSeries in
                identitySnapshotStore.current.sources(for: originSeries).filter { $0.kind == .series }
            },
            indexedSources: { [identitySnapshotStore] identities, kind, anchorTitle, anchorYear in
                identitySnapshotStore.current.sources(
                    forIdentities: identities,
                    kind: kind,
                    anchorTitle: anchorTitle,
                    anchorYear: anchorYear
                )
            },
            indexedAccountIDs: { [identitySnapshotStore] in
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
        FanoutDiagnostics.emit(FanoutDiagnostics.indexStateLine(identitySnapshotStore.current, phase: "stop-index"))
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

    /// The eager `identity → sources` index built at sign-in / sync. The single
    /// shared store every surface reads (Home/Browse/Search merge, the detail
    /// server-picker, and the watch fan-out) so a title's cross-server/cross-account
    /// set is identical regardless of entry path. Profile-scoped: rebuilt when the
    /// active profile changes so one profile's catalogue never leaks into another.
    @ObservationIgnored
    private var _identityIndex = IdentityIndex()

    /// Profile-scoped disk store for the index membership, so cross-server unions
    /// survive relaunch and are known at t=0 (the cold-boot convergence fix). Built
    /// lazily for the active namespace; dropped on profile switch.
    @ObservationIgnored
    private var _identityIndexStore: (any IdentityIndexStoring)?
    private var identityIndexStore: any IdentityIndexStoring {
        if let store = _identityIndexStore { return store }
        let store = FileIdentityIndexStore(namespace: profilesModel.activeNamespace)
        _identityIndexStore = store
        return store
    }

    /// Whether the persisted membership has been reloaded yet this launch / profile.
    /// Restore runs exactly once so a later warm never re-seeds stale disk data over
    /// fresher live scans.
    @ObservationIgnored
    private var didRestorePersistedIndex = false

    /// In-flight warming task, cancelled and replaced when the active accounts /
    /// profile change so a stale scan can't clobber a newer one.
    @ObservationIgnored
    private var identityWarmTask: Task<Void, Never>?

    /// App-lifetime main-thread responsiveness probe (dev-only; nil unless
    /// `PLZXMEM=1`). Held so it lives as long as the app state.
    @ObservationIgnored
    private var perfHitchProbeTask: Task<Void, Never>?

    /// Monotonically bumped every time the identity index is swapped out from under
    /// an in-flight warm — on a profile reset and at the start of each warm wave
    /// (which cancels its predecessor). A warm task captures the value at launch and
    /// stamps every snapshot publish with it; a publish whose generation no longer
    /// matches is dropped, so a task that slips past its cooperative cancellation
    /// check can never republish a superseded (or another profile's) snapshot over
    /// the live one. See ``publishWarmedSnapshot(_:generation:)``.
    @ObservationIgnored
    private var identityWarmGeneration = 0

    /// High-water mark of `indexedAccountIDs.count` published within the current
    /// warm generation. The index only grows as accounts finish within a wave, so a
    /// snapshot carrying fewer accounts than one already published is a stale,
    /// out-of-order fold from a concurrent warm task; rejecting it stops a smaller
    /// snapshot clobbering a fuller one (last-writer-wins). Reset to 0 whenever the
    /// generation bumps so a legitimately smaller set (accounts removed) still
    /// publishes on the next wave.
    @ObservationIgnored
    private var publishedIndexAccountCount = 0

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
    /// Per-library ceiling on how many items a single warm pass indexes. Sized
    /// far above any realistic personal library so it's effectively "all of it".
    ///
    /// KNOWN EDGE (r6-10k-cap-complete, documented/deferred): if a library really
    /// does exceed this, the account is still marked rebuilt for the wave, so a
    /// twin living past the 10k boundary in one server's ordering may not get
    /// indexed and could miss its cross-server merge until a future full re-warm
    /// happens to reach it. Closing this fully would need cursor persistence
    /// (resume the scan past the cap across warms). Left as-is: 10k per library is
    /// enormous for a home media server, so the miss window is negligible in
    /// practice and not worth the added state.
    private let identityMaxItemsPerLibrary = 10_000

    /// Caps how many accounts are indexed concurrently during a warm. Without a
    /// cap a many-server library fans out one full library scan per account at
    /// once, swamping launch-time network/decoding — the per-library fan-out
    /// inside `indexAccount` is bounded, but the per-account group was not. Sized
    /// to a typical multi-server household (mirrors `HomeAggregator`'s account
    /// fan-out) so the common case still runs in a single wave.
    private let identityWarmFanoutLimit = 5

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
        let store = identityIndexStore
        let fanoutLimit = identityWarmFanoutLimit

        identityWarmTask?.cancel()
        // Supersede any still-in-flight warm from a previous wave: bump the
        // generation (and reset the per-wave high-water mark) so a stale publish
        // that slips past its cancellation check is dropped, while a legitimately
        // smaller account set for THIS wave (e.g. a server was removed) still
        // publishes.
        identityWarmGeneration &+= 1
        publishedIndexAccountCount = 0
        let warmGeneration = identityWarmGeneration
        identityWarmTask = Task { [weak self] in
            // B2: On the first warm this launch, seed the index from the persisted
            // membership and publish immediately, so cross-server unions are known
            // at t=0 — the first post-boot stop fans out to every server instead of
            // origin-only while the live scan below refreshes things. Pruned to the
            // active accounts inside `restore` (B3) so a removed server / switched
            // profile is never resurrected.
            var publishedInRestore = false
            if let self, await self.consumePendingRestore() {
                let persisted = store.load()
                if !persisted.isEmpty, await index.restore(from: persisted, retaining: activeIDs) {
                    let snapshot = await index.snapshot()
                    publishedInRestore = await MainActor.run { () -> Bool in
                        guard self.publishWarmedSnapshot(snapshot, generation: warmGeneration) else { return false }
                        // Tell already-loaded surfaces (Home) that cross-server
                        // membership is now known so they re-fold the fuller source
                        // set into their in-place cards. Without this, a boot whose
                        // live warm surfaces no NEW membership (everything already in
                        // the persisted snapshot) would leave Home on its pre-restore
                        // origin-only sources for the whole session — play-time
                        // locality selection then had no local twin to route to.
                        NotificationCenter.default.post(name: .identityIndexDidUpdate, object: nil)
                        self.drainWatchOutbox()
                        return true
                    }
                    FanoutDiagnostics.emit(FanoutDiagnostics.indexStateLine(snapshot, phase: "restore"))
                }
            }
            await index.retainAccounts(activeIDs)
            // r6-retain-publish: if the restore path didn't publish this wave,
            // publish the just-pruned snapshot now so a removed server's sources stop
            // appearing immediately — even when NO account needs a (re)scan (the
            // remaining accounts are warm & fresh, so `accountsToWarm` is empty and
            // the warm loop below would otherwise never publish the pruned set).
            if !publishedInRestore, let self {
                let snapshot = await index.snapshot()
                await MainActor.run {
                    guard self.publishWarmedSnapshot(snapshot, generation: warmGeneration) else { return }
                    NotificationCenter.default.post(name: .identityIndexDidUpdate, object: nil)
                    self.drainWatchOutbox()
                }
            }
            let stale = await index.staleAccounts(olderThan: ttl)

            // Select the accounts that actually need a (re)scan: warm & fresh ones
            // are skipped unless `force`. Resolved up front so the concurrent warm
            // below only spawns real work.
            var accountsToWarm: [ResolvedAccount] = []
            for resolvedAccount in resolved {
                if Task.isCancelled { break }
                let warm = await index.isWarm(resolvedAccount.account.id)
                if warm && !force && !stale.contains(resolvedAccount.account.id) { continue }
                accountsToWarm.append(resolvedAccount)
            }

            // Warm accounts CONCURRENTLY but BOUNDED. Cold-boot warm time used to be
            // the *sum* of each server's scan (a sequential loop), which is the
            // visible "takes a while to warm up on first boot" cost. The identity
            // index is an `actor` keyed by accountID, so concurrent per-account
            // begin/ingest/finish never race. We cap the per-account fan-out (a
            // sliding window) so a many-server library can't launch one full library
            // scan per account at once and swamp the network/decoding pipeline — the
            // window keeps the common household case running in a single wave while
            // bounding pathological (many-server) cases. Each account still
            // publishes its snapshot, persists, and re-drains the outbox the moment
            // IT finishes, so surfaces and fan-out see progress incrementally.
            if !accountsToWarm.isEmpty {
                let warmOne: @Sendable (ResolvedAccount) async -> Void = { resolvedAccount in
                    let accountID = resolvedAccount.account.id
                    if Task.isCancelled { return }
                    await Self.indexAccount(
                        resolvedAccount,
                        into: index,
                        serverInfo: serverInfo[accountID],
                        chunkSize: chunkSize,
                        maxPerLibrary: maxPerLibrary
                    )
                    if Task.isCancelled { return }
                    // Publish progressively so surfaces see each warmed account.
                    let snapshot = await index.snapshot()
                    await MainActor.run {
                        guard let self, self.publishWarmedSnapshot(snapshot, generation: warmGeneration) else { return }
                        // Tell already-loaded surfaces (Home) that the shared
                        // cross-server membership just grew, so they can re-fold
                        // the fuller source set into their in-place cards without
                        // a refetch. Cheap and idempotent: a surface whose rows
                        // gained no new sources no-ops on the re-merge.
                        NotificationCenter.default.post(name: .identityIndexDidUpdate, object: nil)
                        // Re-drain the watch outbox now that another account is
                        // indexed: a movie / series mutation stopped before the
                        // index finished warming re-expands against the larger
                        // union and fans out to the newly-known servers. No-op
                        // when the outbox is empty.
                        self.drainWatchOutbox()
                    }
                    // Make warm progress visible: each publish shows how many
                    // identities and cross-server unions the index now holds.
                    // crossServer staying 0 as accounts warm is the H1 signal
                    // (no union ⇒ nothing fans out).
                    FanoutDiagnostics.emit(FanoutDiagnostics.indexStateLine(snapshot, phase: "warm"))
                }

                let window = max(1, min(fanoutLimit, accountsToWarm.count))
                await withTaskGroup(of: Void.self) { group in
                    var next = 0
                    for _ in 0..<window {
                        let account = accountsToWarm[next]
                        next += 1
                        group.addTask { await warmOne(account) }
                    }
                    while await group.next() != nil {
                        guard next < accountsToWarm.count else { continue }
                        let account = accountsToWarm[next]
                        next += 1
                        group.addTask { await warmOne(account) }
                    }
                }
                // B1: persist the freshly-warmed membership so the next cold boot can
                // seed it at t=0. Done ONCE after the whole wave rather than after
                // each account: `export()` serializes the entire warm index every
                // time, so a per-account save is O(accounts²) redundant full-JSON
                // writes for a many-server library. Only warm accounts are exported,
                // so a half-scan is never frozen as authoritative; skipped on cancel
                // (a superseding wave will persist its own result).
                if !Task.isCancelled {
                    let persisted = await index.export()
                    try? store.save(persisted)
                }
            }
        }
    }

    /// Returns `true` exactly once per launch / profile so the persisted-index
    /// restore runs a single time even though `warmIdentityIndex` is invoked on
    /// every account-set change.
    @MainActor
    private func consumePendingRestore() -> Bool {
        guard !didRestorePersistedIndex else { return false }
        didRestorePersistedIndex = true
        return true
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

        // `libraries()` forced the connection resolver to probe and settle, so the
        // provider now reports its truly-reachable locality. Refresh the captured
        // serverInfo before it's ingested/persisted: it was sampled at warm-start
        // (before any request), when a Plex provider still reports its first
        // *advertised* connection — a server advertises its own LAN address even to
        // remote clients, so the pre-probe value can wrongly read `.local` and get
        // frozen into the persisted index. Sampling it post-probe keeps the stored
        // local/remote classification honest for the server picker's default.
        let liveServerInfo = serverInfo.map { info -> SourceServerInfo in
            var copy = info
            copy.locality = provider.connectionLocality
            return copy
        }

        // A cancelled warm (account set changed / profile switch) must not begin a
        // rebuild that empties this account's bucket only to abandon it — and must
        // not ingest a further page into a bucket the retain/rebuild logic may have
        // just reset for a removed account, which would resurrect it. The group
        // children are cancelled when `identityWarmTask.cancel()` fires; check right
        // before the mutating index calls (there are awaits above that can suspend
        // long enough for cancellation to land).
        if Task.isCancelled { return }
        await index.beginRebuild(for: accountID)
        // `true` if any page needed an enrichment fetch that failed **or** a
        // catalogue page fetch itself failed, so we leave the account un-finished
        // (cold) and a later warm retries it — the index grows toward completeness
        // and never drops a server permanently, and a transient network blip is
        // never frozen as a "complete" (but truncated) scan until the TTL.
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
                ) else {
                    // A page fetch threw (network / server error), not a clean end
                    // of catalogue. Mark the scan inconclusive so this library —
                    // and thus the account — is re-warmed rather than finished as
                    // complete while only partially indexed (which would silently
                    // drop that server's memberships from merges until the TTL).
                    inconclusive = true
                    break
                }
                if page.items.isEmpty { break }
                // Enrich any guid-less movie/series (e.g. a Plex series whose list
                // response omitted its Guid array) via its fuller per-item record,
                // so the store is keyed on real strong ids — origin-agnostic and
                // complete with Plex as a destination, not just a source.
                let prepared = await IdentityEnrichment.prepare(page.items) { item in
                    try? await provider.item(id: item.id)
                }
                inconclusive = inconclusive || prepared.inconclusive
                // Re-check just before the ingest: `provider.items` and the
                // per-item enrichment above are awaits during which the warm may
                // have been cancelled (account removed). Ingesting here would write
                // into a bucket a concurrent retain/rebuild already cleared.
                if Task.isCancelled { return }
                await index.ingest(prepared.indexable, accountID: accountID, serverInfo: liveServerInfo)
                offset += page.items.count
                // Only trust `totalCount` as an end-of-catalogue signal when the
                // provider actually reports one (> 0). A provider that returns a
                // full page of items but `totalCount == 0` (unknown/omitted) would
                // otherwise truncate the scan after the first page; rely on the
                // empty-page break above to terminate in that case.
                if page.totalCount > 0 && offset >= page.totalCount { break }
            }
        }
        // Only mark conclusively built when every guid-less item was resolved; an
        // inconclusive scan stays cold so the next warm retries it (never warm-and-
        // forget with a missing Plex copy).
        if !inconclusive {
            await index.finishRebuild(for: accountID)
        }
    }

    /// Publishes a warmed identity snapshot to the observed property + the
    /// `@Sendable` store, but only when it is safe to do so. Returns whether the
    /// publish was applied (callers gate the "membership grew" notification + outbox
    /// re-drain on it).
    ///
    /// Rejected when:
    ///  - `generation` no longer matches the live warm generation — the index was
    ///    swapped out (profile reset) or a newer warm wave started, so this snapshot
    ///    is from a superseded / different-profile index and must not overwrite the
    ///    current one.
    ///  - the snapshot carries fewer indexed accounts than one already published in
    ///    this generation — within a wave the index only grows, so a smaller set is a
    ///    stale, out-of-order fold from a concurrent warm task racing a fuller one.
    @MainActor
    private func publishWarmedSnapshot(_ snapshot: IdentityIndexSnapshot, generation: Int) -> Bool {
        guard generation == identityWarmGeneration else { return false }
        let accountCount = snapshot.indexedAccountIDs.count
        guard accountCount >= publishedIndexAccountCount else { return false }
        publishedIndexAccountCount = accountCount
        identitySnapshot = snapshot
        identitySnapshotStore.update(snapshot)
        return true
    }

    /// Flushes the identity index when the active profile changes so the next warm
    /// rebuilds it for the now-active profile's accounts.
    private func resetIdentityIndex() {
        identityWarmTask?.cancel()
        identityWarmTask = nil
        // Supersede any in-flight warm publish so a task mid-`snapshot()` from the
        // OLD profile's index can't overwrite the freshly-emptied snapshot once the
        // new profile takes over.
        identityWarmGeneration &+= 1
        publishedIndexAccountCount = 0
        _identityIndex = IdentityIndex()
        _identityIndexStore = nil
        didRestorePersistedIndex = false
        identitySnapshot = .empty
        identitySnapshotStore.update(.empty)
    }

    private var machine = SessionStateMachine()
    private let accountStore: AccountPersisting
    private let registry: ProviderRegistry
    public let authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
    /// The one atomic media-share runtime generation (coordinator + transport
    /// composition + network-file resolver). AppState forwards every media-share
    /// concern to it rather than storing the pieces independently.
    private let mediaShareRuntime: any MediaShareRuntime
    /// Media-share account lifecycle policy (retire/invalidate) routed through
    /// the same runtime generation.
    private let mediaShareAccountService: MediaShareAccountService

    /// The network-file resolver used for direct-file share playback. Forwards
    /// to the runtime so there is a single owner of the resolver instance.
    public var networkFileResolver: any MediaTransportNetworkFileResolving {
        mediaShareRuntime.networkFileResolver
    }
    private var sharePriorityRevision: UInt64 = 0
    private let durableLocalStateStore: DurableLocalStateStore?
    /// Optional tvOS system-user seam (default app-owned no-op). See
    /// `SystemProfileBridging`.
    private let systemBridge: SystemProfileBridging
    /// True when settings models were injected by the caller (tests) and so must
    /// not be rebuilt on profile switch.
    private let usesInjectedModels: Bool

    /// In-memory Plex auth-token overrides keyed by `Account.id`. Set when the
    /// active profile maps to a non-owner Plex Home user so providers resolve as
    /// that user. **PIN-protected** users are never persisted — their token must
    /// not survive relaunch, so Plozz re-prompts each launch. **Unprotected**
    /// users are seeded synchronously from `plexHomeUserTokenCache` (see below)
    /// so their identity paints instantly without the startup double-load.
    private var plexTokenOverrides: [String: String] = [:]
    /// Runtime revision for the effective Plex Home-user credential. Owner
    /// credentials continue to use the account's persisted revision.
    private var plexOverrideCredentialRevisions: [String: CredentialRevision] = [:]

    /// For each account, the Plex Home-user UUID the current override resolves to.
    /// Lets the reconciler tell an already-satisfied protected switch apart from a
    /// stale override left by a previous profile, so a just-entered PIN isn't
    /// re-armed into an infinite prompt/re-prompt loop.
    private var plexResolvedHomeUser: [String: String] = [:]

    /// Keychain-backed cache of resolved server tokens for **unprotected** Plex
    /// Home users. Lets `ensurePlexIdentityForActiveProfile` install the right
    /// identity synchronously at launch/profile-pick (instant, ungated paint),
    /// then refresh it in the background. PIN-protected users are never cached.
    @ObservationIgnored
    private let plexHomeUserTokenCache: PlexHomeUserTokenCache

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
    ///
    /// Why this exists: `switchHomeUser` returns the Home user's *account-level*
    /// plex.tv token, **not** a per-server token. A PMS authorizes browsing with
    /// the user's *server* access token (the same kind the owner account was
    /// built from at sign-in). Sending the bare account token can yield an
    /// unauthorized/empty `/library/sections`, so a switched Home user sees no
    /// libraries. Re-resolving the per-server token here mirrors how every owner
    /// account is built and works for any switched user / any number of accounts.
    @ObservationIgnored
    var plexServerTokenResolve: @Sendable (_ serverID: String, _ userToken: String, _ deviceID: String) async -> String? = { serverID, userToken, deviceID in
        let client = PlexAuthClient(deviceProfile: PlexDeviceProfile(clientIdentifier: deviceID))
        let servers = try? await client.servers(authToken: userToken)
        return servers?.first { $0.id == serverID }?.accessToken
    }

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
        self.accountStore = resolvedAccountStore
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
            ?? DefaultMediaShareRuntime.make(accountStore: resolvedAccountStore)
        self.mediaShareRuntime = resolvedRuntime
        self.mediaShareAccountService = MediaShareAccountService(runtime: resolvedRuntime)
        let defaultAuthenticatedHTTPResolver: AppAuthenticatedHTTPResourceResolver?
        if let authenticatedHTTPResolver {
            self.authenticatedHTTPResolver = authenticatedHTTPResolver
            defaultAuthenticatedHTTPResolver = nil
        } else {
            let resolver = AppAuthenticatedHTTPResourceResolver()
            self.authenticatedHTTPResolver = resolver
            defaultAuthenticatedHTTPResolver = resolver
        }
        self.registry = registry ?? Self.makeDefaultRegistry(
            runtime: resolvedRuntime,
            durableLocalStateStore: resolvedDurableLocalStateStore
        )
        self.profilesModel = profilesModel ?? Self.makeDefaultProfilesModel()
        self.systemBridge = systemBridge ?? Self.makeDefaultSystemBridge()
        self.ratingsProvider = ratingsProvider ?? RatingsServiceFactory.make()
        self.plexHomeUserTokenCache = .makeDefault()

        // If the caller supplied any settings model, treat them all as injected
        // (test path) and don't rebuild them on profile switch. Otherwise build
        // them scoped to the active profile's namespace.
        let injected = spoilerModel != nil
            || subtitleBehaviorModel != nil || subtitleStyleModel != nil
            || playbackModel != nil
            || themeModel != nil || themeMusicModel != nil || diagnosticsModel != nil
            || homeLibraryVisibilityModel != nil || musicPlayerModel != nil
            || uiDensityModel != nil
            || cardStyleModel != nil
            || watchStatusIndicatorModel != nil
            || navigationStyleModel != nil
            || transparencyModel != nil
            || nightShiftModel != nil
        self.usesInjectedModels = injected
        let ns = (profilesModel ?? self.profilesModel).activeNamespace
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
        self.subtitleBehaviorModel = subtitleBehaviorModel ?? SubtitleBehaviorModel(store: SubtitleBehaviorStore(namespace: ns))
        self.subtitleStyleModel = subtitleStyleModel ?? SubtitleStyleModel(store: SubtitleStyleStore(namespace: ns))
        self.spoilerModel = spoilerModel ?? SpoilerSettingsModel(store: SpoilerSettingsStore(namespace: ns))
        self.playbackModel = playbackModel ?? PlaybackSettingsModel(store: PlaybackSettingsStore(namespace: ns))
        self.subtitlePolicyModel = SubtitlePolicyModel(store: SubtitlePolicyStore(namespace: ns))
        self.audioPolicyModel = AudioPolicyModel(store: AudioPolicyStore(namespace: ns))
        self.themeModel = themeModel ?? ThemeSettingsModel(store: ThemeSettingsStore(namespace: ns))
        self.themeMusicModel = themeMusicModel
            ?? ThemeMusicSettingsModel(store: ThemeMusicSettingsStore(namespace: ns))
        self.diagnosticsModel = diagnosticsModel ?? DiagnosticsSettingsModel(store: DiagnosticsSettingsStore(namespace: ns))
        self.musicPlayerModel = musicPlayerModel ?? MusicPlayerSettingsModel(store: MusicPlayerSettingsStore(namespace: ns))
        self.homeLibraryVisibilityModel = homeLibraryVisibilityModel
            ?? HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(namespace: ns))
        self.uiDensityModel = uiDensityModel
            ?? UIDensitySettingsModel(store: UIDensitySettingsStore(namespace: ns))
        self.cardStyleModel = cardStyleModel
            ?? CardStyleSettingsModel(store: CardStyleSettingsStore(namespace: ns))
        self.watchStatusIndicatorModel = watchStatusIndicatorModel
            ?? WatchStatusIndicatorSettingsModel(store: WatchStatusIndicatorSettingsStore(namespace: ns))
        self.navigationStyleModel = navigationStyleModel
            ?? NavigationStyleSettingsModel(store: NavigationStyleSettingsStore(namespace: ns))
        self.transparencyModel = transparencyModel
            ?? TransparencyPreferenceModel(store: TransparencyPreferenceStore(namespace: ns))
        self.heroSettingsModel = HeroSettingsModel(store: HeroSettingsStore(namespace: ns))
        self.nightShiftModel = nightShiftModel
            ?? NightShiftSettingsModel(store: NightShiftSettingsStore(namespace: ns))

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

        // Wire the media-share scan/enrich progress reporter into the app-owned
        // catalog coordinator, so the first share query (from Home) reports into
        // this model and the "Updating library…" banner + Settings last-scanned line
        // light up. The reporter is a Sendable value; capture it before the Task.
        let scanReporter = self.shareScanStatusModel.reporter()
        Task {
            await resolvedRuntime.configure(reporter: scanReporter)
        }
        defaultAuthenticatedHTTPResolver?.configure { [weak self] locator in
            guard let self,
                  let account = self.accountStore.loadAccounts().first(where: {
                      $0.id == locator.accountID
                  }),
                  account.server.provider == locator.provider,
                  self.effectiveCredentialRevision(for: account)
                    == locator.credentialRevision,
                  let token = self.resolvedToken(for: account.id),
                  !token.isEmpty else {
                throw MediaTransportError.authentication(
                    reason: "inactive authenticated HTTP identity"
                )
            }
            let baseURL: URL
            if account.server.provider == .plex {
                let provider = try self.registry.provider(
                    for: self.providerResolutionContext(for: account, token: token)
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
            return AppAuthenticatedHTTPResourceResolver.Context(
                provider: account.server.provider,
                accountID: account.id,
                credentialRevision: self.effectiveCredentialRevision(for: account),
                baseURL: baseURL,
                token: token
            )
        }
    }

    /// Force a fresh scan + enrichment of a media share now (Settings "Scan now").
    /// Builds the share's provider directly from its account (tolerating an empty
    /// token for a guest share, which `provider(forAccountID:)` would reject) and
    /// asks it to rescan — registering its catalog/scanner if needed, so this works
    /// even when Home never queried the share, and it drives the scan indicator.
    public func rescanShare(accountID: String) {
        guard let account = accounts.first(where: { $0.id == accountID }),
              account.server.provider == .mediaShare else { return }
        let token = resolvedToken(for: account.id) ?? ""
        guard let shareProvider = try? registry.provider(
            for: providerResolutionContext(for: account, token: token)
        ) as? ShareProvider else { return }
        Task { await shareProvider.rescan() }
    }

    private static func makeDefaultAccountStore() -> AccountPersisting {
        #if canImport(Security)
        let secureStore = KeychainStore()
        do {
            let localStateStore = try DurableLocalStateStoreFactory.userIndependent()
            return AccountStore(
                secureStore: secureStore,
                mediaCredentialVault: MediaCredentialVault(secureStore: secureStore),
                credentialJournal: try CredentialMutationJournal(store: localStateStore)
            )
        } catch {
            reportMediaSharePersistenceFailure(
                error,
                operation: "credential-infrastructure-init"
            )
            return AccountStore(secureStore: secureStore)
        }
        #else
        return AccountStore(secureStore: InMemorySecureStore())
        #endif
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
                hybridEngineEnabled: HybridPlayback.enabled
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
        do {
            try accountStore.recoverCredentialMutations()
        } catch {
            PlozzLog.auth.error("Credential recovery failed; incomplete shares remain hidden")
        }
        reloadAccounts()
        PlozzLog.boot("bootstrap accounts=\(accounts.count) activeIDs=\(activeAccountIDs.count)")
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
        // The launch picker is mandatory: Back / Cancel must not dismiss it.
        isProfileSelectionCancelable = false
        apply(.restored(accounts))
        // Honor a remembered/auto-landed profile's Plex Home-user mapping at
        // launch. When the picker is shown, the switch happens once the user
        // picks instead.
        if !isChoosingProfile {
            ensurePlexIdentityForActiveProfile()
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
        return try? registry.provider(for: providerResolutionContext(for: account, token: token))
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
                  let provider = try? registry.provider(
                      for: providerResolutionContext(for: account, token: token)
                  )
            else { return nil }
            return ResolvedAccount(account: account, provider: provider)
        }
    }

    /// Resolves specific account ids into `ResolvedAccount`s for the onboarding
    /// "choose your libraries" step (which fans a library-listing call out over
    /// the just-added accounts). Tokens are resolved on demand.
    public func resolvedAccounts(withIDs ids: [String]) -> [ResolvedAccount] {
        ids.compactMap { id in
            guard let account = accounts.first(where: { $0.id == id }),
                  let token = resolvedToken(for: id),
                  let provider = try? registry.provider(
                      for: providerResolutionContext(for: account, token: token)
                  )
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
              let provider = try? registry.provider(
                  for: providerResolutionContext(for: account, token: token)
              )
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
        return try? registry.provider(for: providerResolutionContext(for: account, token: token))
    }

    private func providerResolutionContext(
        for account: Account,
        token: String
    ) -> ProviderResolutionContext {
        let localMediaContext = account.server.provider == .mediaShare
            ? LocalMediaContext(
                accountID: account.id,
                profileID: profilesModel.activeProfileID,
                profileNamespace: profilesModel.activeNamespace
            )
            : nil
        return ProviderResolutionContext(
            session: account.session(token: token),
            accountID: account.id,
            credentialRevision: effectiveCredentialRevision(for: account),
            localMediaContext: localMediaContext
        )
    }

    private func effectiveCredentialRevision(for account: Account) -> CredentialRevision {
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
                        registry.invalidate(accountID: account.id)
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
                        registry.invalidate(accountID: account.id)
                        PlozzLog.boot("ensure.cachedOverride acct=\(account.id) home=\(binding.homeUserID) — instant paint")
                    } else {
                        PlozzLog.boot("ensure.unprotectedSwitch acct=\(account.id) home=\(binding.homeUserID) — cache miss, async")
                    }
                    // Refresh in the background to keep the cached token fresh.
                    // `performPlexSwitch` only bumps the identity generation when the
                    // resolved token actually changed, so a warm-cache refresh that
                    // returns the same token triggers no reload.
                    Task { await performPlexSwitch(accountID: account.id, homeUserID: binding.homeUserID, pin: nil) }
                }
            } else {
                if plexTokenOverrides[account.id] != nil {
                    setPlexTokenOverride(nil, for: account.id)
                    plexResolvedHomeUser[account.id] = nil
                    registry.invalidate(accountID: account.id)
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
                registry.invalidate(accountID: accountID)
            }
            plexIdentityGeneration += 1
            PlozzLog.boot("genBump=\(self.plexIdentityGeneration) site=clearPlexOverrides")
        }
    }

    /// Performs the Plex Home-user switch and installs the resulting token as the
    /// account's override, bumping the identity generation only when the resolved
    /// token actually changed (so a warm-cache refresh doesn't force a reload).
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
            // `token` is the Home user's account-level plex.tv token. Re-resolve
            // it to THIS server's access token (the kind PMS authorizes browsing
            // with), mirroring how the owner account was built at sign-in. Falls
            // back to the account token if the per-server lookup fails so the
            // switch never silently dead-ends. See `plexServerTokenResolve`.
            var resolvedToken = token
            var gotServerToken = false
            if let serverID = accounts.first(where: { $0.id == accountID })?.server.id,
               let serverToken = await plexServerTokenResolve(serverID, token, deviceID) {
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
                registry.invalidate(accountID: accountID)
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
        for account in accounts {
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
        let isFirstRun = accounts.isEmpty && !profilesModel.firstRunProfileSetupComplete
        // Media shares are identified by their share path (host/port/share), not a
        // random UUID, so re-adding the same share — e.g. to fix its password —
        // updates the existing account in place (new credential revision, old one
        // retired) instead of forking a duplicate account. Other providers keep a
        // freshly-minted UUID identity.
        let account = session.server.provider == .mediaShare
            ? Account(id: session.server.id, from: session)
            : Account(from: session)
        let previousAccount = accounts.first { $0.id == account.id }
        do {
            try accountStore.add(account, token: session.accessToken)
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
           let persisted = accountStore.loadAccounts().first(where: { $0.id == account.id }),
           previousAccount.credentialRevision != persisted.credentialRevision {
            mediaShareAccountService.retireCredential(for: previousAccount)
        }
        reloadAccounts()
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

        let isFirstRun = accounts.isEmpty && !profilesModel.firstRunProfileSetupComplete
        var addedIDs: [String] = []
        for session in sessions {
            let account = Account(from: session)
            let previousAccount = accounts.first { $0.id == account.id }
            do {
                try accountStore.add(account, token: session.accessToken)
                if let previousAccount,
                   previousAccount.credentialRevision != account.credentialRevision {
                    mediaShareAccountService.retireCredential(for: previousAccount)
                }
                addedIDs.append(account.id)
            } catch {
                continue // Skip a failed add; keep the rest of the batch.
            }
        }
        reloadAccounts()
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
                let users = await self.plexHomeUsers(forAccountID: accountID)
                if users.count >= 2 {
                    self.pendingPlexUserSelection = PendingPlexUserSelection(
                        accountID: accountID,
                        serverName: session.server.name,
                        users: users,
                        isFirstRun: isFirstRun
                    )
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
                ensurePlexIdentityForActiveProfile()
            }
        }
    }

    /// Handles the "Which Plex user are you?" pick. Binds the chosen Home user to
    /// the active profile, and on first run re-seeds the profile identity from
    /// that user (so the confirm screen shows *who's watching*, not the account
    /// owner). Then continues to the profile-setup sub-flow (first run) or the
    /// app, applying the binding so the Plex identity switches.
    public func selectPlexUserDuringOnboarding(_ user: PlexHomeUser?) {
        guard let pending = pendingPlexUserSelection else { return }
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
        pendingPlexUserSelection = nil
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
        ensurePlexIdentityForActiveProfile()
    }

    /// Dismisses the one-time theme picker shown after creating a profile in-app
    /// and applies the (now active) new profile's Plex identity — raising a PIN
    /// prompt if it maps to a protected Home user. Guarded so it's safe to call
    /// from both the Continue button and the cover's dismissal binding.
    public func finishNewProfileThemeSelection() {
        guard isPickingThemeForNewProfile else { return }
        isPickingThemeForNewProfile = false
        ensurePlexIdentityForActiveProfile()
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
        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = ShareProvider.bracketedHostIfIPv6(host)
        comps.port = port
        comps.path = "/" + share
        guard let baseURL = comps.url else {
            apply(.authenticationFailed(.unknown("Invalid share address")))
            return
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let name = trimmedName.isEmpty ? Self.defaultShareName(path: share, host: host, transport: .smb) : trimmedName
        let server = MediaServer(
            id: Self.mediaShareServerID(host: host, port: port, share: share, username: username),
            name: name,
            baseURL: baseURL,
            provider: .mediaShare
        )
        // A guest/anonymous share has no user identity; use "guest" as a stable
        // per-share user id so the account key is deterministic.
        let user = username.isEmpty ? "guest" : username
        let session = UserSession(
            server: server,
            userID: user,
            userName: username,
            deviceID: accountStore.deviceID(),
            accessToken: password
        )
        apply(.serverSelected(server))
        didAuthenticate(session)
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
        let portKey = port.map { ":\($0)" } ?? ""
        let normalizedUser = username.trimmingCharacters(in: .whitespaces).lowercased()
        let user = normalizedUser.isEmpty ? "guest" : normalizedUser
        return "share:\(host.lowercased())\(portKey)/\(share.lowercased())#\(user)"
    }

    /// The credential a WebDAV share is being added with. Mirrors the vault's
    /// `MediaShareAuthentication` cases WebDAV permits, kept as a small onboarding
    /// input type so the UI (Phase 3) doesn't depend on FeatureAuth internals.
    public enum WebDAVShareAuth: Equatable, Sendable {
        case anonymous
        case password(username: String, password: String)
        case bearer(token: String)

        /// Stable principal component of the account identity. Different users on
        /// one URL get separate accounts; anonymous and bearer each fold to a
        /// single principal (re-adding replaces in place — the "my token/password
        /// changed" flow), which is the common one-principal-per-server case.
        fileprivate var principal: String {
            switch self {
            case .anonymous: return "anon"
            case .password(let username, _):
                let trimmed = username.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? "anon" : trimmed
            case .bearer: return "bearer"
            }
        }

        fileprivate var accountUserName: String {
            switch self {
            case .anonymous, .bearer: return ""
            case .password(let username, _): return username.trimmingCharacters(in: .whitespaces)
            }
        }
    }

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
        let normalizedScheme = scheme.lowercased()
        // Canonicalize the port: an explicit default port (443/https, 80/http)
        // is the same origin as an implicit one, so drop it to dedup
        // `https://h/dav` and `https://h:443/dav` to one account.
        let defaultPort = normalizedScheme == "https" ? 443 : 80
        let portKey = (port == nil || port == defaultPort) ? "" : ":\(port!)"
        // Canonicalize a trailing slash (`/dav` == `/dav/`) so the same
        // collection isn't added twice; the transport endpoint drops it too.
        var normalizedPath = path.isEmpty ? "/" : path
        if normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        return "share:\(normalizedScheme)://\(host.lowercased())\(portKey)\(normalizedPath)#\(principal)"
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
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              // A base URL must never carry credentials-in-URL, a query, or a
              // fragment — those aren't part of a share root and are a smuggling
              // vector. Reject rather than silently strip.
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            apply(.authenticationFailed(.unknown("Invalid WebDAV address")))
            return
        }
        // A TLS leaf pin is only meaningful over HTTPS; refuse it on plaintext.
        if trustPin != nil, scheme != "https" {
            apply(.authenticationFailed(.unknown("A certificate pin requires HTTPS")))
            return
        }
        // Credentials over plain http are permitted for a LAN media share (the
        // onboarding UI warns); only a TLS pin requires https. No cleartext
        // rejection here.

        let path = components.percentEncodedPath
        let normalizedPath = path.isEmpty ? "/" : path
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
            case let .bearer(token):
                authentication = .bearer(token: token)
            }
            let trust = MediaShareTrustMaterial(tlsLeafCertificateSHA256: trustPin)
            envelope = try MediaShareCredentialEnvelope(
                transport: .webDAV,
                authentication: authentication,
                trust: trust
            )
        } catch {
            apply(.authenticationFailed(.unknown("Invalid WebDAV credentials")))
            return
        }

        let serverID = Self.webDAVShareID(
            scheme: scheme,
            host: host,
            port: components.port,
            path: normalizedPath,
            principal: auth.principal
        )
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let name = trimmedName.isEmpty ? Self.defaultShareName(path: normalizedPath, host: host, transport: .webDAV) : trimmedName
        let server = MediaServer(
            id: serverID,
            name: name,
            baseURL: baseURL,
            provider: .mediaShare
        )
        let isFirstRun = accounts.isEmpty && !profilesModel.firstRunProfileSetupComplete
        let userName = auth.accountUserName
        let session = UserSession(
            server: server,
            userID: auth.principal,
            userName: userName,
            deviceID: accountStore.deviceID(),
            // Credential bytes live in the vault envelope, not the token slot.
            accessToken: ""
        )
        let account = Account(id: server.id, from: session)
        let previousAccount = accounts.first { $0.id == account.id }
        apply(.serverSelected(server))
        do {
            try accountStore.addMediaShare(account, credential: envelope, generatedPrivateKey: nil)
        } catch {
            Self.reportMediaSharePersistenceFailure(error, operation: "webdav-save")
            apply(.authenticationFailed(.unknown("Couldn’t save this WebDAV share")))
            return
        }
        finalizeAddedAccount(
            session: session,
            account: account,
            previousAccount: previousAccount,
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
        let lastComponent = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
        let base = (lastComponent?.isEmpty == false) ? lastComponent! : host
        return "\(base) (\(transport.badgeLabel))"
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
        let normalizedScheme = scheme.lowercased()
        let portKey = port.map { ":\($0)" } ?? ""
        var normalizedPath = path.isEmpty ? "/" : path
        if normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        return "share:\(normalizedScheme)://\(host.lowercased())\(portKey)\(normalizedPath)#\(principal)"
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
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else {
            apply(.authenticationFailed(.unknown("Invalid NFS address")))
            return
        }
        var comps = URLComponents()
        comps.scheme = "nfs"
        comps.host = ShareProvider.bracketedHostIfIPv6(trimmedHost)
        comps.port = port
        let normalizedPath = Self.normalizedFilesystemPath(exportPath)
        comps.path = normalizedPath
        guard let baseURL = comps.url else {
            apply(.authenticationFailed(.unknown("Invalid NFS address")))
            return
        }
        let envelope: MediaShareCredentialEnvelope
        do {
            envelope = try MediaShareCredentialEnvelope(
                transport: .nfs,
                authentication: .noCredentials
            )
        } catch {
            apply(.authenticationFailed(.unknown("Invalid NFS share")))
            return
        }
        let serverID = Self.mediaShareFilesystemID(
            scheme: "nfs",
            host: trimmedHost,
            port: port,
            path: normalizedPath,
            principal: "anon"
        )
        persistMediaShare(
            serverID: serverID,
            baseURL: baseURL,
            envelope: envelope,
            userID: "anon",
            userName: "",
            defaultName: Self.defaultShareName(path: normalizedPath, host: trimmedHost, transport: .nfs),
            displayName: displayName,
            invalidMessage: "Couldn’t save this NFS share"
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
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty else {
            apply(.authenticationFailed(.unknown("SFTP needs a host and username")))
            return
        }
        var comps = URLComponents()
        comps.scheme = "sftp"
        comps.host = ShareProvider.bracketedHostIfIPv6(trimmedHost)
        comps.port = port
        let normalizedPath = Self.normalizedFilesystemPath(path)
        comps.path = normalizedPath
        guard let baseURL = comps.url else {
            apply(.authenticationFailed(.unknown("Invalid SFTP address")))
            return
        }
        let envelope: MediaShareCredentialEnvelope
        do {
            let trust = MediaShareTrustMaterial(sshHostKeySHA256: hostKeyPin)
            envelope = try MediaShareCredentialEnvelope(
                transport: .sftp,
                authentication: .password(username: trimmedUser, password: password),
                trust: trust
            )
        } catch {
            apply(.authenticationFailed(.unknown("Invalid SFTP credentials")))
            return
        }
        let serverID = Self.mediaShareFilesystemID(
            scheme: "sftp",
            host: trimmedHost,
            port: port,
            path: normalizedPath,
            principal: trimmedUser
        )
        persistMediaShare(
            serverID: serverID,
            baseURL: baseURL,
            envelope: envelope,
            userID: trimmedUser,
            userName: trimmedUser,
            defaultName: Self.defaultShareName(path: normalizedPath, host: trimmedHost, transport: .sftp),
            displayName: displayName,
            invalidMessage: "Couldn’t save this SFTP share"
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
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
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
        let isFirstRun = accounts.isEmpty && !profilesModel.firstRunProfileSetupComplete
        let session = UserSession(
            server: server,
            userID: userID,
            userName: userName,
            deviceID: accountStore.deviceID(),
            accessToken: ""
        )
        let account = Account(id: server.id, from: session)
        let previousAccount = accounts.first { $0.id == account.id }
        apply(.serverSelected(server))
        do {
            try accountStore.addMediaShare(account, credential: envelope, generatedPrivateKey: nil)
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
        let removedAccount = accounts.first { $0.id == id }
        let shareAccountKey = mediaShareAccountService.mediaShareAccountKey(for: removedAccount)
        do {
            try accountStore.remove(id: id)
        } catch {
            PlozzLog.auth.error("Account removal failed; account remains signed in")
        }
        reloadAccounts()
        guard !accounts.contains(where: { $0.id == id }) else {
            apply(.accountsChanged(accounts))
            return
        }
        if let removedAccount {
            mediaShareAccountService.retireCredential(for: removedAccount)
        }
        if let shareAccountKey {
            shareScanStatusModel.removeShare(shareID: shareAccountKey)
            mediaShareAccountService.invalidate(shareAccountKey: shareAccountKey)
        }
        setPlexTokenOverride(nil, for: id)
        plexResolvedHomeUser[id] = nil
        plexHomeUserTokenCache.removeAll(account: id)
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
        let removedAccounts = accounts
        let shareAccountKeys = mediaShareAccountService.mediaShareAccountKeys(in: removedAccounts)
        do {
            try accountStore.clearAll()
        } catch {
            PlozzLog.auth.error("Sign out all was incomplete; retained accounts remain signed in")
        }
        reloadAccounts()
        let retainedAccountIDs = Set(accounts.map(\.id))
        let confirmedRemovedAccounts = removedAccounts.filter {
            !retainedAccountIDs.contains($0.id)
        }
        let confirmedShareAccountKeys = shareAccountKeys.filter {
            !retainedAccountIDs.contains($0)
        }
        confirmedRemovedAccounts.forEach(mediaShareAccountService.retireCredential)
        confirmedShareAccountKeys.forEach {
            shareScanStatusModel.removeShare(shareID: $0)
        }
        for accountKey in confirmedShareAccountKeys {
            mediaShareAccountService.invalidate(shareAccountKey: accountKey)
        }
        for account in confirmedRemovedAccounts {
            setPlexTokenOverride(nil, for: account.id)
            plexResolvedHomeUser[account.id] = nil
            plexHomeUserTokenCache.removeAll(account: account.id)
        }
        apply(.accountsChanged(accounts))
    }

    /// Debug-only: wipes everything that gates the first-run experience —
    /// accounts, profiles (collapsed to a single pristine default), the
    /// first-run flag, and the recent-servers list — so the next server add
    /// reproduces a genuine first run. Surfaced from a DEBUG-only Settings row.
    public func resetToFirstRunForDebugging() {
        let removedAccounts = accounts
        let shareAccountKeys = mediaShareAccountService.mediaShareAccountKeys(in: removedAccounts)
        do {
            try accountStore.clearAll()
        } catch {
            PlozzLog.auth.error("First-run reset could not remove every account")
        }
        reloadAccounts()
        let retainedAccountIDs = Set(accounts.map(\.id))
        let confirmedRemovedAccounts = removedAccounts.filter {
            !retainedAccountIDs.contains($0.id)
        }
        let confirmedShareAccountKeys = shareAccountKeys.filter {
            !retainedAccountIDs.contains($0)
        }
        confirmedRemovedAccounts.forEach(mediaShareAccountService.retireCredential)
        confirmedShareAccountKeys.forEach {
            shareScanStatusModel.removeShare(shareID: $0)
        }
        for accountKey in confirmedShareAccountKeys {
            mediaShareAccountService.invalidate(shareAccountKey: accountKey)
        }
        guard accounts.isEmpty else {
            apply(.accountsChanged(accounts))
            return
        }
        plexTokenOverrides.removeAll()
        plexOverrideCredentialRevisions.removeAll()
        plexResolvedHomeUser.removeAll()
        plexHomeUserTokenCache.removeAll()
        profilesModel.resetToPristineDefaultForDebugging()
        var recents = lastServerStore
        recents.recentServers = []
        pendingPlexUserSelection = nil
        pendingLibrarySelectionAccountIDs = []
        pendingOnboardingContinuation = nil
        pendingPlexUserApplyToAccountIDs = []
        isChoosingProfile = false
        rebuildSettingsModels()
        apply(.accountsChanged(accounts))
    }

    public func retry() {
        apply(.retry)
    }

    // MARK: Profiles

    /// Opens the profile picker (from Settings → "Switch Profile").
    public func requestProfileSelection() {
        isProfileSelectionCancelable = true
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
        audioController.stop()
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
                profile.avatarEmoji = draft.avatarEmoji
                profile.avatarEmojiColorIndex = draft.avatarEmojiColorIndex
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
            let created = profilesModel.add(
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
                avatarImageURL: draft.avatarImageURL,
                avatarEmoji: draft.avatarEmoji,
                avatarEmojiColorIndex: draft.avatarEmojiColorIndex
            )
            // Switch to the freshly created profile so the per-profile theme
            // picker edits *its* namespace, then present it. Mirrors
            // `switchProfile(to:)` minus the Plex identity check, which is
            // deferred to `finishNewProfileThemeSelection()` so any PIN prompt
            // surfaces as the new profile actually enters the app — not stacked
            // under the theme cover.
            audioController.stop()
            profilesModel.select(created.id)
            rebuildSettingsModels()
            updateTraktForActiveProfile()
            reloadAccounts()
            isChoosingProfile = false
            isPickingThemeForNewProfile = true
        }
    }

    /// Persists ONLY a profile's cosmetic fields (name, avatar symbol/emoji,
    /// colours, borrowed photo) — used by the editor's live auto-save while you
    /// tweak an existing profile.
    ///
    /// Deliberately does **none** of `saveProfile`'s "the active profile's
    /// substance changed" work — no `rebuildSettingsModels`, `reloadAccounts` or
    /// `ensurePlexIdentityForActiveProfile`. Those re-scope which servers feed
    /// Home and can raise a Plex PIN prompt; running them on every keystroke of a
    /// cosmetic edit would reload/flicker Home and could pop a spurious PIN. A
    /// name/avatar/colour change touches none of that, so we just write the
    /// value through. No-op for an unknown id.
    public func updateProfileCosmetics(_ draft: ProfileDraft) {
        guard let id = draft.id,
              var profile = profilesModel.profiles.first(where: { $0.id == id }) else { return }
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never persist a blank name (the field may be momentarily empty while
        // retyping) — keep the last valid one.
        if !trimmed.isEmpty { profile.name = draft.name }
        profile.avatarSymbol = draft.avatarSymbol
        profile.colorIndex = draft.colorIndex
        profile.avatarImageURL = draft.avatarImageURL
        profile.avatarEmoji = draft.avatarEmoji
        profile.avatarEmojiColorIndex = draft.avatarEmojiColorIndex
        profilesModel.update(profile)
    }

    /// Removes a profile (the default profile can't be removed). If it was
    /// active, selection falls back to the first profile and re-scopes.
    public func removeProfile(id: String) {
        let wasActive = id == profilesModel.activeProfileID
        watchReconcilers[id] = nil
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
        // Mutate the resolved set that the UI is actually showing, not the raw
        // stored set. The latter can contain only stale account ids after a
        // server is removed/re-added; reloadAccounts() intentionally resolves
        // that situation to the current household set. Starting from the stale
        // stored value would make removing a visible account a no-op, then the
        // next reload would fall back to every account and leave the switch On.
        let current = activeAccountIDs
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
        // The household-global active set is the fallback for a profile that has
        // never chosen a subset (default profile / upgrade path).
        let globalActive = accountStore.activeAccountIDs()
        let resolved: Set<String>
        if let stored = profilesModel.storedActiveAccountIDs(for: profilesModel.activeProfileID) {
            // The profile made an *explicit* choice. Honor it exactly — including
            // an intentional empty set ("watch nothing"), which is what turning
            // the last server off produces and must not be silently re-expanded
            // to every account (that's what made the master server toggle appear
            // to do nothing). Only fall back if every chosen account has since
            // gone stale (e.g. the servers were signed out household-wide), so a
            // profile isn't left permanently blank by a removal it didn't make.
            let valid = Set(stored.filter { known.contains($0) })
            if valid.isEmpty && !stored.isEmpty {
                resolved = Set(globalActive.filter { known.contains($0) })
            } else {
                resolved = valid
            }
        } else {
            // Never chose → default to the household-global active set.
            resolved = Set(globalActive.filter { known.contains($0) })
        }
        activeAccountIDs = resolved
        sharePriorityRevision &+= 1
        let priorityRevision = sharePriorityRevision
        let preferredShareIDs = Set(
            accounts
                .filter {
                    resolved.contains($0.id)
                        && $0.server.provider == .mediaShare
                }
                .map(\.id)
        )
        Task { [mediaShareRuntime] in
            await mediaShareRuntime.setPreferredAccountKeys(
                preferredShareIDs,
                revision: priorityRevision
            )
        }
    }

    /// Rebuilds the settings models scoped to the active profile's
    /// namespace. No-op when settings models were injected (tests).
    private func rebuildSettingsModels() {
        guard !usesInjectedModels else { return }
        let ns = profilesModel.activeNamespace
        subtitleBehaviorModel = SubtitleBehaviorModel(store: SubtitleBehaviorStore(namespace: ns))
        subtitleStyleModel = SubtitleStyleModel(store: SubtitleStyleStore(namespace: ns))
        spoilerModel = SpoilerSettingsModel(store: SpoilerSettingsStore(namespace: ns))
        playbackModel = PlaybackSettingsModel(store: PlaybackSettingsStore(namespace: ns))
        subtitlePolicyModel = SubtitlePolicyModel(store: SubtitlePolicyStore(namespace: ns))
        audioPolicyModel = AudioPolicyModel(store: AudioPolicyStore(namespace: ns))
        themeModel = ThemeSettingsModel(store: ThemeSettingsStore(namespace: ns))
        themeMusicModel = ThemeMusicSettingsModel(store: ThemeMusicSettingsStore(namespace: ns))
        diagnosticsModel = DiagnosticsSettingsModel(store: DiagnosticsSettingsStore(namespace: ns))
        musicPlayerModel = MusicPlayerSettingsModel(store: MusicPlayerSettingsStore(namespace: ns))
        homeLibraryVisibilityModel = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(namespace: ns))
        uiDensityModel = UIDensitySettingsModel(store: UIDensitySettingsStore(namespace: ns))
        cardStyleModel = CardStyleSettingsModel(store: CardStyleSettingsStore(namespace: ns))
        watchStatusIndicatorModel = WatchStatusIndicatorSettingsModel(store: WatchStatusIndicatorSettingsStore(namespace: ns))
        navigationStyleModel = NavigationStyleSettingsModel(store: NavigationStyleSettingsStore(namespace: ns))
        transparencyModel = TransparencyPreferenceModel(store: TransparencyPreferenceStore(namespace: ns))
        heroSettingsModel = HeroSettingsModel(store: HeroSettingsStore(namespace: ns))
        nightShiftModel = NightShiftSettingsModel(store: NightShiftSettingsStore(namespace: ns))
    }

    /// Repoints Trakt (and its shared scrobbler) at the active profile's own
    /// connection so each household profile scrobbles to its own Trakt account.
    /// Also repoints Simkl, AniList, and MAL. Fire-and-forget: the status refresh
    /// is async and best-effort.
    private func updateTraktForActiveProfile() {
        let ns = profilesModel.activeNamespace
        trackerProfileGeneration &+= 1
        let generation = trackerProfileGeneration
        resetIdentityIndex()
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
