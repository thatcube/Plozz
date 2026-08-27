import Foundation
import Observation
import CoreModels
import CoreNetworking

public typealias HomeContentPublishing =
    @Sendable (_ continueWatching: [MediaItem], _ latest: [MediaItem]) async -> Void

/// Loads and holds the unified Home screen's content rows, merged across every
/// active account/provider. Home-visibility filtering of the Libraries row is
/// applied reactively in the view (against the shared visibility model) so the
/// network result is held unfiltered and toggles take effect without a reload.
@MainActor
@Observable
public final class HomeViewModel {
    public struct Content: Equatable, Sendable, Codable {
        public var continueWatching: [MediaItem]
        public var latest: [MediaItem]
        /// The unified Watchlist row, merged across `WatchlistProviding` accounts.
        public var watchlist: [MediaItem]
        /// Every discovered library (unfiltered), tagged with its owning account.
        public var libraries: [AggregatedLibrary]
        /// Whether Home is in merged mode. `true` (default) uses the classic
        /// cross-server rows (`latest`/`libraries`); `false` means the profile
        /// turned off "Merge libraries on Home" and `librarySections` carries the
        /// per-library blocks instead.
        public var mergeLibraries: Bool = true
        /// Per-library section blocks — populated only in unmerged mode. Each
        /// library's own Continue Watching / Recently Added / discovery-hub rows.
        public var librarySections: [HomeLibrarySectionGroup] = []

        public init(
            continueWatching: [MediaItem] = [],
            latest: [MediaItem] = [],
            watchlist: [MediaItem] = [],
            libraries: [AggregatedLibrary] = [],
            mergeLibraries: Bool = true,
            librarySections: [HomeLibrarySectionGroup] = []
        ) {
            self.continueWatching = continueWatching
            self.latest = latest
            self.watchlist = watchlist
            self.libraries = libraries
            self.mergeLibraries = mergeLibraries
            self.librarySections = librarySections
        }

        // The launch snapshot persists only the merged-mode rows plus the merge
        // flag. `librarySections` (the unmerged per-library blocks) are deliberately
        // NOT Codable-persisted — they'd force Codable onto the whole provider-
        // agnostic section model for little gain, and the silent refresh repopulates
        // them within the first appearance. The instant paint still shows the global
        // rows, the Libraries tiles, and the correct merged/unmerged layout.
        private enum CodingKeys: String, CodingKey {
            case continueWatching, latest, watchlist, libraries, mergeLibraries
        }

        public var isEmpty: Bool {
            continueWatching.isEmpty && latest.isEmpty && watchlist.isEmpty
                && libraries.isEmpty && librarySections.isEmpty
        }

        /// A copy bounded to at most `perRow` items in each media row (libraries
        /// kept whole — they're few and cheap). Used before persisting a snapshot so
        /// the on-disk cache stays small; the first launch paint only needs enough
        /// to fill the hero + the top of each row anyway. Preserves the merge flag
        /// and per-library blocks so an unmerged snapshot paints in the right layout.
        func bounded(perRow: Int) -> Content {
            Content(
                continueWatching: Array(continueWatching.prefix(perRow)),
                latest: Array(latest.prefix(perRow)),
                watchlist: Array(watchlist.prefix(perRow)),
                libraries: libraries,
                mergeLibraries: mergeLibraries,
                librarySections: librarySections.map {
                    HomeLibrarySectionGroup(
                        library: $0.library,
                        sections: $0.sections.map {
                            LibrarySection(id: $0.id, title: $0.title, style: $0.style,
                                           items: Array($0.items.prefix(perRow)))
                        }
                    )
                }
            )
        }
    }

    public private(set) var state: LoadState<Content> = .idle

    /// `true` while `state` holds a snapshot hydrated from `contentStore` on launch
    /// that has NOT yet been refreshed from the network this session. The first
    /// appearance then refreshes **silently** (no full-screen skeleton). Stable
    /// cached rows remain visible; Continue Watching uses a row placeholder until
    /// fresh content publishes once.
    public private(set) var isShowingCachedSnapshot = false
    /// Prevents a restarted SwiftUI task from starting the launch refresh twice
    /// while the cached rows remain visible.
    @ObservationIgnored private var cachedSnapshotRefreshStarted = false

    /// The row structure to render as a skeleton while loading: the layout
    /// persisted from the previous successful load (row kinds, order **and** the
    /// card count each row rendered, so the placeholder matches the user's real
    /// Home), falling back to a default on a first-ever launch.
    public private(set) var skeletonLayout: [HomeRowLayout]

    private let accounts: [ResolvedAccount]
    private let aggregator: HomeAggregator
    private let layoutStore: HomeLayoutStoring
    /// Persists a bounded snapshot of the last successful `Content` so the next
    /// launch can paint stable rows immediately from disk (artwork bytes already
    /// persist in `ArtworkImageCache`/`URLCache`) and then silently refresh. See
    /// `HomeContentStore`.
    private let contentStore: HomeContentStoring
    /// The shared identity-index lookup folded into every merged row so a card
    /// surfaced by one server still carries its full cross-server source set.
    private let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]
    /// Reads the user's *current* per-library Home-visibility at load time, so a
    /// reload (e.g. after a library is hidden) re-aggregates against the latest
    /// choices. Drives the provider's library-scoped fetch for hidden-aware
    /// accounts; the per-item row filter still lives in the view so toggles that
    /// need no re-fetch (Plex, already-tagged items) apply instantly.
    private let currentVisibility: () -> HomeLibraryVisibility

    /// A snapshot of the durable watch-outbox's not-yet-confirmed mutations, read
    /// at load time so the freshly-fetched Continue Watching row reflects plays the
    /// user just performed in-app that the servers haven't recorded yet (the outbox
    /// write is still queued / in-flight, or the server's Resume/OnDeck query is
    /// eventually-consistent). Without this, a reload momentarily reverts the row to
    /// stale pre-play order — the reported "Continue Watching keeps shifting / isn't
    /// what I watched last" symptom. Defaults to none so existing callers/tests are
    /// unaffected. (r8-cw-outbox-patch)
    private let pendingWatchMutations: @Sendable () async -> [WatchMutation]

    /// A snapshot of recently-applied in-progress resume writes (keyed by
    /// `"accountID:itemID"`), read at load time so the Continue Watching overlay can
    /// clamp a server's drain-time timestamp inflation back down to the play's real
    /// time. Plex's `/:/progress` stamps its own server-side view timestamp and can't
    /// backdate it, so an *offline-queued* resume write that drains late otherwise
    /// re-floats a stale title to the top of the row on the next reload. Records are
    /// short-lived, so this never overrides a genuine later play (e.g. on another
    /// client). Defaults to none so existing callers/tests are unaffected. (h2-cw-clamp)
    private let recentlyAppliedRecency: @Sendable () async -> [String: AppliedResumeRecord]
    private let contentPublisher: HomeContentPublishing
    /// What belongs on the Continue Watching row and how long a loaded row may be
    /// trusted. Shared with the aggregator so the limit, the staleness cutoff and
    /// the refresh window are one set of rules rather than three.
    private let policy: ContinueWatchingPolicy
    private let mediaItemActionHandler: (any MediaItemActionHandling)?

    /// In-flight content aggregation (run off the main actor) and the fire-and-
    /// forget Top Shelf publish. Tracked so ``deinit`` can cancel them — otherwise
    /// a Home model torn down mid-load (or one that just falls out of scope in a
    /// unit test) leaks detached work that outlives it, occupying the cooperative
    /// pool and, in tests, surviving the case to trip the simulator watchdog.
    // `nonisolated(unsafe)` so the nonisolated `deinit` can cancel these. Mutated
    // only on the main actor; `deinit` runs after the last reference is gone.
    private nonisolated(unsafe) var aggregationTask: Task<HomeAggregator.Content, Never>?
    /// The unmerged counterpart of `aggregationTask` (populated when the profile
    /// has turned off "Merge libraries on Home"). Tracked so `deinit` can cancel it.
    private nonisolated(unsafe) var unmergedTask: Task<HomeAggregator.UnmergedContent, Never>?
    private nonisolated(unsafe) var topShelfPublishTask: Task<Void, Never>?

    /// Coalesces the burst of `identityIndexDidUpdate` notifications posted while
    /// the index warms: each active account publishes independently, so a fresh
    /// boot with N servers fires N notifications back-to-back. Re-folding every
    /// Home row (Continue Watching + Latest + Watchlist) on the main actor once
    /// per notification is O(N × rows) of avoidable churn during the most
    /// contended moment of launch. Debouncing collapses the burst into a single
    /// re-enrich after the warm settles; the last snapshot is authoritative, so
    /// nothing is lost. Cancelled on teardown alongside the other tasks.
    private nonisolated(unsafe) var reenrichTask: Task<Void, Never>?

    /// How long to wait for the warm burst to settle before re-folding. Short
    /// enough to feel immediate, long enough to swallow a multi-server burst.
    private static let reenrichDebounce: Duration = .milliseconds(200)

    /// The full visibility snapshot the currently-loaded content was aggregated
    /// for — Home-hidden **and** app-wide-disabled sets **and** the merge switch.
    /// `nil` until the first successful load. Used by ``loadIfNeeded(for:)`` to tell
    /// a genuine input change (hide/show/disable a library, or flip merge) apart
    /// from a mere view reappearance — tvOS restarts a `.task(id:)` every time Home
    /// returns from a pushed detail, so an unguarded reload would re-fetch (flashing
    /// the skeleton) and rebuild the rows (yanking focus to the top) on every
    /// back-navigation. Comparing the whole value (not just `disabledKeys`) means a
    /// disable/enable or a merged↔unmerged flip correctly forces a re-aggregation,
    /// since both change what Home fetches and renders.
    private var lastLoadedVisibility: HomeLibraryVisibility?
    /// When the currently-loaded content was aggregated.
    ///
    /// Home has no way to hear that a title was watched, finished or dismissed on
    /// another device: there is no push, and every in-app signal it does have
    /// describes something the viewer did *here*. Left alone it will therefore
    /// keep showing the row it built at launch for as long as the app stays open,
    /// which is the reported "Continue Watching isn't in sync" — the row was right
    /// when it was built and nothing ever asked again. Recording the time lets a
    /// reappearance tell ordinary navigation apart from a genuine absence.
    private var lastLoadedAt: Date?
    /// A load is running right now. See ``load(showLoadingState:)``.
    @ObservationIgnored private var isLoading = false
    /// A load was requested while one was already running; run once more after.
    @ObservationIgnored private var wantsReloadAfterCurrent = false

    public init(
        accounts: [ResolvedAccount],
        aggregator: HomeAggregator = HomeAggregator(),
        layoutStore: HomeLayoutStoring = HomeLayoutStore(),
        contentStore: HomeContentStoring = NoOpHomeContentStore(),
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        currentVisibility: @escaping () -> HomeLibraryVisibility = { .default },
        pendingWatchMutations: @escaping @Sendable () async -> [WatchMutation] = { [] },
        recentlyAppliedRecency: @escaping @Sendable () async -> [String: AppliedResumeRecord] = { [:] },
        mediaItemActionHandler: (any MediaItemActionHandling)? = nil,
        policy: ContinueWatchingPolicy = .default,
        contentPublisher: @escaping HomeContentPublishing = { _, _ in }
    ) {
        self.accounts = accounts
        self.aggregator = aggregator
        self.layoutStore = layoutStore
        self.contentStore = contentStore
        self.identitySources = identitySources
        self.currentVisibility = currentVisibility
        self.pendingWatchMutations = pendingWatchMutations
        self.recentlyAppliedRecency = recentlyAppliedRecency
        self.policy = policy
        self.contentPublisher = contentPublisher
        self.mediaItemActionHandler = mediaItemActionHandler
        let persisted = layoutStore.load()
        self.skeletonLayout = persisted.isEmpty ? HomeRowKind.defaultSkeletonLayout : persisted
        // Hydrate last-known stable rows from disk. Continue Watching is deliberately
        // replaced by its row-sized placeholder until fresh multi-server data lands;
        // mixed/local heroes likewise wait for complete curation. Only a non-empty
        // snapshot is used; anything else leaves
        // `state == .idle` so a genuine first launch shows the normal loading state.
        if var cached = contentStore.load() {
            cached.watchlist = Self.resolvedWatchlist(
                candidates: cached.watchlist + cached.latest,
                fetched: cached.watchlist,
                lastKnown: cached.watchlist,
                handler: mediaItemActionHandler
            )
            // With NO servers to watch, every SERVER-derived row in the snapshot
            // belongs to a library this profile no longer sees. Repainting them
            // is what made turning every server off appear to do nothing —
            // Settings showed them all off while Home kept the old library, and
            // `save` refuses to overwrite good content with an empty aggregate,
            // so it came back on every launch. The universal watchlist is the
            // user's own and survives: it isn't a server's to take away.
            if accounts.isEmpty {
                cached.continueWatching = []
                cached.latest = []
                cached.libraries = []
                cached.librarySections = []
                contentStore.clear()
            }
            if !cached.isEmpty {
                self.state = .loaded(cached)
                self.isShowingCachedSnapshot = true
            }
        }
    }

    deinit {
        aggregationTask?.cancel()
        unmergedTask?.cancel()
        topShelfPublishTask?.cancel()
        reenrichTask?.cancel()
    }

    /// User-facing name for the greeting header — the primary (first) account.
    public var userName: String { accounts.first?.account.userName ?? "" }

    /// Records the row structure the view actually rendered — each row's kind and
    /// the number of cards it showed — so the next launch's skeleton matches it.
    /// Driven by the view (not derived here) because true visibility — e.g.
    /// whether the Libraries row survives the user's per-library Home-visibility
    /// choices, and how many items/tiles each row ends up with — is only known at
    /// render time. Saves only on change to avoid redundant `UserDefaults` writes.
    public func rememberLayout(_ layout: [HomeRowLayout]) {
        guard layout != skeletonLayout else { return }
        skeletonLayout = layout
        layoutStore.save(layout)
    }

    /// Loads on first appearance and re-aggregates only when the visibility
    /// snapshot actually changed since the last successful load. tvOS cancels and
    /// restarts a `.task(id:)` every time Home reappears (returning from a pushed
    /// detail), so binding `load()` directly to the task would reload on every
    /// back-navigation — flashing the skeleton and resetting focus to the top.
    /// This guard makes the reappearance a no-op while still reacting to a genuine
    /// This guard makes the reappearance a no-op while still reacting to a genuine
    /// change: hiding/showing/disabling a library, or flipping the merge switch.
    public func loadIfNeeded(for visibility: HomeLibraryVisibility) async {
        // Showing a cached snapshot from launch: refresh SILENTLY so the instant
        // hero + stable rows never flash to a full-screen skeleton. The volatile
        // Continue Watching row renders a row-sized placeholder until this finishes,
        // so old cards never swap underneath the viewer.
        if isShowingCachedSnapshot {
            guard !cachedSnapshotRefreshStarted else { return }
            cachedSnapshotRefreshStarted = true
            await load(showLoadingState: false)
            cachedSnapshotRefreshStarted = false
            return
        }
        switch state {
        case .loaded, .empty:
            if lastLoadedVisibility == visibility {
                // Nothing the viewer chose has changed — but the world may have.
                // A row older than the policy's window is refreshed **silently**:
                // the current rows stay on screen until fresh content swaps in, so
                // there is no skeleton flash and no focus reset, exactly as for the
                // launch-snapshot and post-playback refreshes. Inside the window a
                // reappearance stays the no-op it has always been, because stepping
                // into a title and back out is navigation, not new information, and
                // reloading there would reshuffle the row under the viewer for
                // nothing.
                let age = lastLoadedAt.map { Date().timeIntervalSince($0) }
                let isStale = (age ?? .infinity) > policy.refreshAfter
                ContinueWatchingDiagnostics.emit(ContinueWatchingDiagnostics.refreshLine(
                    trigger: "appear",
                    willReload: isStale,
                    reason: isStale
                        ? "stale age=\(age.map { String(format: "%.0fs", $0) } ?? "never") > \(Int(policy.refreshAfter))s"
                        : "fresh age=\(age.map { String(format: "%.0fs", $0) } ?? "never")"
                ))
                guard isStale else { return }
                await load(showLoadingState: false)
                return
            }
        default:
            break
        }
        ContinueWatchingDiagnostics.emit(ContinueWatchingDiagnostics.refreshLine(
            trigger: "appear",
            willReload: true,
            reason: "visibility-changed-or-not-loaded"
        ))
        await load()
    }

    public func load() async {
        await load(showLoadingState: true)
    }

    /// Re-aggregates Home content. `showLoadingState` is `false` for a *silent*
    /// refresh (e.g. surfacing a brand-new resume after playback) — the currently
    /// loaded rows stay on screen until the fresh content swaps in, so there's no
    /// skeleton flash or focus reset for a background update.
    public func load(showLoadingState: Bool) async {
        // Coalesce concurrent loads. A load is a fan-out across every signed-in
        // account — measured at ~2.5s per account on a cold launch — so two
        // overlapping ones cost double the network and CPU for one result. They
        // really do overlap: Home's first appearance calls `loadIfNeeded`, and a
        // `.mediaItemDidMutate` notification arriving during launch asks for a
        // full reload on top of it. Rather than drop the request (the caller may
        // know about a change this load started too early to see), remember it
        // and run exactly once more when the current pass finishes.
        guard !isLoading else {
            wantsReloadAfterCurrent = true
            return
        }
        isLoading = true
        defer {
            isLoading = false
            if wantsReloadAfterCurrent {
                wantsReloadAfterCurrent = false
                Task { await load(showLoadingState: false) }
            }
        }
        PlozzLog.boot("HomeVM.load START vm=\(UInt(bitPattern: ObjectIdentifier(self).hashValue)) accounts=\(accounts.count) state=\(String(describing: state)) silent=\(!showLoadingState)")
        let onScreenWatchlist = state.value?.watchlist ?? []
        if showLoadingState { state = .loading }

        let aggregator = self.aggregator
        let accounts = self.accounts
        let identitySources = self.identitySources
        let policy = self.policy
        // What the viewer is looking at right now. A just-played card lives here and
        // nowhere else until the servers catch up, so it has to be offered to the
        // reconciler — which decides, on evidence, whether it has earned its place.
        let onScreenContinueWatching = state.value?.continueWatching ?? []
        let visibility = currentVisibility()

        // Watchlist policy: an explicit user save is dropped only when its
        // library is **disabled** (off everywhere). A watchlisted title whose
        // libraries are ALL disabled is dropped; items with no resolvable library
        // stay (fail-open). Applied here so it also governs the hero (which seeds
        // from the watchlist), not just the row.
        let keepWatchlisted: (MediaItem) -> Bool = { item in
            item.isVisibleOnHome(isLibraryVisible: { visibility.isEnabled($0) })
        }

        // Overlay the durable outbox's not-yet-confirmed plays onto the freshly
        // fetched Continue Watching row so a reload doesn't revert it to stale
        // pre-play order while the server catches up (r8-cw-outbox-patch).
        // Overlay the durable outbox's not-yet-confirmed plays onto the freshly
        // fetched Continue Watching row so a reload doesn't revert it to stale
        // pre-play order while the server catches up (r8-cw-outbox-patch).
        let content: Content
        if visibility.mergeLibrariesOnHome {
            let aggregationTask = Task.detached(priority: .userInitiated) {
                await aggregator.content(from: accounts, policy: policy, visibility: visibility, identitySources: identitySources)
            }
            self.aggregationTask = aggregationTask
            let merged = await aggregationTask.value
            // SwiftUI can cancel/restart the view-owned `.task` while this detached,
            // model-owned aggregation is still valid. Publish its completed result
            // unless the model explicitly cancelled the aggregation task itself;
            // checking the caller here discarded an 8-second five-server result and
            // forced a second full fan-out before Continue Watching appeared.
            guard !aggregationTask.isCancelled else { return }
            let pending = await pendingWatchMutations()
            let appliedRecency = await recentlyAppliedRecency()
            noteServerConfirmed(merged.continueWatching)
            let reconciledCW = Self.reconcileContinueWatching(
                merged.continueWatching,
                pending: pending,
                appliedRecency: appliedRecency,
                carryForward: onScreenContinueWatching,
                serverConfirmed: serverConfirmedTargets
            )
            noteUnconfirmed(reconciled: reconciledCW, fetched: merged.continueWatching)
            Self.logOverlay(fetched: merged.continueWatching, reconciled: reconciledCW, pending: pending)
            let durableWatchlist = Self.resolvedWatchlist(
                candidates:
                    reconciledCW + merged.latest + merged.watchlist,
                fetched: merged.watchlist,
                lastKnown: onScreenWatchlist,
                handler: mediaItemActionHandler
            )
            content = Content(
                continueWatching: reconciledCW,
                latest: merged.latest,
                watchlist: durableWatchlist.filter(keepWatchlisted),
                libraries: merged.libraries
            )
        } else {
            // Unmerged: global Continue Watching + Watchlist stay at the top, the
            // full library inventory feeds the Libraries tiles, and each library the
            // user opted rows into contributes a block below.
            let unmergedTask = Task.detached(priority: .userInitiated) {
                await aggregator.unmergedContent(from: accounts, policy: policy, visibility: visibility, identitySources: identitySources)
            }
            self.unmergedTask = unmergedTask
            let unmerged = await unmergedTask.value
            guard !unmergedTask.isCancelled else { return }
            let pending = await pendingWatchMutations()
            let appliedRecency = await recentlyAppliedRecency()
            noteServerConfirmed(unmerged.continueWatching)
            let reconciledCW = Self.reconcileContinueWatching(
                unmerged.continueWatching,
                pending: pending,
                appliedRecency: appliedRecency,
                carryForward: onScreenContinueWatching,
                serverConfirmed: serverConfirmedTargets
            )
            noteUnconfirmed(reconciled: reconciledCW, fetched: unmerged.continueWatching)
            Self.logOverlay(fetched: unmerged.continueWatching, reconciled: reconciledCW, pending: pending)
            let durableWatchlist = Self.resolvedWatchlist(
                candidates:
                    reconciledCW + unmerged.latest + unmerged.watchlist,
                fetched: unmerged.watchlist,
                lastKnown: onScreenWatchlist,
                handler: mediaItemActionHandler
            )
            content = Content(
                continueWatching: reconciledCW,
                latest: unmerged.latest,
                watchlist: durableWatchlist.filter(keepWatchlisted),
                libraries: unmerged.libraries,
                mergeLibraries: false,
                librarySections: unmerged.librarySections
            )
        }
        // A SILENT background refresh that came back empty must not blank out good
        // content already on screen — e.g. the cached snapshot painted at launch,
        // or the rows after playback, when the server is momentarily unreachable.
        // Keep what's showing and bail (also skipping the Top Shelf republish that
        // would otherwise clear it). Record `lastLoadedVisibility` for THIS snapshot
        // so a reappearance with the same visibility stays a no-op (see
        // `loadIfNeeded`) instead of running a *loud* load that flashes the skeleton
        // and then drops the kept content to `.empty` if the server is still down —
        // the exact flash the cached snapshot exists to prevent. A genuine
        // visibility change still reloads; other triggers (post-play resume reload)
        // still refresh.
        // "Empty" means two different things and this rule can't tell them apart
        // on its own: a fetch that FAILED, versus a profile that watches nothing.
        // Only the first is worth papering over — treating the second as a blip
        // is what kept a switched-off server's library on screen. With no sources
        // the emptiness IS the answer, so fall through and let it stand (which
        // also republishes the Top Shelf, rather than leaving it on the old rows).
        if content.isEmpty, accounts.isEmpty {
            contentStore.clear()
        } else if content.isEmpty, !showLoadingState, case .loaded = state {
            PlozzLog.boot("HomeVM.load KEEP-CACHED silent-empty vm=\(UInt(bitPattern: ObjectIdentifier(self).hashValue))")
            lastLoadedVisibility = visibility
            lastLoadedAt = Date()
            // The live sources were unavailable. Reveal the cached row rather than
            // leaving a permanent loading placeholder with no refresh in flight.
            isShowingCachedSnapshot = false
            return
        }
        isShowingCachedSnapshot = false
        state = content.isEmpty ? .empty : .loaded(content)
        // Record what this content was aggregated for so a later reappearance with
        // an unchanged visibility snapshot is recognised as a no-op (see
        // `loadIfNeeded(for:)`).
        lastLoadedVisibility = visibility
        lastLoadedAt = Date()
        // Persist a bounded snapshot of the fresh content so the next launch paints
        // Home instantly (see `HomeContentStore`). Only meaningful, non-empty
        // content is cached — a transient empty aggregate (e.g. server briefly
        // unreachable) must not overwrite a good snapshot with nothing.
        if !content.isEmpty { saveSnapshot(content) }
        PlozzLog.boot("HomeVM.load DONE vm=\(UInt(bitPattern: ObjectIdentifier(self).hashValue)) empty=\(content.isEmpty) merged=\(content.mergeLibraries) cw=\(content.continueWatching.count) latest=\(content.latest.count) wl=\(content.watchlist.count) libs=\(content.libraries.count) sections=\(content.librarySections.count)")
        guard !Task.isCancelled else { return }

        // Publish the playable rows to the App Group so the Top Shelf extension
        // can render them while the app is closed. Tracked so teardown cancels it.
        // Apply the same Home-visibility filter so a hidden library's items don't
        // leak into Top Shelf. `content.latest` is the global Recently Added feed
        // in both merged and unmerged mode, so Top Shelf is identical either way.
        let isLibraryVisible: (String) -> Bool = { visibility.isVisible($0) }
        let continueWatching = content.continueWatching.filter { $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible) }
        let latest = content.latest.filter { $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible) }
        // Supersede any in-flight publish: the async per-item poster compositing
        // makes a publish take seconds, so two overlapping `load()`s would run two
        // detached publishes whose `pruneArtwork(keeping:)` calls could each delete
        // the other's freshly-written poster, leaving a snapshot pointing at a
        // now-missing file (a blank card until the next publish). Cancelling the
        // prior task first guarantees the newest publish wins.
        topShelfPublishTask?.cancel()
        let contentPublisher = contentPublisher
        topShelfPublishTask = Task.detached(priority: .utility) {
            await contentPublisher(continueWatching, latest)
        }
    }

    /// Applies a watched-state or watchlist mutation to the loaded rows **in
    /// place** so affected cards immediately reflect their new state. A title marked
    /// watched leaves Continue Watching immediately; other rows retain the card and
    /// flip its badge without a refetch. A watchlist add/remove also inserts/removes
    /// the title from the Watchlist row.
    public func applyWatchedState(_ mutation: MediaItemMutation) {
        guard case var .loaded(content) = state else {
            // A play that arrives before Home has any content to update is
            // discarded outright — there is no row to change and nothing here
            // schedules a look later. Worth seeing, because from the outside it is
            // indistinguishable from the play never happening.
            ContinueWatchingDiagnostics.emit(ContinueWatchingDiagnostics.homeMutationLine(
                played: mutation.played,
                resumePosition: mutation.resumePosition,
                onRow: false,
                reloadScheduled: false,
                state: String(describing: state)
            ))
            return
        }
        // A resume/progress change — or a *completed* play — means the user
        // actually played the title just now, so bump its recency and re-sort
        // Continue Watching to float it to the front without a full reload. A bare
        // mark-watched / favourite toggle from the context menu carries no playback
        // progress (it sets `played` but no `playedPercentage`) and must NOT
        // reorder the row — the user's focus stays put while the badge flips in
        // place. A finished PLAY reports resume 0 but playedPercentage 1, so the
        // range check must be `> 0` (not the old `> 0 && < 1`, which dropped the
        // just-finished title so its row order didn't reflect the play until the
        // next full reload removed it).
        let reflectsPlayback = (mutation.resumePosition ?? 0) > 0
            || (mutation.playedPercentage.map { $0 > 0 } ?? false)
        // A brand-new *in-progress* resume for a title that isn't on any Home row
        // yet can't be updated in place — the mutation carries only ids + state, not
        // a full card to synthesise. In-place mapping (below) would leave Continue
        // Watching unchanged, so the just-started title never appears until the next
        // full reload (relaunch). Detect that case here and trigger a *silent*
        // re-aggregation so the new card is fetched from its provider (a media
        // share reads its freshly-persisted local resume off disk) and slots in —
        // no skeleton flash, no focus reset. Gated to an in-progress resume (not a
        // finish, which *leaves* Continue Watching) that matches nothing already
        // loaded, so a normal re-watch or mark-watched never forces a reload.
        let isInProgressResume = (mutation.resumePosition ?? 0) > 0 && !(mutation.played ?? false)
        let alreadyOnHome = content.continueWatching.contains { mutation.targets($0) }
        // A title played for the first time has never been on this row, so there is
        // nothing to update in place. The card is right here on the mutation — the
        // player was holding it the whole time — so put it on the row now rather
        // than asking a server which may not have recorded the play yet. Measured on
        // device, that question is asked before our own write arrives and comes back
        // "no", which is why a title started from Search stayed missing until the
        // app was relaunched.
        var placedCard = false
        if isInProgressResume, !alreadyOnHome, let played = mutation.item {
            var card = played
            card.resumePosition = mutation.resumePosition
            card.playedPercentage = mutation.playedPercentage
            card.lastPlayedAt = Date()
            content.continueWatching.insert(card, at: 0)
            unconfirmedContinueWatchingIDs.insert(card.id)
            placedCard = true
        }
        if isInProgressResume {
            // A new play is a new prediction, so it needs a new acknowledgement:
            // whatever the servers told us about this title before this moment no
            // longer settles anything. Without this a title played, removed, and
            // then played again would be treated as already-confirmed and dropped
            // on the next refresh, even though the fresh play genuinely belongs.
            for target in Self.mutationScopeKeys(mutation, card: mutation.item) {
                serverConfirmedTargets.remove(target)
            }
        }
        if isInProgressResume && !alreadyOnHome {
            // Still refresh, so the placed card is reconciled with the server's own
            // view — cross-server sources, episode linkage, artwork it may know
            // better — once that view catches up.
            scheduleNewResumeReload()
        }
        ContinueWatchingDiagnostics.emit(ContinueWatchingDiagnostics.homeMutationLine(
            played: mutation.played,
            resumePosition: mutation.resumePosition,
            onRow: alreadyOnHome || placedCard,
            reloadScheduled: isInProgressResume && !alreadyOnHome,
            state: placedCard ? "loaded placed-card" : "loaded"
        ))

        // A cleared resume point means the title has nowhere left to continue from,
        // so it leaves the row — whether that came from finishing it or from the
        // viewer taking it off deliberately. Distinguished from "unchanged" by the
        // value being explicitly 0 rather than absent: `nil` means this mutation
        // says nothing about position, while 0 says there is no longer one.
        let clearedResume = mutation.resumePosition == 0 && mutation.played != false
        if mutation.played == true || clearedResume {
            content.continueWatching.removeAll { mutation.targets($0) }
            unconfirmedContinueWatchingIDs.subtract(
                content.continueWatching.map(\.id)
            )
        } else if reflectsPlayback {
            let now = Date()
            let stamped = content.continueWatching.map { item -> MediaItem in
                var updated = apply(mutation, to: item)
                if mutation.targets(item) {
                    updated.lastPlayedAt = now
                    // Also stamp the played source ref(s) so a subsequent
                    // cross-server re-merge folds `now` back onto the card via
                    // `unifiedWatchState` (most-recent-wins) instead of reverting
                    // the card's recency to the source's pre-play timestamp.
                    if !updated.sources.isEmpty {
                        updated.sources = updated.sources.map { ref in
                            guard mutation.matches(accountID: ref.accountID, itemID: ref.itemID) else { return ref }
                            var r = ref
                            r.lastPlayedAt = now
                            return r
                        }
                    }
                }
                return updated
            }
            // Float the just-played card(s) to the front while preserving the
            // relative order of every other card. We deliberately do NOT re-run the
            // recency sort here: the loaded row no longer carries the per-server
            // feeds, and re-sorting a row whose just-played cards we've optimistically
            // stamped to `now` would reshuffle it out from under the user. A stable
            // partition ("just watched" → top, everyone else in place) is the correct,
            // focus-preserving reorder.
            let played = stamped.filter { mutation.targets($0) }
            let rest = stamped.filter { !mutation.targets($0) }
            content.continueWatching = played + rest
        } else {
            content.continueWatching = content.continueWatching.map { apply(mutation, to: $0) }
        }
        content.latest = content.latest.map { apply(mutation, to: $0) }
        content.watchlist = updatedWatchlist(content.watchlist, mutation: mutation, in: content)
        // Unmerged mode renders the per-library rows straight from
        // `librarySections`, so the same title's card there must reflect an
        // in-place mark-watched / favourite / finish too — otherwise the global
        // "Recently Added" flips but the per-library copy on the same screen stays
        // stale until relaunch. These are single-source rows, so a plain per-item
        // apply (no recency re-sort) mirrors the `latest` treatment above.
        if !content.librarySections.isEmpty {
            content.librarySections = content.librarySections.map { group in
                var group = group
                group.sections = group.sections.map { section in
                    var section = section
                    section.items = section.items.map { apply(mutation, to: $0) }
                    return section
                }
                return group
            }
        }
        state = .loaded(content)
        // Keep the next launch snapshot in lockstep with in-session watch actions.
        // Without this, quitting after playback resurrects the pre-play Continue
        // Watching order until the next live refresh completes.
        saveSnapshot(content)
    }

    /// Re-resolves the durable alias-ordered Watchlist against already-loaded
    /// presentation candidates. No provider creation, disk read, or network work.
    private var durableWatchlistSaveTask: Task<Void, Never>?
    private var durableWatchlistRefreshTask: Task<Void, Never>?

    /// Re-folds Home's watchlist row shortly after a change, rather than during it.
    ///
    /// `refreshDurableWatchlist` re-resolves universal identity for every loaded
    /// card, which is the expensive graph walk the membership memo exists to avoid
    /// — and it ran synchronously the moment a watchlist notification arrived.
    /// Home stays mounted behind a pushed detail page, so pressing the watchlist
    /// button on a show ran all of that on the main thread before the frame that
    /// would show the button's new state could be drawn.
    ///
    /// Nothing here is urgent: it refreshes a row the viewer is not looking at,
    /// and the control they ARE looking at already answers from intent. Deferring
    /// lets the press paint first, and coalescing means a burst re-folds once.
    public func scheduleDurableWatchlistRefresh() {
        durableWatchlistRefreshTask?.cancel()
        durableWatchlistRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.refreshDurableWatchlist()
        }
    }

    public func refreshDurableWatchlist() {
        guard case var .loaded(content) = state,
              let mediaItemActionHandler else { return }
        var candidates = content.watchlist
            + content.continueWatching
            + content.latest
        candidates += content.librarySections.flatMap {
            $0.sections.flatMap(\.items)
        }

        content.watchlist = Self.resolvedWatchlist(
            candidates: candidates,
            fetched: content.watchlist,
            lastKnown: content.watchlist,
            handler: mediaItemActionHandler
        )
        state = content.isEmpty ? .empty : .loaded(content)
        if !content.isEmpty { scheduleDurableWatchlistSave(content) }
    }

    /// The one policy for folding the durable watchlist into Home.
    ///
    /// Before the native view has loaded, the runtime contains only explicit
    /// Plozz intents. It is not an authoritative partial result: resolving
    /// against it downgraded 181 last-known titles to 78 unknown ones in both the
    /// constructor AND the first background aggregation, which is why gating the
    /// constructor alone still painted "+" on every launch.
    ///
    /// A saved Home row is the complete last-known presentation and wins during
    /// that startup window. On a genuine first run there is no saved row, so the
    /// freshly fetched provider row is the honest thing to show until native
    /// resolution is ready.
    static func resolvedWatchlist(
        candidates: [MediaItem],
        fetched: [MediaItem],
        lastKnown: [MediaItem],
        handler: (any MediaItemActionHandling)?
    ) -> [MediaItem] {
        guard let handler else { return fetched }
        guard handler.isDurableWatchlistPresentationReady() else {
            return lastKnown.isEmpty ? fetched : lastKnown
        }
        let resolved = handler.durableWatchlistItems(from: candidates)
        if resolved.isEmpty, !lastKnown.isEmpty { return lastKnown }
        return resolved
    }

    /// Persists Home's snapshot after a watchlist change, off the press.
    ///
    /// `contentStore.save` JSON-encodes every row and writes the file, on the
    /// main thread. Doing that inline meant one watchlist toggle paid for a full
    /// encode of Home before the next frame could be drawn, and a burst of
    /// presses paid for one per press — the interaction visibly stalled.
    ///
    /// The snapshot is only a warm start for next launch, so it does not have to
    /// be written during the gesture. Coalescing to the last change also means a
    /// burst writes once instead of once per press.
    private func scheduleDurableWatchlistSave(_ content: Content) {
        durableWatchlistSaveTask?.cancel()
        durableWatchlistSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            self.saveSnapshot(content)
        }
    }

    /// Last session's curated hero, ready to paint in the first frame.
    ///
    /// Deliberately unconditional on which sources are enabled: a hero that starts
    /// as a skeleton on every launch is the thing this exists to prevent. What
    /// makes it safe is ``HeroDurableSnapshot`` — re-applied here on the way out,
    /// not just on the way in, so a file written by a build that predates the rule
    /// (or by one whose enrichment added a resumable source ref afterwards) cannot
    /// repaint a stale playback position either.
    public func cachedHeroItems(for settings: HeroSettings) -> [MediaItem]? {
        guard settings.isActive else { return nil }
        guard let stored = contentStore.loadHero(
            for: HeroConfigurationKey(settings: settings)
        ) else { return nil }
        let durable = HeroDurableSnapshot.filter(stored)
        return durable.isEmpty ? nil : durable
    }

    public func cacheHeroItems(_ items: [MediaItem], for settings: HeroSettings) {
        guard settings.isActive, !items.isEmpty else { return }
        contentStore.saveHero(items, for: HeroConfigurationKey(settings: settings))
    }

    /// Discards the launch snapshot, for a curation that authoritatively found
    /// nothing. ``cacheHeroItems(_:for:)`` deliberately refuses to write an empty
    /// set — otherwise a failed refresh would erase a good snapshot — so running
    /// out of content needs to say so explicitly rather than by omission.
    public func clearCachedHeroItems() {
        contentStore.clearHero()
    }

    /// Targets a server has shown us since we last wrote to them, keyed like
    /// ``MediaSourceRef/id``.
    ///
    /// Turns "absent from the feed" — which on its own is ambiguous — into two
    /// distinguishable things. Before a server has acknowledged our write, absence
    /// means it has not caught up and the just-played card deserves to be carried.
    /// Once it has returned that card even once, the prediction is fulfilled, and a
    /// later absence is the server saying the title is gone: watched elsewhere, or
    /// dismissed in its own app. Without this distinction a title removed moments
    /// after being played stayed on the row until the carry window expired, which is
    /// the mirror of the bug the window exists to prevent.
    ///
    /// A fresh play removes its targets again, because that is a new prediction
    /// awaiting a new acknowledgement.
    private var serverConfirmedTargets: Set<String> = []

    /// Cards on the row that no server has returned yet — placed from a play we
    /// just made, or carried while a server catches up.
    ///
    /// They are shown, but never **persisted**. The launch snapshot exists to
    /// repaint what the servers last said, and writing a prediction into it makes
    /// the prediction self-sustaining: the next launch paints it, that painted row
    /// is what carry-forward inspects, and the durable write record it cites is
    /// still on disk — so the card re-carries itself indefinitely and survives even
    /// a force restart. Bounded prediction, unbounded persistence, and the
    /// persistence wins. Keeping them out of the snapshot is what bounds it.
    private var unconfirmedContinueWatchingIDs: Set<String> = []

    /// In-flight guard so a burst of resume ticks for a not-yet-loaded title
    /// coalesces into a single silent re-aggregation instead of stacking reloads.
    private var newResumeReloadInFlight = false

    /// The scope keys a mutation addresses. `scopedItemIDs` already carries the
    /// exact `(account, item)` pairs the fan-out targeted; the played card
    /// contributes its own servers so a merged title is fully covered.
    nonisolated static func mutationScopeKeys(_ mutation: MediaItemMutation, card: MediaItem?) -> Set<String> {
        // `scopedItemIDs` joins with ":", and an item id may itself contain one, so
        // split on the FIRST separator only — the account id never does.
        var keys = Set(mutation.scopedItemIDs.compactMap { scoped -> String? in
            guard let separator = scoped.firstIndex(of: ":") else { return nil }
            return String(scoped[scoped.startIndex..<separator])
                + "\u{1}"
                + String(scoped[scoped.index(after: separator)...])
        })
        if let card { keys.formUnion(scopeKeys(of: card)) }
        return keys
    }

    /// The scope keys a card answers to: every server that holds it, plus its own
    /// account-and-id pair for an unmerged single-source card.
    nonisolated static func scopeKeys(of item: MediaItem) -> Set<String> {
        var keys = Set(item.sources.map { $0.accountID + "\u{1}" + $0.itemID })
        if let account = item.sourceAccountID { keys.insert(account + "\u{1}" + item.id) }
        return keys
    }

    /// Persists the launch snapshot with predictions stripped out.
    ///
    /// What is on screen and what is worth repainting next launch are different
    /// questions. A card no server has confirmed is shown because we have good
    /// reason to expect it; it is not something to repaint from disk days later,
    /// when the reason has long since expired and no server ever agreed.
    private func saveSnapshot(_ content: Content) {
        guard !unconfirmedContinueWatchingIDs.isEmpty else {
            contentStore.save(content)
            return
        }
        var durable = content
        durable.continueWatching.removeAll { unconfirmedContinueWatchingIDs.contains($0.id) }
        contentStore.save(durable)
    }

    /// Recomputes which cards are on the row without any server having returned
    /// them, so the launch snapshot can leave them out. Replaces the set outright:
    /// a card the feed now carries has stopped being a prediction.
    private func noteUnconfirmed(reconciled: [MediaItem], fetched: [MediaItem]) {
        let confirmed = Set(fetched.map(\.id))
        unconfirmedContinueWatchingIDs = Set(
            reconciled.lazy.map(\.id).filter { !confirmed.contains($0) }
        )
    }

    /// Records that the servers have acknowledged these cards, so a later absence
    /// reads as a removal rather than as lag. See ``serverConfirmedTargets``.
    private func noteServerConfirmed(_ fetched: [MediaItem]) {
        for item in fetched { serverConfirmedTargets.formUnion(Self.scopeKeys(of: item)) }
    }

    /// Silently re-aggregates Home so a brand-new resume is backed by real server
    /// data as soon as the servers have it.
    ///
    /// This is now a follow-up rather than the way the title appears: the played
    /// card is placed on the row immediately by ``applyWatchedState(_:)``, because
    /// the app already has it and does not need to ask anyone. The reload exists so
    /// the placed card is reconciled with the server's own view (artwork, episode
    /// linkage, cross-server sources) once that view catches up.
    private func scheduleNewResumeReload() {
        guard !newResumeReloadInFlight, case .loaded = state else { return }
        newResumeReloadInFlight = true
        Task { [weak self] in
            guard let self else { return }
            await self.load(showLoadingState: false)
            self.newResumeReloadInFlight = false
        }
    }

    /// Overlays the durable watch-outbox's **not-yet-confirmed** mutations onto a
    /// freshly-fetched Continue Watching row, so a reload reflects what the user
    /// just played in-app even before every server's Resume/OnDeck query catches up.
    ///
    /// Matching is by **exact server target** — a pending mutation's
    /// `(accountID, itemID)` targets against each card's source refs (and the card's
    /// own `sourceAccountID:id` for un-merged single-source cards). No canonical-id
    /// recomputation: the outbox already addresses the precise server rows, so this
    /// can't accidentally re-merge unrelated titles.
    ///
    /// For each matched card, only when the pending action is at least as recent as
    /// the card's server-reported recency (older/superseded writes are ignored):
    ///  - a **finished** play (`played == true`) drops the card — a watched title
    ///    leaves Continue Watching, anticipating the server's own removal;
    ///  - an **in-progress** play (`resumePosition > 0`) stamps the card (and its
    ///    matching source refs) with the play's `capturedAt` recency + resume, so it
    ///    floats to the correct spot;
    ///  - anything else (e.g. a bare mark-*unwatched*) is left untouched — we never
    ///    fabricate recency for a non-play, nor invent a card out of nothing.
    ///
    /// **Carrying a just-played card (`carryForward`).** The server owns watch
    /// state and wins every disagreement — but only once it has actually heard us.
    /// A play produces two independent pieces of work, telling the server where the
    /// viewer stopped and asking it what is in progress, and nothing orders them;
    /// measured on device, the ask routinely wins and the server answers about a
    /// moment before the play. Dropping the card on that answer is how a title
    /// started from Search vanished until the app was relaunched.
    ///
    /// So a card already on screen is kept when the feed omits it, and **only**
    /// while there is concrete evidence the server has not caught up yet: a write
    /// still queued for it, or one applied within `carryForwardWindow`. Outside
    /// that the card goes, without exception — which is what stops this becoming
    /// the mirror bug, a title removed on another client that Plozz keeps showing
    /// forever. It is a short-lived prediction of what the server is about to say,
    /// never a second opinion about what is true.
    ///
    /// `carryForwardWindow` is deliberately **seconds**. It covers exactly one
    /// thing: the gap between a server accepting our write and reflecting it in
    /// its own resume feed, which takes a moment, not minutes. Being offline is a
    /// different condition and is already covered by the write still being queued.
    /// Anything longer is not patience, it is a licence to keep showing a title
    /// the viewer has removed — and someone will always reach for the server's own
    /// app, so that removal has to land whatever Plozz happens to be doing.
    ///
    /// The row is then re-sorted with the aggregator's exact recency comparator so
    /// the overlaid stamps take effect. Pure and side-effect-free for testability.
    ///
    /// **Drain-time inflation clamp (`appliedRecency`).** Some servers (Plex) stamp
    /// their own view timestamp on an out-of-band resume write and can't backdate it,
    /// so an *offline-queued* resume that drains late converges at the drain clock —
    /// re-floating a stale title to the top on the next reload even though nothing was
    /// re-watched. For each source we recently applied an in-progress resume to, this
    /// clamps that source's `lastPlayedAt` back **down** to the play's real
    /// `capturedAt` (recomputing the card's folded recency), but only while the record
    /// is fresh, so it can never override a genuine later play (e.g. on another
    /// client). Clamp-only-downward: worst case a card sits slightly lower, never
    /// wrongly at the top. (h2-cw-clamp)
    public nonisolated static func reconcileContinueWatching(
        _ items: [MediaItem],
        pending: [WatchMutation],
        appliedRecency: [String: AppliedResumeRecord] = [:],
        carryForward: [MediaItem] = [],
        serverConfirmed: Set<String> = [],
        now: Date = Date(),
        clampFreshness: TimeInterval = 30 * 60,
        carryForwardWindow: TimeInterval = 20
    ) -> [MediaItem] {
        guard !pending.isEmpty || !appliedRecency.isEmpty else { return items }

        func targetKey(_ accountID: String, _ itemID: String) -> String { accountID + "\u{1}" + itemID }
        let pendingByTarget: [String: [WatchMutation]] = pending.reduce(into: [:]) { acc, m in
            for t in m.targets { acc[targetKey(t.accountID, t.itemID), default: []].append(m) }
        }

        func newestMatch(for item: MediaItem) -> WatchMutation? {
            var keys = Set(item.sources.map { targetKey($0.accountID, $0.itemID) })
            if let account = item.sourceAccountID { keys.insert(targetKey(account, item.id)) }
            guard !keys.isEmpty else { return nil }
            var best: WatchMutation?
            for key in keys {
                for m in pendingByTarget[key] ?? [] where best == nil || m.capturedAt > best!.capturedAt {
                    best = m
                }
            }
            return best
        }

        var overlaid: [MediaItem] = []
        overlaid.reserveCapacity(items.count)
        for rawItem in items {
            // Undo any server drain-time timestamp inflation before the pending
            // overlay reads the card's recency, so an offline-drained Plex resume
            // can't leave a stale play floating at the top.
            let item = appliedRecency.isEmpty
                ? rawItem
                : clampInflatedRecency(rawItem, appliedRecency: appliedRecency, now: now, clampFreshness: clampFreshness)
            guard let m = newestMatch(for: item) else { overlaid.append(item); continue }
            // Ignore a pending write the server has already superseded with a newer play.
            guard m.capturedAt >= (item.lastPlayedAt ?? .distantPast) else { overlaid.append(item); continue }

            if m.played == true {
                // Finished / marked-watched: the title leaves Continue Watching.
                continue
            }
            guard let resume = m.resumePosition, resume > 0 else {
                // A non-play mutation (e.g. mark-unwatched) — don't reorder or drop.
                overlaid.append(item)
                continue
            }
            var updated = item
            updated.lastPlayedAt = m.capturedAt
            updated.resumePosition = resume
            let targetKeys = Set(m.targets.map { targetKey($0.accountID, $0.itemID) })
            updated.sources = updated.sources.map { ref in
                guard targetKeys.contains(targetKey(ref.accountID, ref.itemID)) else { return ref }
                var r = ref
                if (r.lastPlayedAt ?? .distantPast) < m.capturedAt { r.lastPlayedAt = m.capturedAt }
                r.resumePosition = resume
                return r
            }
            overlaid.append(updated)
        }
        overlaid.append(contentsOf: carriedForward(
            carryForward,
            fetched: items,
            pending: pending,
            appliedRecency: appliedRecency,
            serverConfirmed: serverConfirmed,
            now: now,
            window: carryForwardWindow
        ))
        return HomeAggregator.sortedByRecency(overlaid)
    }

    /// Cards on screen that the fresh feed left out, kept only while a write for
    /// them is still queued or landed within `window`.
    ///
    /// The window is what keeps the server authoritative. Our write is accepted in
    /// well under a second, so a feed that still omits the title minutes later is
    /// not lagging — it is telling us something (watched elsewhere, dismissed on
    /// another client) and it gets to be right.
    private nonisolated static func carriedForward(
        _ candidates: [MediaItem],
        fetched: [MediaItem],
        pending: [WatchMutation],
        appliedRecency: [String: AppliedResumeRecord],
        serverConfirmed: Set<String>,
        now: Date,
        window: TimeInterval
    ) -> [MediaItem] {
        guard !candidates.isEmpty else { return [] }
        func scopeKey(_ accountID: String, _ itemID: String) -> String { accountID + "\u{1}" + itemID }

        var present = Set<String>()
        for item in fetched {
            for source in item.sources { present.insert(scopeKey(source.accountID, source.itemID)) }
            if let account = item.sourceAccountID { present.insert(scopeKey(account, item.id)) }
        }
        // Writes still queued for a title — the server demonstrably has not seen it.
        var queued = Set<String>()
        for mutation in pending where (mutation.resumePosition ?? 0) > 0 && mutation.played != true {
            for target in mutation.targets { queued.insert(scopeKey(target.accountID, target.itemID)) }
        }
        // Writes that landed recently enough that the feed may not show them yet.
        var recentlyWritten = Set<String>()
        for (key, record) in appliedRecency where now.timeIntervalSince(record.appliedAt) <= window {
            // `appliedRecency` keys on "accountID:itemID"; re-key to the scoped form.
            guard let separator = key.firstIndex(of: ":") else { continue }
            recentlyWritten.insert(
                scopeKey(String(key[key.startIndex..<separator]), String(key[key.index(after: separator)...]))
            )
        }

        var carried: [MediaItem] = []
        for candidate in candidates {
            // Only ever carry something genuinely in progress. A finish is supposed
            // to leave the row, so its absence is the intended outcome.
            guard (candidate.resumePosition ?? 0) > 0 else { continue }
            var keys = Set(candidate.sources.map { scopeKey($0.accountID, $0.itemID) })
            if let account = candidate.sourceAccountID { keys.insert(scopeKey(account, candidate.id)) }
            guard !keys.isDisjoint(with: queued) || !keys.isDisjoint(with: recentlyWritten) else { continue }
            guard keys.isDisjoint(with: present) else { continue }
            // The server already acknowledged this write once. Its absence now is an
            // answer, not a lag, and it outranks anything we predicted.
            guard keys.isDisjoint(with: serverConfirmed) else { continue }
            carried.append(candidate)
        }
        if !carried.isEmpty {
            ContinueWatchingDiagnostics.emit(ContinueWatchingDiagnostics.carryForwardLine(
                titles: carried.map(\.title)
            ))
        }
        return carried
    }

    /// Pending in-progress plays that matched **no card** in the freshly fetched
    /// feed.
    ///
    /// ``reconcileContinueWatching`` may drop a card or restamp one, but it
    /// deliberately never invents one — it will not fabricate a row the feed did
    /// not return. That is the right call for correctness and it leaves a real
    /// gap: a title the viewer just started, which the server has not yet listed,
    /// has nowhere to be put. The row then stays silently wrong until some later
    /// refresh happens to catch the server up, which in practice is the next
    /// launch. Starting something from Search is the everyday way to hit this,
    /// because a title reached from Search is precisely one that was not already
    /// on the row.
    ///
    /// Naming those plays turns "nothing appeared" into an observation. Pure, so
    /// it is testable and costs nothing when diagnostics are off.
    public nonisolated static func unmatchedPendingTargets(
        in items: [MediaItem],
        pending: [WatchMutation]
    ) -> [String] {
        guard !pending.isEmpty else { return [] }
        func key(_ accountID: String, _ itemID: String) -> String { accountID + "\u{1}" + itemID }
        var present = Set<String>()
        for item in items {
            for source in item.sources { present.insert(key(source.accountID, source.itemID)) }
            if let account = item.sourceAccountID { present.insert(key(account, item.id)) }
        }
        var unmatched: [String] = []
        var seen = Set<String>()
        // Only in-progress plays: a finished one is *supposed* to be absent from
        // the row, so its absence is the correct outcome rather than a gap.
        for mutation in pending where (mutation.resumePosition ?? 0) > 0 && mutation.played != true {
            for target in mutation.targets {
                let target_key = key(target.accountID, target.itemID)
                guard !present.contains(target_key), seen.insert(target_key).inserted else { continue }
                unmatched.append("\(target.accountID):\(target.itemID)")
            }
        }
        return unmatched
    }

    /// Emits what the overlay did to one fetched feed. Gated; free when off.
    private nonisolated static func logOverlay(
        fetched: [MediaItem],
        reconciled: [MediaItem],
        pending: [WatchMutation]
    ) {
        guard ContinueWatchingDiagnostics.isEnabled else { return }
        ContinueWatchingDiagnostics.emit(ContinueWatchingDiagnostics.overlayLine(
            fetched: fetched.count,
            reconciled: reconciled.count,
            pending: pending.count,
            unmatched: unmatchedPendingTargets(in: fetched, pending: pending)
        ))
    }

    /// Clamps a card's server-reported recency **down** to the real play time for any
    /// source we recently applied an in-progress resume to, undoing a server's
    /// drain-time timestamp inflation (see ``reconcileContinueWatching``). Only fires
    /// while the record is fresh (`now − appliedAt ≤ clampFreshness`, device clock)
    /// and only when the server shows something newer than the true play — so it can
    /// never lower a genuine later play made elsewhere. Downward-only.
    nonisolated private static func clampInflatedRecency(
        _ item: MediaItem,
        appliedRecency: [String: AppliedResumeRecord],
        now: Date,
        clampFreshness: TimeInterval
    ) -> MediaItem {
        func recordKey(_ accountID: String, _ itemID: String) -> String { accountID + ":" + itemID }
        func freshCapture(_ accountID: String, _ itemID: String) -> Date? {
            guard let record = appliedRecency[recordKey(accountID, itemID)],
                  now.timeIntervalSince(record.appliedAt) <= clampFreshness else { return nil }
            return record.capturedAt
        }

        var updated = item
        if !updated.sources.isEmpty {
            var didClamp = false
            updated.sources = updated.sources.map { ref in
                guard let capturedAt = freshCapture(ref.accountID, ref.itemID),
                      let reported = ref.lastPlayedAt, reported > capturedAt else { return ref }
                didClamp = true
                var r = ref
                r.lastPlayedAt = capturedAt
                return r
            }
            guard didClamp else { return item }
            // Re-fold the card's recency from the clamped sources (most-recent-wins);
            // only ever lower it, never raise.
            if let folded = MediaItemMerger.unifiedWatchState(from: updated.sources).lastPlayedAt,
               folded < (updated.lastPlayedAt ?? .distantFuture) {
                updated.lastPlayedAt = folded
            }
            return updated
        }
        // Un-merged single-source card: no source refs, recency is on the item.
        if let account = item.sourceAccountID,
           let capturedAt = freshCapture(account, item.id),
           let reported = item.lastPlayedAt, reported > capturedAt {
            updated.lastPlayedAt = capturedAt
        }
        return updated
    }

    /// Reconciles the Watchlist row with a favorite mutation: removes titles that
    /// were un-favorited, and surfaces newly-favorited titles already present in
    /// another loaded row (so the row updates without a full reload). Non-favorite
    /// mutations only refresh the favorite flag on existing cards.
    private func updatedWatchlist(
        _ watchlist: [MediaItem],
        mutation: MediaItemMutation,
        in content: Content
    ) -> [MediaItem] {
        var updated = watchlist.map { apply(mutation, to: $0) }
        guard let favorite = mutation.favorite else { return updated }
        if favorite {
            // De-dup by (account, id), not bare id: a raw item id collides across
            // servers (two Plex servers can share a ratingKey), which would wrongly
            // suppress a genuine favorite that lives on a different server.
            // (r6-watchlist-bareid)
            func scopedKey(_ item: MediaItem) -> String { "\(item.sourceAccountID ?? ""):\(item.id)" }
            var seen = Set(updated.map(scopedKey))
            for candidate in (content.continueWatching + content.latest)
            where mutation.targets(candidate) && seen.insert(scopedKey(candidate)).inserted {
                var copy = candidate
                copy.isFavorite = true
                updated.insert(copy, at: 0)
            }
        } else {
            updated.removeAll { mutation.targets($0) }
        }
        return updated
    }

    /// Re-folds the *current* cross-server identity sources into the already-loaded
    /// rows **in place**, without a refetch. Invoked when the identity index warms
    /// further (a new account finishes indexing) so a card that cold-loaded before
    /// its local twin was known picks that twin up — which is what lets play-time
    /// selection route to the local (same-LAN) copy instead of a remote one.
    ///
    /// This mirrors ``HomeAggregator``'s row merge exactly: re-run the same
    /// identity/merge core over the loaded cards with the live `identitySources`
    /// closure (which reads the freshest snapshot) plus the accounts' server info.
    /// `MediaItemMerger.merge` is idempotent and order-stable over already-merged
    /// cards, so Continue Watching order — and therefore the user's focus — is
    /// preserved; only each card's `sources` set grows. Crucially it does **not**
    /// re-sort Continue Watching: the recency order is authoritative from load time
    /// and re-sorting the feed-less loaded row is what used to shuffle the row on
    /// every index warm. State is only republished when something actually changed,
    /// so a re-enrich that surfaces no new source is a true no-op (no view churn).
    public func reenrich() {
        guard case let .loaded(current) = state else { return }
        let serverInfoMap = accounts.sourceServerInfo()
        let resolve: (String) -> SourceServerInfo? = { serverInfoMap[$0] }
        let sources = identitySources

        var updated = current
        // Re-merge folds any newly-discovered cross-server sources into the loaded
        // cards. `MediaItemMerger.merge` is order-stable (first occurrence stays
        // primary), so the Continue Watching order the initial load computed is
        // preserved verbatim — we deliberately do NOT re-sort here. The recency sort
        // anchors untimestamped "Next Up" cards from a per-*feed* carry-forward that
        // only exists at load time (pre-interleave); re-sorting the interleaved,
        // feed-less loaded row is exactly what used to make Continue Watching "shift
        // around" on every background index warm. Enrich in place; never reorder.
        updated.continueWatching = MediaItemMerger.merge(current.continueWatching, serverInfo: resolve, identitySources: sources)
        updated.latest = MediaItemMerger.merge(current.latest, serverInfo: resolve, identitySources: sources)
        updated.watchlist = MediaItemMerger.merge(current.watchlist, serverInfo: resolve, identitySources: sources)

        // Republish only on a real change so an index warm that adds no new source
        // to any visible card doesn't churn the view or disturb focus.
        guard updated != current else { return }
        state = .loaded(updated)
    }

    /// Coalesced entry point for the `identityIndexDidUpdate` notification. The
    /// index publishes once per warmed account, so on a multi-server boot this
    /// fires in a tight burst; debouncing collapses it to a single ``reenrich()``
    /// once the burst settles, avoiding O(accounts × rows) redundant main-actor
    /// merges. A prior pending pass is cancelled so only the latest snapshot is
    /// folded. Callers that need a synchronous fold (tests, explicit refresh) call
    /// ``reenrich()`` directly.
    public func scheduleReenrich(
        onSettled: @escaping @MainActor () -> Void = {}
    ) {
        reenrichTask?.cancel()
        reenrichTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reenrichDebounce)
            guard !Task.isCancelled, let self else { return }
            self.reenrich()
            onSettled()
        }
    }

    /// Current durable watched/unwatched intents, projected into the same
    /// optimistic mutation shape visible surfaces already consume.
    public func pendingHeroWatchMutations() async -> [MediaItemMutation] {
        let pending = await pendingWatchMutations()
        return pending
            .sorted { $0.capturedAt < $1.capturedAt }
            .compactMap(MediaItemMutation.init(watchMutation:))
    }

    private func apply(_ mutation: MediaItemMutation, to item: MediaItem) -> MediaItem {
        mutation.applied(to: item)
    }
}
