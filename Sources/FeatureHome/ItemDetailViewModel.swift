import Foundation
import Observation
import CoreModels
import CoreNetworking
import MetadataKit
import RatingsService
import ProviderTrailers

/// Loads full detail for an item plus its children (episodes/seasons), and
/// asynchronously enriches it with external ratings (IMDb/RT/Metacritic).
@MainActor
@Observable
public final class ItemDetailViewModel {
    public struct Detail: Equatable, Sendable {
        public var item: MediaItem
        public var children: [MediaItem]
        /// True once the children fetch has completed (so an empty `children` can
        /// be distinguished from "still loading"). Leaf items — which never have
        /// children — are considered loaded immediately.
        public var childrenLoaded: Bool = false
    }

    public private(set) var state: LoadState<Detail> = .idle

    /// Playable trailers for this item, loaded alongside detail. Empty until
    /// resolved (and when the backend has none). Each is tagged with this
    /// detail's owning account so it routes back to the right provider.
    public private(set) var trailers: [MediaItem] = []

    /// Episodes for each season of a series, loaded lazily the first time a
    /// season is shown/focused and cached so re-focusing a tab is instant. Keyed
    /// by season id. Observed by `SeriesDetailView` to populate its episode rail.
    public private(set) var seasonEpisodes: [String: [MediaItem]] = [:]
    private var loadingSeasons: Set<String> = []
    /// Episode ids whose badges have already been enriched from a full per-item
    /// fetch (see ``enrichEpisodeBadgesIfNeeded(_:)``) so the focused-episode hero
    /// never re-fetches the same episode while the user browses a rail.
    private var enrichedEpisodeIDs: Set<String> = []
    /// When this detail is a series, context propagated onto its episodes so each
    /// episode resolves fallback artwork/routing with full series metadata.
    private var seriesEpisodeContext: SeriesEpisodeContext?

    /// When the requested item was a season, the id of that season. A season
    /// never renders its own page — `load()` transparently redirects to the
    /// parent series, and the series page uses this to pre-select the season the
    /// user actually tapped. `nil` for non-season loads.
    public private(set) var preselectedSeasonID: String?

    private let provider: any MediaProvider
    private let itemID: String
    private let ratingsProvider: any ExternalRatingsProviding
    /// A **discovery** item (a Seerr/Overseerr title that may not be in any
    /// library). Its synthetic `seer:<tmdbId>` id isn't resolvable through a
    /// `MediaProvider`, so `load()`/`reload()` skip the provider fetch and every
    /// library-only enrichment (children, trailers, ratings, cross-server) and
    /// simply keep the seeded `initialItem` — which already carries the TMDB
    /// artwork + overview the discovery detail page shows.
    private let isDiscoveryItem: Bool
    /// For a discovery item, fetches its current request/availability + download
    /// progress from Seerr (by TMDB id). Called on every `load()` so reopening a
    /// title requested in an earlier visit reflects the real "Requested"/
    /// "Downloading" state instead of the stale "Request" seeded from the search
    /// result. `nil` (or a `nil` result) leaves the seeded state untouched.
    private let discoveryStatusRefresh: (@Sendable (MediaItem) async -> (MediaAvailabilityStatus, Double?)?)?

    /// The currently *active* source the page is showing. Defaults to the base
    /// `provider`/`itemID`/`sourceAccountID` the page was opened with, but is
    /// re-pointed by ``switchToSource(accountID:)`` so a **series** can switch to
    /// another server's copy IN PLACE (reloading that server's seasons/episodes)
    /// without pushing a new navigation entry. All loads/fetches/tagging/snapshot
    /// keying go through these, never the immutable base, so an in-place switch
    /// re-keys cleanly. The base lets are kept so the page's original identity is
    /// recoverable and the documented immutability of the opened source holds.
    private var activeProvider: any MediaProvider
    private var activeItemID: String
    private var activeSourceAccountID: String?
    /// Resolves a keyless online trailer (public YouTube front-ends), used only
    /// when the provider surfaces no local or server trailer. Injectable so tests
    /// can avoid the network.
    private let onlineTrailerResolver: OnlineTrailerResolving
    /// Verifies which (if any) of an ordered list of YouTube video ids actually
    /// resolves to a playable **public** stream, returning the first that does.
    /// Used to decide whether to show the Trailer button at all — a dead server
    /// trailer link with no playable replacement yields no button. Injectable so
    /// tests stay off the network.
    private let playableVideoIDResolver: PlayableTrailerResolving
    /// Memo of trailer-resolution outcomes so a revisited detail page surfaces its
    /// Trailer button instantly instead of re-running extraction/search. Injected
    /// so tests can supply an isolated cache.
    private let trailerCache: TrailerResolutionCache
    /// The account this item belongs to, propagated so the detail item and its
    /// children stay tagged with their owning provider as the user drills down
    /// (children come from the provider untagged). `nil` outside aggregated flows.
    private let sourceAccountID: String?

    /// The **origin** server this detail was opened from, when that origin should
    /// drive the default source.
    ///
    /// Set only when the detail was reached from a single specific server's
    /// **library tile** (browse): the cross-server picker uses *this* account as a
    /// **soft** tie-break — its copy wins only among otherwise-equal candidates,
    /// never over a more-local or higher-quality copy (the user can still switch).
    /// `nil` for titles opened from the cross-server-merged Home/Search rows, which
    /// keep the smart best default. See
    /// ``CrossSourceSelector/bestSelection(from:capabilities:preferring:)``.
    public let originSourceAccountID: String?

    /// The cross-server sources of this (possibly merged) title, threaded in from
    /// the merged card so the detail page can offer a **server picker** and play
    /// from any server. Empty for a single-server item. The primary source's
    /// versions/watch-state are seeded from the loaded detail; alternates are
    /// enriched off the critical path (see ``enrichAlternateSources``).
    private let initialSources: [MediaSourceRef]
    /// Resolves an account id to its provider so alternate-server copies can be
    /// fetched for their versions/watch-state. Returns `nil` for unknown accounts
    /// (e.g. a server signed out since the merge).
    private let alternateProviderResolver: (String) -> (any MediaProvider)?

    /// Discovers *other servers* that host this same title and returns the unified
    /// cross-server source list (primary first), so a title surfaced from a single
    /// server (e.g. a Home row that only one server put in "Recently Added") still
    /// gets a server picker. Given the loaded primary item it searches the other
    /// accounts, merges by ``MediaItemIdentity``, and returns every matching
    /// server's ``MediaSourceRef``. `nil` outside multi-account flows. Runs off the
    /// critical path of first paint.
    private let crossServerSourceResolver: (@Sendable (MediaItem) async -> [MediaSourceRef])?

    /// The enriched per-server sources for this title, primary first. Drives the
    /// detail server picker; each entry's `versions` fill in as alternate servers
    /// resolve. Empty for a single-server title (no picker shown).
    public private(set) var sources: [MediaSourceRef] = []
    /// In-flight enrichment pass for alternate sources. Kept cancellable so a
    /// reload/navigation change can drop stale work promptly.
    // `nonisolated(unsafe)` so the nonisolated `deinit` can cancel these handles.
    // Every mutation happens on the main actor (cancel-and-replace inside isolated
    // methods); `deinit` only runs once the last reference is gone, so there is no
    // concurrent access. `Task` is Sendable, so cancelling is safe from anywhere.
    private nonisolated(unsafe) var alternateSourceEnrichmentTask: Task<Void, Never>?
    /// In-flight cross-server discovery pass (search other accounts for this
    /// title). Cancellable so a reload/navigation change drops stale work.
    private nonisolated(unsafe) var crossServerDiscoveryTask: Task<Void, Never>?
    /// Off-critical-path restore of the persisted snapshot. Raced against the live
    /// `provider.item(id:)` fetch so first paint is NEVER gated on a (possibly
    /// disk-contended) snapshot read — it only paints/enriches if it wins and
    /// never downgrades a fresher render. Cancelled on each new load.
    private nonisolated(unsafe) var snapshotRestoreTask: Task<Void, Never>?
    /// Set once the live fetch publishes fresh detail, so a late snapshot restore
    /// never clobbers a fresher hero.
    private var hasPaintedFreshDetail = false
    /// Guards the one-time initial locality retarget in ``load()`` so it runs at
    /// most once and can never override a later user server switch. Set the first
    /// time `load()` evaluates the preference, and eagerly by ``switchToSource``
    /// so an explicit pick is always authoritative.
    private var didApplyInitialLocalityPreference = false
    /// Set once the user explicitly picks a server via ``switchToSource`` so the
    /// automatic post-discovery locality retarget (``retargetToMostLocalSourceAfterDiscovery``)
    /// can never override their choice.
    private var userDidSwitchSource = false
    /// Coalesces snapshot writes to AT MOST one in flight per view model: a burst
    /// of state changes (children arrive, episodes prewarm, cross-server discovery,
    /// alternate-source updates) used to each fire a full-snapshot encode+write,
    /// flooding the cache's I/O queue and starving the NEXT page's snapshot read
    /// for many seconds. Cancel-and-replace + a short debounce collapses the burst
    /// into a single write of the latest snapshot.
    private nonisolated(unsafe) var pendingSnapshotWrite: Task<Void, Never>?
    /// Bound concurrent alternate-server detail fetches to keep Home-opened
    /// details responsive and avoid saturating startup/network image traffic.
    private static let alternateSourceFanoutLimit = 3

    /// True when running inside an XCTest host. The speculative-work dwell gates
    /// below are wall-clock timers that exist purely to suppress work during
    /// rapid on-device navigation churn; under tests they would only add (and
    /// race) multi-second delays, so they collapse to zero and the enrichment
    /// runs deterministically — exactly the behavior these suites assert.
    private static let isRunningUnderTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Dwell before any speculative discovery fan-out (cross-server discovery,
    /// alternate-source fetch) fires. A page tapped through in under this window
    /// pays zero speculative cost. Zero under tests. (Trailer extraction has its
    /// own dwell on the awaited path — see ``trailerExtractionDwellNanos``.)
    private static var enrichmentDwellNanos: UInt64 { isRunningUnderTests ? 0 : 800_000_000 }

    /// Further dwell before the authoritative YouTubeKit/JavaScriptCore trailer
    /// extraction (the single biggest CPU consumer during browsing) runs, so only
    /// a page genuinely settled on pays it. Zero under tests.
    private static var trailerExtractionDwellNanos: UInt64 { isRunningUnderTests ? 0 : 1_700_000_000 }

    /// In-flight SPECULATIVE discovery (cross-server picker + alternate-source
    /// watch-state), owned as a cancellable task that `load()` does NOT await.
    /// Decoupling it from `load()` means a navigate-away (which cancels via
    /// ``suspendEnrichment()``) stops the multi-server search fan-out from running
    /// to completion on the next page's back — the cooperative-pool starvation
    /// that left a freshly-opened detail's `provider.item` unscheduled for 15–20s
    /// after tapping through several titles. Trailers + ratings, by contrast, are
    /// awaited on the `load()` path (see ``runTrailersAndRatings(for:)``).
    private nonisolated(unsafe) var enrichmentTask: Task<Void, Never>?
    /// The fully-loaded item enrichment is keyed to, so a page returned to (popped
    /// back onto) can resume the speculative discovery that was suspended on
    /// disappear.
    private var enrichmentItem: MediaItem?
    /// Set once speculative discovery (alternate sources + cross-server) has been
    /// kicked off, so resuming on reappear doesn't restart already-running work.
    private var enrichmentComplete = false
    /// This page's ``EnrichmentScheduler`` generation token. Stamped when the page
    /// becomes the active detail; the scheduler drops any background work tagged
    /// with an older token before it hits the network, so tapping quickly through
    /// titles collapses to just the page landed on instead of piling a dozen
    /// cross-server search fan-outs onto the cooperative pool.
    private var enrichmentGeneration: UInt64 = 0

    /// Persistent stale-while-revalidate store of this title's resolved detail
    /// (item + children + episodes + cross-server sources). On a revisit `load()`
    /// paints the last-known snapshot instantly, then refreshes it from the
    /// network — so a show you've opened before never shows a cold spinner.
    private let snapshotCache: DetailSnapshotCache
    /// Stable per-title key for ``snapshotCache``. Scoped by owning account so the
    /// same id on two servers caches independently. All routes to a series share a
    /// key (they're all built with the series id as `itemID`).
    private var snapshotKey: String { "\(activeSourceAccountID ?? "_")|\(activeItemID)" }

    public init(
        provider: any MediaProvider,
        itemID: String,
        initialItem: MediaItem? = nil,
        isDiscoveryItem: Bool = false,
        discoveryStatusRefresh: (@Sendable (MediaItem) async -> (MediaAvailabilityStatus, Double?)?)? = nil,
        ratingsProvider: any ExternalRatingsProviding = DisabledRatingsProvider(),
        sourceAccountID: String? = nil,
        originSourceAccountID: String? = nil,
        onlineTrailerResolver: @escaping OnlineTrailerResolving = ItemDetailViewModel.defaultOnlineTrailerResolver,
        playableVideoIDResolver: @escaping PlayableTrailerResolving = ItemDetailViewModel.defaultPlayableVideoIDResolver,
        trailerCache: TrailerResolutionCache = .shared,
        initialSources: [MediaSourceRef] = [],
        alternateProviderResolver: @escaping (String) -> (any MediaProvider)? = { _ in nil },
        crossServerSourceResolver: (@Sendable (MediaItem) async -> [MediaSourceRef])? = nil,
        snapshotCache: DetailSnapshotCache = .ephemeral
    ) {
        self.provider = provider
        self.itemID = itemID
        self.activeProvider = provider
        self.activeItemID = itemID
        self.isDiscoveryItem = isDiscoveryItem
        self.discoveryStatusRefresh = discoveryStatusRefresh
        // Fall back to the library-origin account when a direct source tag is
        // absent, so a played item is always attributed to the account it was
        // browsed from (a local media share persists resume/played state keyed by
        // this id — dropping it silently routes the write to the primary server
        // instead, which is why a share's resume never survived a relaunch).
        self.activeSourceAccountID = sourceAccountID ?? originSourceAccountID
        self.ratingsProvider = ratingsProvider
        self.sourceAccountID = sourceAccountID
        self.originSourceAccountID = originSourceAccountID
        self.onlineTrailerResolver = onlineTrailerResolver
        self.playableVideoIDResolver = playableVideoIDResolver
        self.trailerCache = trailerCache
        self.initialSources = initialSources
        self.alternateProviderResolver = alternateProviderResolver
        self.crossServerSourceResolver = crossServerSourceResolver
        self.snapshotCache = snapshotCache

        // Seed the hero from the list item the user just tapped so the detail
        // screen's first paint is INSTANT — before `provider.item(id:)` returns.
        // `load()` then swaps in the fully-detailed item (and children/ratings)
        // in place without ever dropping back to a loading/skeleton state.
        if let initialItem {
            let seeded = sourceAccountID.map(initialItem.taggingSource) ?? initialItem
            self.state = .loaded(Detail(item: seeded, children: []))
        }
    }

    /// Production online-trailer resolver: a keyless YouTube search (no API key,
    /// no TMDb) that surfaces ranked official-trailer candidates for the title.
    public static let defaultOnlineTrailerResolver: OnlineTrailerResolving = { item in
        await OnlineTrailerSource.trailers(for: item)
    }

    /// Production playability verifier: extracts via YouTubeKit (in
    /// `ProviderTrailers`) and returns the first candidate that yields a playable
    /// public stream, skipping any private/removed video.
    public static let defaultPlayableVideoIDResolver: PlayableTrailerResolving = { candidates in
        await YouTubeTrailerProvider.firstPlayableVideoID(in: candidates)
    }

    /// Cancels every piece of owned background work so no detached/async task can
    /// outlive the view model. The view's `onDisappear` already calls
    /// ``suspendEnrichment()``, but a view model torn down without that hook
    /// (navigation pop under memory pressure, a unit test that just lets the
    /// instance fall out of scope) would otherwise leak its in-flight tasks —
    /// they keep occupying the cooperative pool, fire state mutations after the
    /// page is gone, and in tests outlive the case and trip the simulator
    /// watchdog. `Task.cancel()` is safe to call from this non-isolated `deinit`.
    deinit {
        enrichmentTask?.cancel()
        crossServerDiscoveryTask?.cancel()
        alternateSourceEnrichmentTask?.cancel()
        snapshotRestoreTask?.cancel()
        pendingSnapshotWrite?.cancel()
    }

    public func load() async {
        // Discovery (Seerr) items aren't backed by a resolvable library provider,
        // so the library fetch below would only 404. Instead of the fetch, refresh
        // the title's request/availability state from Seerr (so a reopened title
        // reflects a request made earlier) and keep the seeded item otherwise.
        guard !isDiscoveryItem else {
            await refreshDiscoveryStatus()
            return
        }
        alternateSourceEnrichmentTask?.cancel()
        alternateSourceEnrichmentTask = nil
        enrichmentTask?.cancel()
        enrichmentTask = nil
        crossServerDiscoveryTask?.cancel()
        crossServerDiscoveryTask = nil
        hasPaintedFreshDetail = false

        // Before the very first fetch, retarget a cross-server-merged Home/Search
        // open onto its most-local copy (see doc on the method): a SERIES loads
        // its whole tree from ONE server and its per-server episodes can't
        // cross-server re-select at play time, so the initial server MUST be the
        // local one or every episode streams from a remote/Tailscale merge-primary.
        applyInitialLocalityPreferenceIfNeeded()

        // Stale-while-revalidate restore, RACED OFF THE CRITICAL PATH. The snapshot
        // read used to be the FIRST await in load() — so a disk-contended read (the
        // cache I/O queue saturated by other pages' snapshot writes) blocked the
        // live `provider.item(id:)` fetch from even starting, leaving the page blank
        // for as long as the read was starved. Now the read runs in its own task: it
        // paints the cached hero/seasons/picker only if it arrives before fresh
        // detail and never downgrades a fresher render, while the live fetch below
        // proceeds immediately and drives first paint regardless of the cache.
        snapshotRestoreTask?.cancel()
        let restoreKey = snapshotKey
        let restoreCache = snapshotCache
        snapshotRestoreTask = Task { [weak self] in
            guard let snapshot = await restoreCache.snapshot(for: restoreKey) else { return }
            guard let self, !Task.isCancelled else { return }
            self.applySnapshotIfNotStale(snapshot)
        }

        // Cold open (no seeded hero) shows a spinner immediately instead of blank.
        if state.value == nil { state = .loading }
        do {
            var fetched = try await activeProvider.item(id: activeItemID)
            try Task.checkCancellation()
            fetched = await redirectingSeasonToSeries(fetched)
            try Task.checkCancellation()
            captureSeriesContext(from: fetched)
            // Immutable snapshot so the concurrent async-lets below capture a
            // Sendable value (Swift 6 strict-concurrency forbids capturing
            // mutated `var`s into concurrently-executing code).
            let item = fetched
            let taggedItem = tagged(item)

            // Container kinds (series/season/folder/collection) have children
            // to list; leaf items (movies, episodes, videos) don't.
            let needsChildren: Bool
            switch item.kind {
            case .series, .season, .folder, .collection: needsChildren = true
            default: needsChildren = false
            }

            // Publish the full-detail hero IMMEDIATELY so first paint isn't gated
            // on the children round-trip. This also replaces any lighter seeded
            // list item with the richer fetched one in place (same identity ⇒ no
            // flicker). For container kinds the children rail starts empty and
            // fills in below; for leaf kinds the empty list is final.
            if needsChildren {
                // Containers (series/season/folder/collection): publish the
                // full-detail hero IMMEDIATELY (carrying whatever children we have
                // already — usually none on a cold open) so the hero backdrop,
                // title logo and overview are NOT gated on the children round-trip.
                // A remote server with a large episode list (e.g. a long anime
                // series on someone else's Jellyfin) could otherwise leave the hero
                // blank for many seconds while `children(of:)` runs. SeriesDetailView
                // re-latches its selected season + episodes + Play target via
                // `.task(id: seasons.map(\.id))` the moment the children arrive —
                // exactly as it already does for a seeded open — so an empty-children
                // first paint is safe and never strands the season picker.
                let seededChildren = state.value?.children ?? []
                state = .loaded(Detail(item: taggedItem, children: seededChildren, childrenLoaded: state.value?.childrenLoaded ?? false))
                hasPaintedFreshDetail = true
                seedSources(from: taggedItem)
                // Speculative discovery (cross-server picker + alternate-source
                // watch-state) runs as a CANCELLABLE unit that `load()` does NOT
                // await — so navigating away cancels it instead of letting the
                // multi-server search fan-out starve the next page's `provider.item`.
                startSpeculativeEnrichment(for: item)
                // Children fill in off the critical path of first paint; merge them
                // in (same item identity ⇒ no hero flicker) when they arrive.
                let fetchedChildren = (try? await activeProvider.children(of: item.id)) ?? []
                try Task.checkCancellation()
                state = .loaded(Detail(item: taggedItem, children: fetchedChildren.map(tagged), childrenLoaded: true))
                persistSnapshot()
                // Trailers + ratings ARE awaited: opening a detail deterministically
                // populates its Trailer button and rating badges. Cancelled with
                // load() on navigate-away; heavy trailer extraction is dwell-gated.
                await runTrailersAndRatings(for: item)
            } else {
                // Leaf kinds (movie/episode/video): the hero IS the content, so
                // publish it immediately, then load trailers/ratings off the
                // critical path of first paint.
                state = .loaded(Detail(item: taggedItem, children: [], childrenLoaded: true))
                hasPaintedFreshDetail = true
                seedSources(from: taggedItem)
                persistSnapshot()
                // See container branch: speculative discovery is cancellable and
                // NOT awaited (a navigate-away drops it), while trailers + ratings
                // ARE awaited so the Trailer button / rating badges populate
                // deterministically before load() returns.
                startSpeculativeEnrichment(for: item)
                await runTrailersAndRatings(for: item)
            }
        } catch is CancellationError {
            // Back-button during load: leave whatever state we already published
            // (seeded hero, full hero, or .loading) — never flash a failure for a
            // clean cancel.
            return
        } catch let error as AppError {
            // Don't bury an already-painted hero under a full-screen error just
            // because the detail re-fetch failed; the seeded hero stays usable.
            if state.value == nil { state = .failed(error) }
        } catch {
            if state.value == nil { state = .failed(.unknown("")) }
        }
    }

    /// Refreshes a discovery (Seerr) title's request/availability + download
    /// progress from Seerr on (re)open, so a title requested in an earlier visit
    /// shows "Requested"/"Downloading" rather than a stale "Request" seeded from
    /// the search result. The seeded item is kept untouched on any failure, and the
    /// state is only republished when something actually changed (no needless
    /// re-render / focus churn).
    private func refreshDiscoveryStatus() async {
        guard let current = state.value?.item else {
            if state.value == nil { state = .empty }
            return
        }
        guard let discoveryStatusRefresh,
              let (availability, downloadProgress) = await discoveryStatusRefresh(current),
              !Task.isCancelled
        else { return }
        guard current.availability != availability || current.downloadProgress != downloadProgress else { return }
        var updated = current
        updated.availability = availability
        updated.downloadProgress = downloadProgress
        state = .loaded(Detail(item: updated, children: [], childrenLoaded: true))
    }

    /// A season must never render a page of its own. When the fetched item is a
    /// season with a resolvable parent series, transparently swap it for that
    /// series (remembering the season in `preselectedSeasonID` so the series page
    /// opens on it). Returns the item unchanged for non-seasons, or when the
    /// parent series can't be resolved. This guarantees that tapping a season
    /// anywhere — Recently Added, Search, a deep link — lands on the rich series
    /// page, never a standalone season page.
    private func redirectingSeasonToSeries(_ item: MediaItem) async -> MediaItem {
        guard item.kind == .season,
              let seriesID = item.seriesID,
              let series = try? await activeProvider.item(id: seriesID) else {
            preselectedSeasonID = nil
            return item
        }
        preselectedSeasonID = item.id
        return series
    }

    /// Already-loaded episodes for `seasonID`, or `nil` if not yet fetched.
    public func episodes(for seasonID: String) -> [MediaItem]? {
        seasonEpisodes[seasonID]
    }

    /// Starts the SPECULATIVE off-critical-path enrichment for `item` as
    /// cancellable work: cross-server server-picker discovery and alternate-source
    /// watch-state. Crucially `load()` does NOT await this — so navigating away
    /// (which cancels via ``suspendEnrichment()``) drops the multi-server search
    /// fan-out the instant the user leaves, instead of letting it run to
    /// completion and starve the next page's `provider.item` for the cooperative
    /// thread pool.
    ///
    /// Trailers and external ratings are NOT started here: those resolve on the
    /// awaited `load()` path (see ``runTrailersAndRatings(for:)``) so that opening
    /// a detail deterministically populates its Trailer button and rating badges,
    /// while this speculative discovery stays decoupled and droppable.
    private func startSpeculativeEnrichment(for item: MediaItem) {
        enrichmentItem = item
        enrichmentComplete = false
        enrichmentTask?.cancel()
        crossServerDiscoveryTask?.cancel()
        alternateSourceEnrichmentTask?.cancel()
        let taggedItem = tagged(item)
        enrichmentTask = Task(priority: .utility) { [weak self] in
            // Umbrella dwell gate: opening a page and immediately leaving (the
            // navigation-churn pattern) must fire ZERO speculative enrichment —
            // no cross-server search fan-out, no alternate-source fetch, no
            // JavaScriptCore trailer extraction. All of that is work for a page the
            // user is actually looking at, not one they're tapping through. A short
            // cancellable wait here means a sub-second open→back does nothing at
            // all; the first-paint detail (driven by load(), not this task) has
            // already shown. Cancelled by suspendEnrichment on navigate-away.
            // Skipped entirely (not merely zero-length) under tests so enrichment
            // is deterministic with no spurious suspension point.
            if Self.enrichmentDwellNanos > 0 {
                try? await Task.sleep(nanoseconds: Self.enrichmentDwellNanos)
                guard !Task.isCancelled else { return }
            }
            // Bump the GLOBAL enrichment generation: opening this page makes every
            // older page's still-in-flight discovery/alternate work stale, so the
            // scheduler drops it BEFORE it touches the network. This is what stops
            // rapid tap-through from piling a dozen cross-server search fan-outs
            // onto the small cooperative pool and freezing it (timeouts and
            // cancellation stop firing once the pool is saturated, so the flood
            // must be prevented at the source, not bounded after the fact).
            let token = await EnrichmentScheduler.shared.bumpGeneration()
            guard let self, !Task.isCancelled else { return }
            self.enrichmentGeneration = token
            self.startAlternateSourceEnrichment(primaryID: item.id)
            self.startCrossServerDiscovery(for: taggedItem)
            self.enrichmentComplete = true
        }
    }

    /// Resolves trailers and external ratings concurrently on the awaited `load()`
    /// path, so opening a detail deterministically populates its Trailer button
    /// and rating badges before `load()` returns. Cancellable via the awaiting
    /// task: a navigate-away cancels `load()`, which cancels this mid-flight (the
    /// guards below bail) instead of letting YouTube extraction / a ratings fetch
    /// run to completion on the next page's back. The heavy trailer extraction is
    /// additionally gated behind a cancellable dwell (see ``loadTrailers(for:)``)
    /// so rapid tap-through never pays it.
    private func runTrailersAndRatings(for item: MediaItem) async {
        async let trailersDone: Void = loadTrailers(for: item)
        async let ratingsDone: Void = enrichRatings(for: item)
        async let overviewDone: Void = enrichOverview(for: item)
        _ = await trailersDone
        _ = await ratingsDone
        _ = await overviewDone
    }

    /// Cancels ALL off-critical-path enrichment (trailers, ratings, cross-server
    /// discovery, alternate-source fetches) for this page. Called from the detail
    /// view's `onDisappear` — when the user navigates away the work must stop so
    /// it cannot keep occupying the cooperative thread pool and starve the NEXT
    /// page's `provider.item` (the multi-second blank-detail hang).
    public func suspendEnrichment() {
        enrichmentTask?.cancel(); enrichmentTask = nil
        crossServerDiscoveryTask?.cancel(); crossServerDiscoveryTask = nil
        alternateSourceEnrichmentTask?.cancel(); alternateSourceEnrichmentTask = nil
    }

    /// Resumes enrichment for a page returned to (popped back onto) whose work was
    /// suspended on disappear. No-op during the initial load (which `load()`
    /// drives), for a page still loading, or once enrichment finished — so it
    /// never double-starts or races `load()`.
    public func resumeEnrichmentIfNeeded() {
        guard hasPaintedFreshDetail, !enrichmentComplete, enrichmentTask == nil,
              let item = enrichmentItem else { return }
        startSpeculativeEnrichment(for: item)
    }

    /// Fetches the item's trailers off the critical path. The Trailer button is
    /// surfaced **fast** (optimistically, from the server's own trailer id) and
    /// the verified, actually-playable id is refined in the background — so the
    /// button appears in well under a second instead of waiting 5–10s for the full
    /// extract → byte-check → keyless-search chain to finish.
    ///
    /// Flow:
    ///  1. A local server trailer file wins outright (a real asset, no network).
    ///  2. A cached outcome for this item (working id or "none") applies instantly.
    ///  3. Otherwise, if the server has a remote (YouTube) trailer id, show the
    ///     button **immediately** from it, then verify in the same pass: refine to
    ///     the first id that actually plays, search for a replacement when the
    ///     server ids are all dead, and retract only when nothing plays at all.
    ///  4. With no server id, a keyless search decides whether to show a button.
    ///
    /// The verified outcome is cached so revisiting the page is instant, and the
    /// player's own primary→alternatives→error fallback means an optimistic button
    /// self-heals at tap time rather than ever being a dead end.
    private func loadTrailers(for item: MediaItem) async {
        guard !Task.isCancelled else { return }
        let provided = (try? await activeProvider.trailers(for: item.id)) ?? []
        guard !Task.isCancelled else { return }

        // 1) A real local trailer file wins outright — no network verification.
        if let local = provided.first(where: { !$0.isYouTubeTrailer }) {
            guard isStillLoaded(item) else { return }
            trailers = [tagged(local)]
            return
        }

        let serverIDs = orderedUnique(provided.compactMap(\.youTubeTrailerVideoID))

        // 2) A cached decision applies instantly — the main reason a revisited page
        //    no longer re-pays the extraction/search cost.
        if let cached = trailerCache.outcome(for: item.id) {
            guard isStillLoaded(item) else { return }
            switch cached {
            case .working(let id): surfaceTrailer(videoID: id, for: item)
            case .none: trailers = []
            }
            return
        }

        // 3) Optimistically show the button from the server's first trailer id
        //    while verification runs, so it isn't gated on the network.
        if let optimistic = serverIDs.first {
            surfaceTrailer(videoID: optimistic, for: item)
        }

        // Dwell gate: the authoritative verify/replace pass below runs YouTubeKit's
        // JavaScriptCore stream extraction, which is heavy (a JSContext executing
        // YouTube's player JS) and the single biggest CPU consumer during browsing.
        // This dwell means roughly 1.7s of continuous settle on ONE page before any
        // trailer JS runs — so even "pause to look at it load" browsing never
        // triggers extraction, only a page the user has genuinely settled on. The
        // optimistic button above has already appeared, so this never delays what
        // the user sees. trailers run on the awaited load() path, so a navigate-away
        // cancels load() — and this dwell with it (the guard below bails). Skipped
        // under tests so the (injected, instant) verify/search pass is deterministic.
        if Self.trailerExtractionDwellNanos > 0 {
            try? await Task.sleep(nanoseconds: Self.trailerExtractionDwellNanos)
            guard !Task.isCancelled, isStillLoaded(item) else { return }
        }

        // Verify (authoritative): refine to the first server id that actually
        // plays, else search for a replacement, then cache the outcome.
        var workingID = await playableVideoIDResolver(serverIDs)
        guard !Task.isCancelled else { return }
        if workingID == nil {
            let searchIDs = orderedUnique(await onlineTrailerResolver(item).compactMap(\.youTubeTrailerVideoID))
            let fresh = searchIDs.filter { !serverIDs.contains($0) }
            if !fresh.isEmpty {
                workingID = await playableVideoIDResolver(fresh)
            }
        }

        guard isStillLoaded(item) else { return }
        if let workingID {
            surfaceTrailer(videoID: workingID, for: item)
            trailerCache.record(.working(workingID), for: item.id)
        } else {
            // Nothing playable anywhere — retract the optimistic button (rare; a
            // server trailer with no working video and no findable replacement).
            trailers = []
            trailerCache.record(.none, for: item.id)
        }
    }

    /// Whether the loaded detail is still this `item` (guards against a stale
    /// trailer resolution landing after the user navigated away / reloaded).
    private func isStillLoaded(_ item: MediaItem) -> Bool {
        if case let .loaded(detail) = state, detail.item.id == item.id { return true }
        return false
    }

    /// Builds and shows the online (YouTube) Trailer button for `videoID`, stamped
    /// with the item's context so a play-time replacement search has a clean
    /// title/year to work with.
    private func surfaceTrailer(videoID: String, for item: MediaItem) {
        let trailer = MediaItem.youTubeTrailer(
            videoID: videoID,
            title: "\(item.title) — Trailer",
            parentTitle: item.title,
            posterURL: item.posterURL
        )
        trailers = [stampTrailerContext(trailer, from: item)]
    }

    /// De-duplicates `ids` preserving first-seen order and dropping empties.
    private func orderedUnique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ids where !id.isEmpty && !seen.contains(id) {
            seen.insert(id)
            out.append(id)
        }
        return out
    }

    /// Stamps the parent title and year onto an online (YouTube) trailer so that,
    /// if its video later proves unavailable at play time, the keyless search for
    /// a replacement trailer has a clean title/year to work with (server trailers
    /// often carry only a generic name like "Trailer" and no year). Local trailers
    /// and already-populated fields are left untouched.
    private func stampTrailerContext(_ trailer: MediaItem, from item: MediaItem) -> MediaItem {
        guard trailer.isYouTubeTrailer else { return trailer }
        var copy = trailer
        if copy.parentTitle?.isEmpty != false { copy.parentTitle = item.title }
        if copy.productionYear == nil { copy.productionYear = item.productionYear }
        return copy
    }

    /// Applies a watched-state or progress mutation to the loaded detail, its
    /// children and any loaded season episodes **in place** — updating only the
    /// fields the mutation carries (watched badge, resume position, progress). The
    /// arrays keep their identity and order (no refetch, no momentary emptying), so
    /// SwiftUI updates just the affected cards and the user's focus stays exactly
    /// where it was.
    public func applyWatchedState(_ mutation: MediaItemMutation) {
        if case var .loaded(detail) = state {
            detail.item = mutation.applied(to: detail.item)
            detail.children = detail.children.map { mutation.applied(to: $0) }
            state = .loaded(detail)
        }
        for (seasonID, episodes) in seasonEpisodes {
            seasonEpisodes[seasonID] = episodes.map { mutation.applied(to: $0) }
        }
    }

    /// Quietly re-fetches the detail, its children, and any season episode lists
    /// already shown, **without** dropping to a full-screen loading state. Used
    /// after a context-menu action (e.g. mark watched) so the hero, child rail
    /// and watched badges reflect the new server state in place.
    public func reload() async {
        guard !isDiscoveryItem else { return }
        guard case .loaded = state else { await load(); return }
        // Capture the active source identity for this reload. An in-place
        // ``switchToSource(accountID:)`` can re-point active* (and start its own
        // reload) while this one is still awaiting the network; re-checking the
        // identity before publishing makes a superseded reload bail instead of
        // painting the previous server's detail/children over the newer one.
        let provider = activeProvider
        let itemID = activeItemID
        let account = activeSourceAccountID
        func isCurrent() -> Bool {
            activeItemID == itemID && activeSourceAccountID == account
        }
        guard var item = try? await provider.item(id: itemID) else { return }
        guard !Task.isCancelled, isCurrent() else { return }
        item = await redirectingSeasonToSeries(item)
        captureSeriesContext(from: item)
        let children: [MediaItem]
        switch item.kind {
        case .series, .season, .folder, .collection:
            children = (try? await provider.children(of: item.id)) ?? []
        default:
            children = []
        }
        guard !Task.isCancelled, isCurrent() else { return }
        state = .loaded(Detail(item: tagged(item), children: children.map(tagged), childrenLoaded: true))
        // Refresh the episode lists that were already loaded for visible seasons.
        let loadedSeasonIDs = Array(seasonEpisodes.keys)
        seasonEpisodes = [:]
        for seasonID in loadedSeasonIDs {
            if Task.isCancelled { return }
            await loadEpisodes(for: seasonID)
        }
        guard !Task.isCancelled else { return }
        await enrichRatings(for: item)
        await enrichOverview(for: item)
    }

    /// Whether the page can switch to `accountID`'s copy of this title in place —
    /// i.e. that server is one of the known cross-server `sources`, an alternate
    /// provider resolves for it, and it isn't already the active server.
    public func canSwitchToSource(accountID: String) -> Bool {
        guard accountID != activeSourceAccountID,
              sources.contains(where: { $0.accountID == accountID }),
              alternateProviderResolver(accountID) != nil else { return false }
        return true
    }

    /// Retargets the initial active server to the most-local copy of a
    /// cross-server-merged title — **once**, before the first fetch.
    ///
    /// A movie re-selects its best (most-local) copy at play time via the picker
    /// and `bestSourcePlayItem`, so its initial load server doesn't affect where
    /// it plays. A **series** is different: the whole season/episode tree loads
    /// from ONE server, and each per-server episode carries only its own single
    /// source — so `bestSourcePlayItem` can't cross-server re-select at play time.
    /// If the merge-primary happens to be a remote/Tailscale server, every episode
    /// would then stream remotely even when a same-LAN copy exists. Picking the
    /// local server up front fixes that (the picker still lets the user switch).
    ///
    /// Scope guards:
    ///  * Only for titles opened from a cross-server-merged Home/Search row
    ///    (`originSourceAccountID == nil`). A deliberate library-tile browse keeps
    ///    that library's server.
    ///  * Only when there's a real cross-server choice (`initialSources > 1`).
    ///  * Runs at most once and is disabled by an explicit `switchToSource`, so it
    ///    never fights a user's manual server pick.
    ///
    /// Locality is read LIVE from each source's provider (falling back to the
    /// stored ref locality) so a network change since the card was built is
    /// honored.
    private func applyInitialLocalityPreferenceIfNeeded() {
        guard !didApplyInitialLocalityPreference else { return }
        // Only consume the one-shot once there's a REAL cross-server choice to
        // evaluate. A Continue Watching / Home card commonly cold-loads with a
        // single known source (its local twin isn't in the identity index yet), so
        // burning the flag here would permanently disable the retarget — the
        // deferred ``retargetToMostLocalSourceAfterDiscovery`` handles that case
        // once discovery surfaces the twin.
        guard originSourceAccountID == nil, initialSources.count > 1 else { return }
        didApplyInitialLocalityPreference = true

        let liveRanked = initialSources.map { source -> MediaSourceRef in
            let provider = source.accountID == activeSourceAccountID
                ? activeProvider
                : alternateProviderResolver(source.accountID)
            guard let locality = provider?.connectionLocality else { return source }
            var copy = source
            copy.locality = locality
            return copy
        }

        guard let best = CrossSourceSelector.bestSelection(
                  from: liveRanked,
                  capabilities: .detected()
              )?.source,
              best.accountID != activeSourceAccountID,
              let provider = alternateProviderResolver(best.accountID) else { return }

        activeProvider = provider
        activeItemID = best.itemID
        activeSourceAccountID = best.accountID
    }

    /// Deferred twin of ``applyInitialLocalityPreferenceIfNeeded`` for the common
    /// case where a series cold-loads with a SINGLE source and its local copy is
    /// only discovered later (async cross-server discovery).
    ///
    /// The initial pass can only choose among the sources known at first paint. A
    /// Continue Watching / Home card usually has just one source then (the identity
    /// index hasn't surfaced the same-LAN twin yet), so it correctly does nothing.
    /// When discovery later folds in a more-local twin we must still route the
    /// series there — otherwise every episode streams from the original (possibly
    /// remote/Tailscale) server for the whole session, because a series loads its
    /// episode tree from ONE server and per-server episodes can't cross-server
    /// re-select at play time (see ``applyInitialLocalityPreferenceIfNeeded``). This
    /// also refreshes the retarget against LIVE locality, so it doubles as the
    /// detail page's fix for a stale synchronous locality read.
    ///
    /// Series only (a movie re-selects its best copy at play time via
    /// `bestSourcePlayItem`). Never overrides an explicit user pick
    /// (``switchToSource``) or an origin-pinned detail page, and reloads in place so
    /// the local server's episode tree loads. Returns `true` when it retargeted.
    @discardableResult
    private func retargetToMostLocalSourceAfterDiscovery(kind: MediaItemKind) async -> Bool {
        guard kind == .series,
              originSourceAccountID == nil,
              !userDidSwitchSource,
              sources.count > 1 else { return false }

        let liveRanked = sources.map { source -> MediaSourceRef in
            let provider = source.accountID == activeSourceAccountID
                ? activeProvider
                : alternateProviderResolver(source.accountID)
            guard let locality = provider?.connectionLocality else { return source }
            var copy = source
            copy.locality = locality
            return copy
        }

        guard let best = CrossSourceSelector.bestSelection(
                  from: liveRanked,
                  capabilities: .detected()
              )?.source,
              best.accountID != activeSourceAccountID,
              let provider = alternateProviderResolver(best.accountID) else { return false }

        // Deliberately DO NOT call `suspendEnrichment()` here: this runs inside
        // `crossServerDiscoveryTask` (via the awaited `applyDiscoveredSources`), and
        // suspend cancels that task — which would also cancel THIS task and make the
        // `reload()` below bail on its `Task.isCancelled` checks, painting nothing.
        // Stop only the per-server speculative enrichment now pointed at the wrong
        // server; the discovery task itself is already finishing.
        enrichmentTask?.cancel(); enrichmentTask = nil
        alternateSourceEnrichmentTask?.cancel(); alternateSourceEnrichmentTask = nil

        activeProvider = provider
        activeItemID = best.itemID
        activeSourceAccountID = best.accountID

        seasonEpisodes = [:]
        loadingSeasons = []
        preselectedSeasonID = nil

        await reload()
        // Re-establish alternate-version enrichment against the NEW active server so
        // the picker's other servers still fill in their real versions.
        startAlternateSourceEnrichment(primaryID: best.itemID)
        return true
    }

    /// Switches the page to another server's copy of this title IN PLACE — without
    /// pushing a navigation entry — and reloads that server's children/episodes.
    ///
    /// This brings a **series** server-switch to parity with how movies already
    /// switch source via a state override: the cross-server picker still shows
    /// every server, episode preservation (same S·E) and origin-aware version
    /// defaulting still work, but pressing Back returns to the origin rather than
    /// walking back through each previously-selected server. The per-server item
    /// ids differ, so `activeProvider`/`activeItemID`/`activeSourceAccountID` are
    /// re-pointed (re-keying snapshot + episode caches) and the children reload
    /// from the new server; `sources` itself is left intact so the picker keeps
    /// every server. No-op for an unknown/already-active account.
    public func switchToSource(accountID: String) async {
        guard accountID != activeSourceAccountID,
              let source = sources.first(where: { $0.accountID == accountID }),
              let provider = alternateProviderResolver(accountID) else { return }

        // An explicit user pick is authoritative — never let a subsequent
        // `load()` re-apply the automatic initial locality preference, nor the
        // post-discovery locality retarget, over it.
        didApplyInitialLocalityPreference = true
        userDidSwitchSource = true

        // Stop the old server's speculative enrichment so it can't clobber the new
        // server's source list after the switch.
        suspendEnrichment()

        activeProvider = provider
        activeItemID = source.itemID
        activeSourceAccountID = accountID

        // Drop the old server's per-season episode caches so the rail reloads from
        // the new server (its ids differ); the season list reloads via reload().
        seasonEpisodes = [:]
        loadingSeasons = []
        preselectedSeasonID = nil

        // Reload the new server's detail + children in place over the existing
        // hero (no spinner). reload() now reads activeProvider/activeItemID.
        await reload()
    }

    /// Lazily fetches and caches the episodes of one season. Idempotent: a season
    /// already loaded (or in flight) is a no-op, so callers may invoke it freely
    /// whenever a season tab gains focus. Fetch failures cache an empty list so a
    /// missing season renders as "no episodes" rather than retrying on every
    /// focus change.
    public func loadEpisodes(for seasonID: String) async {
        if seasonEpisodes[seasonID] != nil || loadingSeasons.contains(seasonID) { return }
        loadingSeasons.insert(seasonID)
        defer { loadingSeasons.remove(seasonID) }
        let episodes = (try? await activeProvider.children(of: seasonID)) ?? []
        guard !Task.isCancelled else { return }
        seasonEpisodes[seasonID] = stampSeriesTMDb(into: episodes.map(tagged))
        persistSnapshot()
    }

    /// Replaces the cached episodes for a season after the view has enriched them
    /// — specifically, after injecting a resolved still URL into episodes the
    /// server has no image for, so the rail re-renders seeding a synchronously
    /// available thumbnail (no gray-placeholder flash). The ids and order are
    /// unchanged, so SwiftUI updates artwork in place without disturbing focus.
    public func setEpisodes(_ episodes: [MediaItem], for seasonID: String) {
        guard seasonEpisodes[seasonID] != nil else { return }
        seasonEpisodes[seasonID] = episodes
    }

    /// Refreshes a focused episode's capability badges from a full per-item fetch.
    ///
    /// Episode rails are seeded from the season's `/children` listing. On Plex that
    /// payload can come back with a TRIMMED `<Stream>` (no `DOVIPresent`/`colorTrc`)
    /// and without the Media-level `audioProfile`, so the parser asserts `SDR` and
    /// drops Atmos — an episode that is really 4K Dolby Vision / HDR10 / Atmos then
    /// badges as "SDR · Dolby Digital+ 5.1". (Jellyfin's children payload carries
    /// the full stream facts, which is why the same title badges correctly there.)
    /// The full `/library/metadata/{id}` fetch always carries the real stream
    /// facts, so when an episode is shown in the hero we fetch it once and merge its
    /// `mediaInfo`/`versions` back into the cached rail entry.
    ///
    /// Idempotent per episode id (only the first focus pays a fetch). Returns the
    /// enriched episode (or the already-rich cached copy) so the caller can refresh
    /// the hero in place, or `nil` when there is nothing to update.
    public func enrichEpisodeBadgesIfNeeded(_ episode: MediaItem) async -> MediaItem? {
        guard episode.kind == .episode else { return nil }
        if enrichedEpisodeIDs.contains(episode.id) {
            return storedEpisode(id: episode.id)
        }
        guard let full = try? await activeProvider.item(id: episode.id),
              !Task.isCancelled else { return nil }
        enrichedEpisodeIDs.insert(episode.id)
        var enriched = episode
        enriched.mediaInfo = full.mediaInfo ?? enriched.mediaInfo
        if !full.versions.isEmpty { enriched.versions = full.versions }
        mergeEnrichedEpisodeIntoRail(enriched)
        return enriched
    }

    /// The currently-cached rail copy of an episode, scanning every loaded season.
    private func storedEpisode(id: String) -> MediaItem? {
        for episodes in seasonEpisodes.values {
            if let match = episodes.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    /// Folds an enriched episode's badge facts back into its season's rail entry,
    /// preserving every other field already on the cached item (e.g. a
    /// view-injected still URL) so the rail re-renders artwork in place.
    private func mergeEnrichedEpisodeIntoRail(_ episode: MediaItem) {
        for (seasonID, episodes) in seasonEpisodes {
            guard let index = episodes.firstIndex(where: { $0.id == episode.id }) else { continue }
            var updated = episodes
            var merged = updated[index]
            merged.mediaInfo = episode.mediaInfo
            merged.versions = episode.versions
            updated[index] = merged
            seasonEpisodes[seasonID] = updated
            persistSnapshot()
            return
        }
    }

    /// Stamps an item with this detail's owning account (if any) so navigation
    /// keeps routing to the right provider.
    private func tagged(_ item: MediaItem) -> MediaItem {
        guard let activeSourceAccountID else { return item }
        return item.taggingSource(activeSourceAccountID)
    }

    /// Captures the series-level context (TMDb id + anime ids/genre) used to stamp
    /// episodes as they load. Cleared for non-series details.
    private func captureSeriesContext(from item: MediaItem) {
        guard item.kind == .series else {
            seriesEpisodeContext = nil
            return
        }
        seriesEpisodeContext = SeriesEpisodeContext(series: item)
    }

    /// Paints a restored ``DetailSnapshotCache`` snapshot so a revisited title
    /// shows its hero, season/episode lists and server picker instantly. Strictly
    /// additive to first paint — the live `load()` immediately follows and replaces
    /// this in place with fresh data (same identity ⇒ no flicker).
    private func applySnapshot(_ snapshot: DetailSnapshotCache.Snapshot) {
        let item = tagged(snapshot.item)
        captureSeriesContext(from: item)
        // A snapshot's children are a COMPLETED fetch persisted from a prior visit,
        // so mark them loaded — otherwise a revisited folder would flash its
        // loading placeholder (and, worse, never distinguish empty-from-loading).
        state = .loaded(Detail(item: item, children: snapshot.children.map(tagged), childrenLoaded: true))
        if !snapshot.seasonEpisodes.isEmpty {
            seasonEpisodes = snapshot.seasonEpisodes.mapValues { stampSeriesTMDb(into: $0.map(tagged)) }
        }
        if snapshot.sources.count > 1 {
            let restored = prunedToActiveAccounts(snapshot.sources)
            if restored.count > 1 {
                sources = restored
                applyUnifiedWatchState()
            }
        }
    }

    /// Applies a snapshot that lost the race to the live fetch. On a genuinely cold
    /// open (no hero painted yet) it restores the full snapshot; otherwise it keeps
    /// whatever hero is showing and only ADOPTS enrichments the current state still
    /// lacks — so a revisit still gets its season picker / episode rails / server
    /// picker instantly from disk without ever downgrading a fresher render.
    private func applySnapshotIfNotStale(_ snapshot: DetailSnapshotCache.Snapshot) {
        if state.value == nil && !hasPaintedFreshDetail {
            applySnapshot(snapshot)
        } else {
            adoptSnapshotEnrichments(snapshot)
        }
    }

    /// Merges cached children/episodes/sources into the current state WITHOUT
    /// downgrading anything the live fetch already produced (each merge is guarded
    /// on the current value being empty/thinner).
    private func adoptSnapshotEnrichments(_ snapshot: DetailSnapshotCache.Snapshot) {
        if let detail = state.value, detail.children.isEmpty, !snapshot.children.isEmpty {
            state = .loaded(Detail(item: detail.item, children: snapshot.children.map(tagged), childrenLoaded: true))
        }
        if seasonEpisodes.isEmpty, !snapshot.seasonEpisodes.isEmpty {
            seasonEpisodes = snapshot.seasonEpisodes.mapValues { stampSeriesTMDb(into: $0.map(tagged)) }
        }
        if sources.count <= 1, snapshot.sources.count > 1 {
            let restored = prunedToActiveAccounts(snapshot.sources)
            if restored.count > 1 {
                sources = restored
                applyUnifiedWatchState()
            }
        }
    }

    /// Writes the current resolved detail (item + children + episodes + sources) to
    /// the persistent cache for instant restore next time. Coalesced to at most one
    /// in-flight write per view model (cancel-and-replace + short debounce): a burst
    /// of state changes during a single open would otherwise fire many full-snapshot
    /// encodes, saturating the cache I/O queue and starving the next page's read.
    /// Only persists once a full detail has been published so a half-loaded page
    /// never overwrites a richer snapshot.
    private func persistSnapshot() {
        guard let detail = state.value, !detail.item.id.isEmpty else { return }
        let snapshot = DetailSnapshotCache.Snapshot(
            item: detail.item,
            children: detail.children,
            seasonEpisodes: seasonEpisodes,
            sources: sources
        )
        let key = snapshotKey
        let cache = snapshotCache
        pendingSnapshotWrite?.cancel()
        pendingSnapshotWrite = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await cache.store(snapshot, for: key)
        }
    }

    /// Ensures every episode carries the parent series' TMDb id under `SeriesTmdb`,
    /// plus the series' anime ids and an "Anime" genre when the show is anime. This
    /// is required for robust anime thumbnail/logo fallback (episodes rarely carry
    /// the show's anime ids/genre, so the series-banner fallback would otherwise
    /// misclassify them as non-anime and show nothing). Done here once per fetch to
    /// avoid per-focus remapping in the view layer.
    private func stampSeriesTMDb(into episodes: [MediaItem]) -> [MediaItem] {
        guard let seriesEpisodeContext else { return episodes }
        return seriesEpisodeContext.stamping(episodes)
    }

    /// Fetches external ratings off the critical path and merges them into the
    /// already-loaded detail. Failures are silent — the screen keeps whatever
    /// backend-native ratings it already has.
    private func enrichRatings(for item: MediaItem) async {
        let external = await ratingsProvider.ratings(for: item)
        guard !Task.isCancelled else { return }
        guard !external.isEmpty else { return }
        guard case var .loaded(detail) = state, detail.item.id == item.id else { return }
        detail.item.ratings = detail.item.ratings.mergedWithAuthoritative(external)
        state = .loaded(detail)
    }

    /// Fills in a missing plot/overview from the keyless ``OverviewRouter`` (TVmaze
    /// for TV, Wikipedia for film/anime), off the critical path. Only runs when the
    /// item has NO description of its own — so a real server's overview is never
    /// overwritten, and in practice this only fires for local media-share items
    /// (whose provider synthesises no text). Cached in the router, so revisiting a
    /// page or opening another episode of the same show issues no new request. A
    /// describable kind is required so folders/collections never trigger a lookup.
    private func enrichOverview(for item: MediaItem) async {
        guard item.overview?.isEmpty ?? true else { return }
        switch item.kind {
        case .movie, .series, .season, .episode, .video: break
        case .folder, .collection, .unknown: return
        }
        let text = await OverviewRouter.shared.overview(for: item)
        guard !Task.isCancelled, let text, !text.isEmpty else { return }
        guard case var .loaded(detail) = state, detail.item.id == item.id else { return }
        guard detail.item.overview?.isEmpty ?? true else { return }
        detail.item.overview = text
        state = .loaded(detail)
    }

    /// Seeds ``sources`` from the merged card's references, stamping the *primary*
    /// source (the one this detail was loaded from) with the freshly-fetched
    /// versions and watch-state so the server picker and version picker are
    /// correct the instant the hero renders — before any alternate server is hit.
    /// Leaves `sources` empty for a single-server title (no picker shown).
    private func seedSources(from primary: MediaItem) {
        guard initialSources.count > 1 else {
            // Single-server card: nothing to seed from initialSources. But if a
            // snapshot restore (or earlier discovery) already populated a richer
            // sources list with same-account siblings or cross-server twins, do
            // NOT clobber it back to empty — that's how the version picker
            // disappeared on revisit until async discovery re-ran ~1s later.
            if sources.count <= 1 {
                sources = []
            } else {
                // Re-stamp just the primary entry with the freshly-fetched
                // watch-state and versions so the kept-from-snapshot picker
                // still reflects the latest from this server. Prune first so a
                // server disabled since the snapshot was written drops out.
                sources = prunedToActiveAccounts(sources)
                    .map { stampedPrimarySource($0, from: primary) }
                applyUnifiedWatchState()
            }
            return
        }
        // Prune any source whose owning account is no longer active (signed out
        // or excluded from the active profile) BEFORE seeding, exactly as the
        // cache-restore and single-server paths do — otherwise a merged card
        // built while a server was enabled would seed a picker entry the app
        // can't reach or switch to (`switchToSource`/enrichment already guard on
        // the resolver, so it would sit there dead). The active/primary source is
        // always retained by `prunedToActiveAccounts`.
        let activeSources = prunedToActiveAccounts(initialSources)
        guard activeSources.count > 1 else {
            // Pruning collapsed us to a single reachable server: no picker, same
            // contract as a single-server card above.
            sources = []
            return
        }
        sources = activeSources.map { source in
            guard source.itemID == primary.id else { return source }
            var seeded = source
            // Single-file primary items report no intrinsic versions; synthesise
            // one so the combined version picker (across same-account siblings)
            // has a distinguishable entry for the primary's own file.
            seeded.versions = primary.versions.isEmpty
                ? [MediaVersion.synthesized(from: primary)]
                : primary.versions
            seeded.resumePosition = primary.resumePosition
            seeded.playedPercentage = primary.playedPercentage
            seeded.isPlayed = primary.isPlayed
            seeded.isFavorite = primary.isFavorite
            seeded.lastPlayedAt = primary.lastPlayedAt
            return seeded
        }
        applyUnifiedWatchState()
    }

    /// Discovers other servers hosting this title (off the critical path) and folds
    /// them into ``sources`` so a single-server card (e.g. a Home row only one
    /// server surfaced) still gets a server picker. Idempotent: only updates when
    /// it actually finds *more* servers than are already known, so it never
    /// regresses a richer picker already seeded from a merged Search/Home card.
    private func startCrossServerDiscovery(for primary: MediaItem) {
        guard let resolver = crossServerSourceResolver else { return }
        let token = enrichmentGeneration
        crossServerDiscoveryTask?.cancel()
        crossServerDiscoveryTask = Task(priority: .utility) { [weak self] in
            // Gate the multi-server search fan-out behind the shared scheduler:
            // skipped entirely if a newer page has superseded this one, and capped
            // so at most a couple run app-wide.
            let discovered = await EnrichmentScheduler.shared.run(token: token) {
                await resolver(primary)
            }
            guard let discovered, !Task.isCancelled, discovered.count > 1 else { return }
            await self?.applyDiscoveredSources(discovered, primary: primary)
        }
    }

    private func sourceKey(_ source: MediaSourceRef) -> String {
        "\(source.accountID)#\(source.itemID)"
    }

    /// Drops picker sources whose owning account is no longer active — signed
    /// out, or excluded from the active profile via the "Use this server" toggle
    /// (such an account resolves no provider through `alternateProviderResolver`).
    /// The primary/active source is always retained so the page the user
    /// navigated to never loses its own entry. This is what keeps a disabled
    /// server from lingering in the picker when it's restored from a stale
    /// on-disk snapshot persisted while the server was still enabled.
    private func prunedToActiveAccounts(_ candidate: [MediaSourceRef]) -> [MediaSourceRef] {
        candidate.filter { source in
            source.accountID == activeSourceAccountID
                || alternateProviderResolver(source.accountID) != nil
        }
    }

    /// Stamps the primary source with the freshly-fetched detail so the picker and
    /// version list are correct for the server the user is already looking at.
    private func stampedPrimarySource(_ source: MediaSourceRef, from primary: MediaItem) -> MediaSourceRef {
        guard source.accountID == activeSourceAccountID, source.itemID == primary.id else { return source }
        var seeded = source
        seeded.versions = primary.versions.isEmpty
            ? [MediaVersion.synthesized(from: primary)]
            : primary.versions
        seeded.resumePosition = primary.resumePosition
        seeded.playedPercentage = primary.playedPercentage
        seeded.isPlayed = primary.isPlayed
        seeded.isFavorite = primary.isFavorite
        seeded.lastPlayedAt = primary.lastPlayedAt
        return seeded
    }

    private func applyDiscoveredSources(_ discovered: [MediaSourceRef], primary: MediaItem) async {
        guard !discovered.isEmpty else { return }
        var result: [MediaSourceRef]
        if sources.isEmpty {
            // Single-server card: take the discovered cross-server set wholesale,
            // stamping the primary with the detail we already fetched.
            result = discovered.map { stampedPrimarySource($0, from: primary) }
        } else {
            // Already had a (seeded) picker: union in any newly-found servers,
            // preserving existing order + already-enriched versions.
            result = sources
            // Refresh each KEPT source's locality from the re-discovery first: a
            // repeated discovery may re-classify a server local↔remote after a
            // network change (e.g. the device got home onto the LAN, or dropped
            // off it onto Tailscale) WITHOUT surfacing any new server. That
            // must still update the picker highlight and the play default, so we
            // publish on a locality change even when the server count is
            // unchanged (the count-grew guard below alone would swallow it).
            let discoveredLocality = Dictionary(
                discovered.compactMap { ref in ref.locality.map { (sourceKey(ref), $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            result = result.map { existing in
                guard let refreshed = discoveredLocality[sourceKey(existing)],
                      refreshed != existing.locality else { return existing }
                var copy = existing
                copy.locality = refreshed
                return copy
            }
            var keys = Set(result.map(sourceKey))
            for source in discovered where keys.insert(sourceKey(source)).inserted {
                result.append(source)
            }
        }
        // Publish when discovery expanded the server list OR refreshed a kept
        // server's locality (result differs from the current sources).
        guard result.count > 1, result != sources else { return }
        sources = result
        applyUnifiedWatchState()
        persistSnapshot()
        // If discovery surfaced a more-local copy of a SERIES, route there now so
        // its episode tree loads from the local (same-LAN) server — the initial
        // pass couldn't pick it because the twin wasn't known at first paint. The
        // reload inside re-drives detail AND re-establishes alternate enrichment for
        // the new active server, so return before kicking the old server's pass.
        if await retargetToMostLocalSourceAfterDiscovery(kind: primary.kind) { return }
        startAlternateSourceEnrichment(primaryID: primary.id)
    }

    private struct AlternateSourceRequest: Sendable {
        var sourceID: String
        var itemID: String
        var accountID: String
        var provider: any MediaProvider
    }

    private struct AlternateSourceUpdate: Sendable {
        var sourceID: String
        var versions: [MediaVersion]
        var resumePosition: TimeInterval?
        var playedPercentage: Double?
        var isPlayed: Bool
        var isFavorite: Bool
        var lastPlayedAt: Date?
    }

    /// Starts best-effort alternate-server enrichment off the critical path with a
    /// bounded concurrent fan-out, then applies all resolved updates in one batch.
    private func startAlternateSourceEnrichment(primaryID: String) {
        guard sources.count > 1 else { return }
        let token = enrichmentGeneration
        let requests: [AlternateSourceRequest] = sources.compactMap { source in
            guard source.itemID != primaryID,
                  let provider = alternateProviderResolver(source.accountID) else { return nil }
            return AlternateSourceRequest(
                sourceID: source.id,
                itemID: source.itemID,
                accountID: source.accountID,
                provider: provider
            )
        }
        guard !requests.isEmpty else { return }

        alternateSourceEnrichmentTask = Task(priority: .utility) { [weak self] in
            // Gate behind the shared scheduler so a superseded page's alternate
            // fetches are skipped and total background concurrency stays bounded.
            let updates = await EnrichmentScheduler.shared.run(token: token) {
                await Self.fetchAlternateSourceUpdates(
                    requests,
                    maxConcurrent: Self.alternateSourceFanoutLimit
                )
            }
            guard let updates, !Task.isCancelled, !updates.isEmpty else { return }
            await self?.applyAlternateSourceUpdates(updates, primaryID: primaryID)
        }
    }

    /// Fetches alternate-server copies concurrently (bounded), preserving
    /// first-seen source order in the resulting updates. When an alternate item
    /// has no intrinsic ``MediaItem/versions`` (a single-file item, which is the
    /// common case for same-account duplicate movies), one is **synthesised**
    /// from its `mediaInfo` so the version picker has a distinguishable entry
    /// for it carrying the backing item id.
    private nonisolated static func fetchAlternateSourceUpdates(
        _ requests: [AlternateSourceRequest],
        maxConcurrent: Int
    ) async -> [AlternateSourceUpdate] {
        guard !requests.isEmpty else { return [] }
        let concurrency = max(1, min(maxConcurrent, requests.count))
        return await withTaskGroup(of: (Int, AlternateSourceUpdate?).self) { group in
            var nextIndex = 0
            func makeTask(index: Int, request: AlternateSourceRequest) {
                group.addTask {
                    guard let alt = try? await request.provider.item(id: request.itemID) else {
                        return (index, nil)
                    }
                    let tagged = alt.taggingSource(request.accountID)
                    let versions = tagged.versions.isEmpty
                        ? [MediaVersion.synthesized(from: tagged)]
                        : tagged.versions
                    return (index, AlternateSourceUpdate(
                        sourceID: request.sourceID,
                        versions: versions,
                        resumePosition: tagged.resumePosition,
                        playedPercentage: tagged.playedPercentage,
                        isPlayed: tagged.isPlayed,
                        isFavorite: tagged.isFavorite,
                        lastPlayedAt: tagged.lastPlayedAt
                    ))
                }
            }
            for _ in 0..<concurrency {
                let index = nextIndex
                nextIndex += 1
                makeTask(index: index, request: requests[index])
            }

            var byIndex: [Int: AlternateSourceUpdate] = [:]
            while let (index, update) = await group.next() {
                if let update { byIndex[index] = update }
                if nextIndex < requests.count {
                    let queuedIndex = nextIndex
                    nextIndex += 1
                    makeTask(index: queuedIndex, request: requests[queuedIndex])
                }
            }
            return requests.indices.compactMap { byIndex[$0] }
        }
    }

    /// Applies alternate-source metadata updates in one publish to minimise
    /// repeated main-actor churn while preserving unified watch-state behaviour.
    private func applyAlternateSourceUpdates(_ updates: [AlternateSourceUpdate], primaryID: String) {
        guard case let .loaded(detail) = state, detail.item.id == primaryID else { return }
        var updatedSources = sources
        var changed = false
        for update in updates {
            guard let index = updatedSources.firstIndex(where: { $0.id == update.sourceID }) else { continue }
            var source = updatedSources[index]
            source.versions = update.versions
            source.resumePosition = update.resumePosition
            source.playedPercentage = update.playedPercentage
            source.isPlayed = update.isPlayed
            source.isFavorite = update.isFavorite
            source.lastPlayedAt = update.lastPlayedAt
            if source != updatedSources[index] {
                updatedSources[index] = source
                changed = true
            }
        }
        guard changed else { return }
        sources = updatedSources
        applyUnifiedWatchState()
    }

    /// Folds every known source's watch-state into one most-recent-wins state and
    /// stamps it onto the loaded detail, so a merged title's hero shows unified
    /// progress (e.g. 4 min watched on server A even when primary-backed by B).
    private func applyUnifiedWatchState() {
        guard sources.count > 1, case var .loaded(detail) = state else { return }
        let unified = MediaItemMerger.unifiedWatchState(from: sources)
        detail.item.resumePosition = unified.resumePosition
        detail.item.playedPercentage = unified.playedPercentage
        detail.item.isPlayed = unified.isPlayed
        detail.item.lastPlayedAt = unified.lastPlayedAt
        state = .loaded(detail)
    }

    /// Label for the primary action button, reflecting resume vs. play.
    public func playButtonTitle(for item: MediaItem) -> String {
        "Play"
    }
}
