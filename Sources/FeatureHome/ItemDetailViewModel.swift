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
    private var alternateSourceEnrichmentTask: Task<Void, Never>?
    /// In-flight cross-server discovery pass (search other accounts for this
    /// title). Cancellable so a reload/navigation change drops stale work.
    private var crossServerDiscoveryTask: Task<Void, Never>?
    /// Off-critical-path restore of the persisted snapshot. Raced against the live
    /// `provider.item(id:)` fetch so first paint is NEVER gated on a (possibly
    /// disk-contended) snapshot read — it only paints/enriches if it wins and
    /// never downgrades a fresher render. Cancelled on each new load.
    private var snapshotRestoreTask: Task<Void, Never>?
    /// Set once the live fetch publishes fresh detail, so a late snapshot restore
    /// never clobbers a fresher hero.
    private var hasPaintedFreshDetail = false
    /// Coalesces snapshot writes to AT MOST one in flight per view model: a burst
    /// of state changes (children arrive, episodes prewarm, cross-server discovery,
    /// alternate-source updates) used to each fire a full-snapshot encode+write,
    /// flooding the cache's I/O queue and starving the NEXT page's snapshot read
    /// for many seconds. Cancel-and-replace + a short debounce collapses the burst
    /// into a single write of the latest snapshot.
    private var pendingSnapshotWrite: Task<Void, Never>?
    /// Bound concurrent alternate-server detail fetches to keep Home-opened
    /// details responsive and avoid saturating startup/network image traffic.
    private static let alternateSourceFanoutLimit = 3

    /// In-flight trailers+ratings enrichment, owned as a cancellable task that
    /// `load()` does NOT await. Decoupling it from `load()` means a navigate-away
    /// (which cancels via ``suspendEnrichment()``) stops YouTube trailer
    /// extraction + external-ratings work from running to completion on the next
    /// page's back — the cooperative-pool starvation that left a freshly-opened
    /// detail's `provider.item` unscheduled for 15–20s after tapping through
    /// several titles.
    private var enrichmentTask: Task<Void, Never>?
    /// The fully-loaded item enrichment is keyed to, so a page returned to (popped
    /// back onto) can resume the enrichment that was suspended on disappear.
    private var enrichmentItem: MediaItem?
    /// Set once trailers+ratings enrichment ran to completion, so resuming on
    /// reappear doesn't redo finished work.
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
    private var snapshotKey: String { "\(sourceAccountID ?? "_")|\(itemID)" }

    public init(
        provider: any MediaProvider,
        itemID: String,
        initialItem: MediaItem? = nil,
        ratingsProvider: any ExternalRatingsProviding = DisabledRatingsProvider(),
        sourceAccountID: String? = nil,
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
        self.ratingsProvider = ratingsProvider
        self.sourceAccountID = sourceAccountID
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

    public func load() async {
        let _dlogHB = DLog.startHeartbeat()
        DLog.mark("LOAD enter id=\(itemID) acct=\(sourceAccountID ?? "nil") seeded=\(state.value != nil)")
        defer { _dlogHB.cancel(); DLog.setPhase("idle"); DLog.mark("LOAD exit id=\(itemID)") }
        alternateSourceEnrichmentTask?.cancel()
        alternateSourceEnrichmentTask = nil
        enrichmentTask?.cancel()
        enrichmentTask = nil
        crossServerDiscoveryTask?.cancel()
        crossServerDiscoveryTask = nil
        hasPaintedFreshDetail = false

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
            DLog.mark("snapshot restore landed seeded=\(self.state.value != nil) fresh=\(self.hasPaintedFreshDetail)")
            self.applySnapshotIfNotStale(snapshot)
        }

        // Cold open (no seeded hero) shows a spinner immediately instead of blank.
        if state.value == nil { state = .loading }
        do {
            DLog.setPhase("provider.item")
            var fetched = try await provider.item(id: itemID)
            DLog.mark("provider.item done kind=\(fetched.kind)")
            try Task.checkCancellation()
            DLog.setPhase("redirectSeasonToSeries")
            fetched = await redirectingSeasonToSeries(fetched)
            DLog.mark("redirect done")
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
                state = .loaded(Detail(item: taggedItem, children: seededChildren))
                hasPaintedFreshDetail = true
                DLog.mark("FIRST PAINT (container) id=\(item.id)")
                seedSources(from: taggedItem)
                // Off-critical-path enrichment (trailers, ratings, cross-server
                // discovery, alternate sources) runs as a CANCELLABLE unit that
                // `load()` does NOT await — so navigating away cancels it instead of
                // letting it run to completion and starve the next page's
                // `provider.item` for the cooperative thread pool.
                startEnrichment(for: item)
                // Children fill in off the critical path of first paint; merge them
                // in (same item identity ⇒ no hero flicker) when they arrive.
                DLog.setPhase("provider.children")
                let fetchedChildren = (try? await provider.children(of: item.id)) ?? []
                DLog.mark("provider.children done count=\(fetchedChildren.count)")
                try Task.checkCancellation()
                state = .loaded(Detail(item: taggedItem, children: fetchedChildren.map(tagged)))
                persistSnapshot()
            } else {
                // Leaf kinds (movie/episode/video): the hero IS the content, so
                // publish it immediately, then load trailers/ratings off the
                // critical path of first paint.
                state = .loaded(Detail(item: taggedItem, children: []))
                hasPaintedFreshDetail = true
                DLog.mark("FIRST PAINT (leaf) id=\(item.id)")
                seedSources(from: taggedItem)
                persistSnapshot()
                // See container branch: cancellable, non-awaited enrichment so a
                // navigate-away cancels it rather than starving the next page.
                startEnrichment(for: item)
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
              let series = try? await provider.item(id: seriesID) else {
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

    /// Starts all off-critical-path enrichment for `item` as cancellable work:
    /// cross-server server-picker discovery, alternate-source watch-state, and
    /// trailers+ratings. Crucially `load()` does NOT await this — so the page
    /// paints and `load()` returns immediately, and ``suspendEnrichment()`` can
    /// drop every piece the instant the user navigates away. This is what stops a
    /// tapped-through page's YouTube extraction / multi-server search from holding
    /// cooperative-pool threads and starving the next page's `provider.item`.
    private func startEnrichment(for item: MediaItem) {
        enrichmentItem = item
        enrichmentComplete = false
        enrichmentTask?.cancel()
        crossServerDiscoveryTask?.cancel()
        alternateSourceEnrichmentTask?.cancel()
        let taggedItem = tagged(item)
        enrichmentTask = Task(priority: .utility) { [weak self] in
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
            DLog.mark("ENRICH start gen=\(token) id=\(item.id)")
            self.startAlternateSourceEnrichment(primaryID: item.id)
            self.startCrossServerDiscovery(for: taggedItem)
            await self.runTrailersAndRatings(for: item)
        }
    }

    /// Resolves trailers and external ratings concurrently, off the first-paint
    /// path. Runs inside the cancellable ``enrichmentTask`` so a navigate-away
    /// cancels both mid-flight instead of letting them run to completion.
    private func runTrailersAndRatings(for item: MediaItem) async {
        async let trailersDone: Void = loadTrailers(for: item)
        async let ratingsDone: Void = enrichRatings(for: item)
        _ = await trailersDone
        _ = await ratingsDone
        guard !Task.isCancelled else { return }
        enrichmentComplete = true
        DLog.mark("trailers+ratings done id=\(item.id)")
    }

    /// Cancels ALL off-critical-path enrichment (trailers, ratings, cross-server
    /// discovery, alternate-source fetches) for this page. Called from the detail
    /// view's `onDisappear` — when the user navigates away the work must stop so
    /// it cannot keep occupying the cooperative thread pool and starve the NEXT
    /// page's `provider.item` (the multi-second blank-detail hang).
    public func suspendEnrichment() {
        DLog.mark("SUSPEND enrichment gen=\(enrichmentGeneration)")
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
        startEnrichment(for: item)
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
        let provided = (try? await provider.trailers(for: item.id)) ?? []
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

    /// Applies a watched-state mutation to the loaded detail, its children and
    /// any loaded season episodes **in place** — flipping only the `isPlayed`
    /// flag on the affected items. Because the arrays keep their identity and
    /// order (no refetch, no momentary emptying), SwiftUI updates just the
    /// watched badges and the user's focus stays exactly where it was.
    public func applyWatchedState(_ mutation: MediaItemMutation) {
        if case var .loaded(detail) = state {
            if mutation.itemIDs.contains(detail.item.id) {
                if let played = mutation.played { detail.item.isPlayed = played }
                if let favorite = mutation.favorite { detail.item.isFavorite = favorite }
            }
            detail.children = detail.children.map { apply(mutation, to: $0) }
            state = .loaded(detail)
        }
        for (seasonID, episodes) in seasonEpisodes {
            seasonEpisodes[seasonID] = episodes.map { apply(mutation, to: $0) }
        }
    }

    private func apply(_ mutation: MediaItemMutation, to item: MediaItem) -> MediaItem {
        guard mutation.itemIDs.contains(item.id) else { return item }
        var copy = item
        if let played = mutation.played { copy.isPlayed = played }
        if let favorite = mutation.favorite { copy.isFavorite = favorite }
        return copy
    }

    /// Quietly re-fetches the detail, its children, and any season episode lists
    /// already shown, **without** dropping to a full-screen loading state. Used
    /// after a context-menu action (e.g. mark watched) so the hero, child rail
    /// and watched badges reflect the new server state in place.
    public func reload() async {
        guard case .loaded = state else { await load(); return }
        guard var item = try? await provider.item(id: itemID) else { return }
        guard !Task.isCancelled else { return }
        item = await redirectingSeasonToSeries(item)
        captureSeriesContext(from: item)
        let children: [MediaItem]
        switch item.kind {
        case .series, .season, .folder, .collection:
            children = (try? await provider.children(of: item.id)) ?? []
        default:
            children = []
        }
        guard !Task.isCancelled else { return }
        state = .loaded(Detail(item: tagged(item), children: children.map(tagged)))
        // Refresh the episode lists that were already loaded for visible seasons.
        let loadedSeasonIDs = Array(seasonEpisodes.keys)
        seasonEpisodes = [:]
        for seasonID in loadedSeasonIDs {
            if Task.isCancelled { return }
            await loadEpisodes(for: seasonID)
        }
        guard !Task.isCancelled else { return }
        await enrichRatings(for: item)
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
        let episodes = (try? await provider.children(of: seasonID)) ?? []
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

    /// Stamps an item with this detail's owning account (if any) so navigation
    /// keeps routing to the right provider.
    private func tagged(_ item: MediaItem) -> MediaItem {
        guard let sourceAccountID else { return item }
        return item.taggingSource(sourceAccountID)
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
        state = .loaded(Detail(item: item, children: snapshot.children.map(tagged)))
        if !snapshot.seasonEpisodes.isEmpty {
            seasonEpisodes = snapshot.seasonEpisodes.mapValues { stampSeriesTMDb(into: $0.map(tagged)) }
        }
        if snapshot.sources.count > 1 {
            sources = snapshot.sources
            applyUnifiedWatchState()
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
            state = .loaded(Detail(item: detail.item, children: snapshot.children.map(tagged)))
        }
        if seasonEpisodes.isEmpty, !snapshot.seasonEpisodes.isEmpty {
            seasonEpisodes = snapshot.seasonEpisodes.mapValues { stampSeriesTMDb(into: $0.map(tagged)) }
        }
        if sources.count <= 1, snapshot.sources.count > 1 {
            sources = snapshot.sources
            applyUnifiedWatchState()
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

    /// Seeds ``sources`` from the merged card's references, stamping the *primary*
    /// source (the one this detail was loaded from) with the freshly-fetched
    /// versions and watch-state so the server picker and version picker are
    /// correct the instant the hero renders — before any alternate server is hit.
    /// Leaves `sources` empty for a single-server title (no picker shown).
    private func seedSources(from primary: MediaItem) {
        guard initialSources.count > 1 else { sources = []; return }
        sources = initialSources.map { source in
            guard source.itemID == primary.id else { return source }
            var seeded = source
            seeded.versions = primary.versions
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

    /// Stamps the primary source with the freshly-fetched detail so the picker and
    /// version list are correct for the server the user is already looking at.
    private func stampedPrimarySource(_ source: MediaSourceRef, from primary: MediaItem) -> MediaSourceRef {
        guard source.accountID == sourceAccountID, source.itemID == primary.id else { return source }
        var seeded = source
        seeded.versions = primary.versions
        seeded.resumePosition = primary.resumePosition
        seeded.playedPercentage = primary.playedPercentage
        seeded.isPlayed = primary.isPlayed
        seeded.isFavorite = primary.isFavorite
        seeded.lastPlayedAt = primary.lastPlayedAt
        return seeded
    }

    private func applyDiscoveredSources(_ discovered: [MediaSourceRef], primary: MediaItem) {
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
            var keys = Set(result.map(sourceKey))
            for source in discovered where keys.insert(sourceKey(source)).inserted {
                result.append(source)
            }
        }
        // Only publish when discovery actually expanded the server list.
        guard result.count > 1, result.count > sources.count else { return }
        sources = result
        applyUnifiedWatchState()
        persistSnapshot()
        startAlternateSourceEnrichment(primaryID: primary.id)
    }

    private struct AlternateSourceRequest: Sendable {
        var sourceID: String
        var itemID: String
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
            return AlternateSourceRequest(sourceID: source.id, itemID: source.itemID, provider: provider)
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
    /// first-seen source order in the resulting updates.
    private nonisolated static func fetchAlternateSourceUpdates(
        _ requests: [AlternateSourceRequest],
        maxConcurrent: Int
    ) async -> [AlternateSourceUpdate] {
        guard !requests.isEmpty else { return [] }
        let concurrency = max(1, min(maxConcurrent, requests.count))
        return await withTaskGroup(of: (Int, AlternateSourceUpdate?).self) { group in
            var nextIndex = 0
            for _ in 0..<concurrency {
                let index = nextIndex
                nextIndex += 1
                let request = requests[index]
                group.addTask {
                    guard let alt = try? await request.provider.item(id: request.itemID) else {
                        return (index, nil)
                    }
                    return (index, AlternateSourceUpdate(
                        sourceID: request.sourceID,
                        versions: alt.versions,
                        resumePosition: alt.resumePosition,
                        playedPercentage: alt.playedPercentage,
                        isPlayed: alt.isPlayed,
                        isFavorite: alt.isFavorite,
                        lastPlayedAt: alt.lastPlayedAt
                    ))
                }
            }

            var byIndex: [Int: AlternateSourceUpdate] = [:]
            while let (index, update) = await group.next() {
                if let update { byIndex[index] = update }
                if nextIndex < requests.count {
                    let queuedIndex = nextIndex
                    nextIndex += 1
                    let request = requests[queuedIndex]
                    group.addTask {
                        guard let alt = try? await request.provider.item(id: request.itemID) else {
                            return (queuedIndex, nil)
                        }
                        return (queuedIndex, AlternateSourceUpdate(
                            sourceID: request.sourceID,
                            versions: alt.versions,
                            resumePosition: alt.resumePosition,
                            playedPercentage: alt.playedPercentage,
                            isPlayed: alt.isPlayed,
                            isFavorite: alt.isFavorite,
                            lastPlayedAt: alt.lastPlayedAt
                        ))
                    }
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
