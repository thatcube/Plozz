import Foundation
import Observation
import CoreModels
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
    /// When this detail is a series, its TMDb id. Stamped into loaded episodes
    /// under `SeriesTmdb` once at fetch time so episode rails don't re-map every
    /// episode on every focus movement.
    private var seriesTMDbID: String?
    /// When this detail is a series, the anime provider-ids (AniList/AniDB/MAL/…)
    /// and an "Anime" marker propagated onto its episodes so each episode — and
    /// the series-level fallback synthesized from it — classifies as anime and can
    /// resolve the keyless AniList banner. Episodes themselves rarely carry the
    /// show's anime ids/genre, so without this an anime episode with no still gets
    /// no thumbnail at all.
    private var seriesAnimeIDs: [String: String] = [:]
    private var seriesIsAnime = false

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

    public init(
        provider: any MediaProvider,
        itemID: String,
        initialItem: MediaItem? = nil,
        ratingsProvider: any ExternalRatingsProviding = DisabledRatingsProvider(),
        sourceAccountID: String? = nil,
        onlineTrailerResolver: @escaping OnlineTrailerResolving = ItemDetailViewModel.defaultOnlineTrailerResolver,
        playableVideoIDResolver: @escaping PlayableTrailerResolving = ItemDetailViewModel.defaultPlayableVideoIDResolver,
        trailerCache: TrailerResolutionCache = .shared
    ) {
        self.provider = provider
        self.itemID = itemID
        self.ratingsProvider = ratingsProvider
        self.sourceAccountID = sourceAccountID
        self.onlineTrailerResolver = onlineTrailerResolver
        self.playableVideoIDResolver = playableVideoIDResolver
        self.trailerCache = trailerCache

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
        // Don't flash a loading/skeleton state over a hero we already seeded from
        // the tapped list item; only show `.loading` for a cold (unseeded) open.
        if state.value == nil { state = .loading }
        do {
            var fetched = try await provider.item(id: itemID)
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
            state = .loaded(Detail(item: taggedItem, children: []))

            if needsChildren {
                // Fan out: children, trailers, and ratings have no dependency on
                // each other once `item` is known, so run them concurrently
                // instead of serially. Trailers and ratings each guard against
                // the user navigating away (`isStillLoaded` / state-id check).
                async let childrenResult: [MediaItem] = (try? await provider.children(of: item.id)) ?? []
                async let trailersDone: Void = loadTrailers(for: item)
                async let ratingsDone: Void = enrichRatings(for: item)

                let fetchedChildren = await childrenResult
                // Patch children in place, preserving the loaded item identity so
                // a fast Back-and-reopen doesn't clobber a newer load.
                if case var .loaded(detail) = state, detail.item.id == taggedItem.id {
                    detail.children = fetchedChildren.map(tagged)
                    state = .loaded(detail)
                }
                _ = await trailersDone
                _ = await ratingsDone
            } else {
                // Leaf kinds: hero is the final state for children; still load
                // trailers/ratings off the critical path of first paint.
                async let trailersDone: Void = loadTrailers(for: item)
                async let ratingsDone: Void = enrichRatings(for: item)
                _ = await trailersDone
                _ = await ratingsDone
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
        let provided = (try? await provider.trailers(for: item.id)) ?? []

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
        item = await redirectingSeasonToSeries(item)
        captureSeriesContext(from: item)
        let children: [MediaItem]
        switch item.kind {
        case .series, .season, .folder, .collection:
            children = (try? await provider.children(of: item.id)) ?? []
        default:
            children = []
        }
        state = .loaded(Detail(item: tagged(item), children: children.map(tagged)))
        // Refresh the episode lists that were already loaded for visible seasons.
        let loadedSeasonIDs = Array(seasonEpisodes.keys)
        seasonEpisodes = [:]
        for seasonID in loadedSeasonIDs {
            await loadEpisodes(for: seasonID)
        }
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
        seasonEpisodes[seasonID] = stampSeriesTMDb(into: episodes.map(tagged))
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
            seriesTMDbID = nil
            seriesAnimeIDs = [:]
            seriesIsAnime = false
            return
        }
        seriesTMDbID = item.providerIDs["Tmdb"]
        seriesAnimeIDs = item.providerIDs.filter { ContentClassifier.isAnimeProviderIDKey($0.key) }
        seriesIsAnime = ContentClassifier.isAnime(item)
    }

    /// Ensures every episode carries the parent series' TMDb id under `SeriesTmdb`,
    /// plus the series' anime ids and an "Anime" genre when the show is anime. This
    /// is required for robust anime thumbnail/logo fallback (episodes rarely carry
    /// the show's anime ids/genre, so the series-banner fallback would otherwise
    /// misclassify them as non-anime and show nothing). Done here once per fetch to
    /// avoid per-focus remapping in the view layer.
    private func stampSeriesTMDb(into episodes: [MediaItem]) -> [MediaItem] {
        let hasTMDb = (seriesTMDbID?.isEmpty == false)
        guard hasTMDb || seriesIsAnime || !seriesAnimeIDs.isEmpty else { return episodes }
        return episodes.map { episode in
            var copy = episode
            if let seriesTMDbID, !seriesTMDbID.isEmpty, copy.providerIDs["SeriesTmdb"] == nil {
                copy.providerIDs["SeriesTmdb"] = seriesTMDbID
            }
            for (key, value) in seriesAnimeIDs where copy.providerIDs[key] == nil {
                copy.providerIDs[key] = value
            }
            if seriesIsAnime, !copy.genres.contains(where: { $0.lowercased().contains("anime") }) {
                copy.genres.append("Anime")
            }
            return copy
        }
    }

    /// Fetches external ratings off the critical path and merges them into the
    /// already-loaded detail. Failures are silent — the screen keeps whatever
    /// backend-native ratings it already has.
    private func enrichRatings(for item: MediaItem) async {
        let external = await ratingsProvider.ratings(for: item)
        guard !external.isEmpty else { return }
        guard case var .loaded(detail) = state, detail.item.id == item.id else { return }
        detail.item.ratings = detail.item.ratings.mergedWithAuthoritative(external)
        state = .loaded(detail)
    }

    /// Label for the primary action button, reflecting resume vs. play.
    public func playButtonTitle(for item: MediaItem) -> String {
        "Play"
    }
}
