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

    public init(
        provider: any MediaProvider,
        itemID: String,
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
        state = .loading
        do {
            var item = try await provider.item(id: itemID)
            guard !Task.isCancelled else { return }
            item = await redirectingSeasonToSeries(item)
            captureSeriesContext(from: item)
            // Series/seasons have children to list; leaf items don't.
            let children: [MediaItem]
            switch item.kind {
            case .series, .season, .folder, .collection:
                children = try await provider.children(of: item.id)
            default:
                children = []
            }
            guard !Task.isCancelled else { return }
            state = .loaded(Detail(item: tagged(item), children: children.map(tagged)))
            guard !Task.isCancelled else { return }
            await loadTrailers(for: item)
            guard !Task.isCancelled else { return }
            await enrichRatings(for: item)
        } catch is CancellationError {
            return
        } catch let error as AppError {
            state = .failed(error)
        } catch {
            state = .failed(.unknown(""))
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

    /// Label for the primary action button, reflecting resume vs. play.
    public func playButtonTitle(for item: MediaItem) -> String {
        "Play"
    }
}
