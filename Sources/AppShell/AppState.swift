import Foundation
import Observation
import CoreModels
import CoreNetworking
import FeatureAuth
import FeatureDiscovery
import FeatureMusic
import FeatureProfiles
import ProviderJellyfin
import ProviderPlex
import RatingsService
import TraktService
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
    /// The active profile's Night Shift (warm/dim screen tint) settings + live
    /// schedule. Scoped per profile (rebuilt on profile switch) like the theme;
    /// its overlay is installed at the app root in `RootView`.
    public private(set) var nightShiftModel: NightShiftSettingsModel

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
    /// When `true`, `RootView` shows the profile picker instead of the signed-in
    /// UI (shown at launch with >1 profile, and from "Switch Profile").
    public private(set) var isChoosingProfile = false
    /// Whether the current profile picker can be dismissed without choosing.
    /// `false` for the mandatory launch picker (Back / Cancel must not bail out
    /// of it), `true` when opened from Settings → "Switch Profile" over an
    /// already-active profile.
    public private(set) var isProfileSelectionCancelable = false

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

    /// Simkl sync: device-code OAuth + history scrobble. Mirrors Trakt's pattern.
    public let simklService: SimklService

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
            simklScrobbler: { [weak self] in
                await MainActor.run { self?.simklService.scrobbler ?? DisabledSimklScrobbler() }
            },
            anilistScrobbler: { [weak self] in
                await MainActor.run { self?.anilistService.scrobbler ?? DisabledAniListScrobbler() }
            },
            malScrobbler: { [weak self] in
                await MainActor.run { self?.malService.scrobbler ?? DisabledMALScrobbler() }
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
            indexedSources: { [identitySnapshotStore] identities in
                identitySnapshotStore.current.sources(forIdentities: identities)
            },
            indexedAccountIDs: { [identitySnapshotStore] in
                identitySnapshotStore.current.indexedAccountIDs
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
        profilesModel: ProfilesModel? = nil,
        systemBridge: SystemProfileBridging? = nil,
        subtitleBehaviorModel: SubtitleBehaviorModel? = nil,
        subtitleStyleModel: SubtitleStyleModel? = nil,
        spoilerModel: SpoilerSettingsModel? = nil,
        playbackModel: PlaybackSettingsModel? = nil,
        themeModel: ThemeSettingsModel? = nil,
        diagnosticsModel: DiagnosticsSettingsModel? = nil,
        musicPlayerModel: MusicPlayerSettingsModel? = nil,
        homeLibraryVisibilityModel: HomeLibraryVisibilityModel? = nil,
        uiDensityModel: UIDensitySettingsModel? = nil,
        nightShiftModel: NightShiftSettingsModel? = nil,
        ratingsProvider: (any ExternalRatingsProviding)? = nil,
        traktService: TraktService? = nil,
        simklService: SimklService? = nil,
        anilistService: AniListService? = nil,
        malService: MALService? = nil,
        lastfmService: LastFmService? = nil
    ) {
        self.accountStore = accountStore ?? Self.makeDefaultAccountStore()
        self.registry = registry ?? Self.makeDefaultRegistry()
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
            || themeModel != nil || diagnosticsModel != nil
            || homeLibraryVisibilityModel != nil || musicPlayerModel != nil
            || uiDensityModel != nil
            || nightShiftModel != nil
        self.usesInjectedModels = injected
        let ns = (profilesModel ?? self.profilesModel).activeNamespace
        // Seed Trakt with the active profile's namespace so its scrobbler and the
        // Settings connection model read that profile's own Trakt tokens.
        self.traktService = traktService ?? TraktServiceFactory.make(namespace: ns)
        // Seed other trackers with the same profile namespace.
        self.simklService = simklService ?? SimklServiceFactory.make(namespace: ns)
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
        self.diagnosticsModel = diagnosticsModel ?? DiagnosticsSettingsModel(store: DiagnosticsSettingsStore(namespace: ns))
        self.musicPlayerModel = musicPlayerModel ?? MusicPlayerSettingsModel(store: MusicPlayerSettingsStore(namespace: ns))
        self.homeLibraryVisibilityModel = homeLibraryVisibilityModel
            ?? HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(namespace: ns))
        self.uiDensityModel = uiDensityModel
            ?? UIDensitySettingsModel(store: UIDensitySettingsStore(namespace: ns))
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
                        plexTokenOverrides[account.id] = nil
                        plexResolvedHomeUser[account.id] = nil
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
                        plexTokenOverrides[account.id] = cached
                        plexResolvedHomeUser[account.id] = binding.homeUserID
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
                    plexTokenOverrides[account.id] = nil
                    plexResolvedHomeUser[account.id] = nil
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
            plexTokenOverrides.removeAll()
            plexResolvedHomeUser.removeAll()
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
            plexTokenOverrides[accountID] = resolvedToken
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
        plexHomeUserTokenCache.removeAll(account: id)
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
        plexTokenOverrides.removeAll()
        plexResolvedHomeUser.removeAll()
        plexHomeUserTokenCache.removeAll()
        reloadAccounts()
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
        subtitleBehaviorModel = SubtitleBehaviorModel(store: SubtitleBehaviorStore(namespace: ns))
        subtitleStyleModel = SubtitleStyleModel(store: SubtitleStyleStore(namespace: ns))
        spoilerModel = SpoilerSettingsModel(store: SpoilerSettingsStore(namespace: ns))
        playbackModel = PlaybackSettingsModel(store: PlaybackSettingsStore(namespace: ns))
        subtitlePolicyModel = SubtitlePolicyModel(store: SubtitlePolicyStore(namespace: ns))
        audioPolicyModel = AudioPolicyModel(store: AudioPolicyStore(namespace: ns))
        themeModel = ThemeSettingsModel(store: ThemeSettingsStore(namespace: ns))
        diagnosticsModel = DiagnosticsSettingsModel(store: DiagnosticsSettingsStore(namespace: ns))
        musicPlayerModel = MusicPlayerSettingsModel(store: MusicPlayerSettingsStore(namespace: ns))
        homeLibraryVisibilityModel = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(namespace: ns))
        uiDensityModel = UIDensitySettingsModel(store: UIDensitySettingsStore(namespace: ns))
        nightShiftModel = NightShiftSettingsModel(store: NightShiftSettingsStore(namespace: ns))
    }

    /// Repoints Trakt (and its shared scrobbler) at the active profile's own
    /// connection so each household profile scrobbles to its own Trakt account.
    /// Also repoints Simkl, AniList, and MAL. Fire-and-forget: the status refresh
    /// is async and best-effort.
    private func updateTraktForActiveProfile() {
        let ns = profilesModel.activeNamespace
        resetWatchReconciler()
        resetIdentityIndex()
        Task {
            await traktService.setActiveProfile(namespace: ns)
            await simklService.setActiveProfile(namespace: ns)
            await anilistService.setActiveProfile(namespace: ns)
            await malService.setActiveProfile(namespace: ns)
            await lastfmService.setActiveProfile(namespace: ns)
        }
    }

    private func apply(_ event: SessionEvent) {
        machine.apply(event)
        state = machine.state
    }
}
