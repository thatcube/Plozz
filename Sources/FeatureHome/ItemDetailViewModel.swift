import Foundation
import Observation
import CoreModels
import RatingsService

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

    private let provider: any MediaProvider
    private let itemID: String
    private let ratingsProvider: any ExternalRatingsProviding
    /// Resolves online (TMDb → YouTube) trailers, used only when the provider
    /// surfaces no local trailer. Injectable so tests can avoid the network.
    private let onlineTrailerResolver: OnlineTrailerResolving
    /// The account this item belongs to, propagated so the detail item and its
    /// children stay tagged with their owning provider as the user drills down
    /// (children come from the provider untagged). `nil` outside aggregated flows.
    private let sourceAccountID: String?

    public init(
        provider: any MediaProvider,
        itemID: String,
        ratingsProvider: any ExternalRatingsProviding = DisabledRatingsProvider(),
        sourceAccountID: String? = nil,
        onlineTrailerResolver: @escaping OnlineTrailerResolving = ItemDetailViewModel.defaultOnlineTrailerResolver
    ) {
        self.provider = provider
        self.itemID = itemID
        self.ratingsProvider = ratingsProvider
        self.sourceAccountID = sourceAccountID
        self.onlineTrailerResolver = onlineTrailerResolver
    }

    /// Production online-trailer resolver: looks the title up on TMDb and surfaces
    /// the best YouTube trailer as a playable online trailer item.
    public static let defaultOnlineTrailerResolver: OnlineTrailerResolving = { item in
        await OnlineTrailerSource.trailers(for: item)
    }

    public func load() async {
        state = .loading
        do {
            let item = try await provider.item(id: itemID)
            // Series/seasons have children to list; leaf items don't.
            let children: [MediaItem]
            switch item.kind {
            case .series, .season, .folder, .collection:
                children = try await provider.children(of: itemID)
            default:
                children = []
            }
            state = .loaded(Detail(item: tagged(item), children: children.map(tagged)))
            await loadTrailers(for: item)
            await enrichRatings(for: item)
        } catch let error as AppError {
            state = .failed(error)
        } catch {
            state = .failed(.unknown(""))
        }
    }

    /// Already-loaded episodes for `seasonID`, or `nil` if not yet fetched.
    public func episodes(for seasonID: String) -> [MediaItem]? {
        seasonEpisodes[seasonID]
    }

    /// Fetches the item's trailers off the critical path and tags them with the
    /// owning account so playback routes to the right provider. Local trailers
    /// (Jellyfin local files, Plex local extras) are preferred; when the backend
    /// has none, falls back to an online (TMDb → YouTube) trailer so libraries
    /// without local trailer files still get one. Best-effort: any failure leaves
    /// `trailers` empty and the detail page hides its Trailer button.
    private func loadTrailers(for item: MediaItem) async {
        let local = (try? await provider.trailers(for: item.id)) ?? []
        // Online trailers are intentionally left untagged: they route to the
        // YouTube trailer provider via their marker, not to an account provider.
        let resolved = local.isEmpty ? await onlineTrailerResolver(item) : local.map(tagged)
        guard case let .loaded(detail) = state, detail.item.id == item.id else { return }
        trailers = resolved
    }

    /// Applies a watched-state mutation to the loaded detail, its children and
    /// any loaded season episodes **in place** — flipping only the `isPlayed`
    /// flag on the affected items. Because the arrays keep their identity and
    /// order (no refetch, no momentary emptying), SwiftUI updates just the
    /// watched badges and the user's focus stays exactly where it was.
    public func applyWatchedState(_ mutation: MediaItemMutation) {
        if case var .loaded(detail) = state {
            if mutation.itemIDs.contains(detail.item.id) {
                detail.item.isPlayed = mutation.played
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
        copy.isPlayed = mutation.played
        return copy
    }

    /// Quietly re-fetches the detail, its children, and any season episode lists
    /// already shown, **without** dropping to a full-screen loading state. Used
    /// after a context-menu action (e.g. mark watched) so the hero, child rail
    /// and watched badges reflect the new server state in place.
    public func reload() async {
        guard case .loaded = state else { await load(); return }
        guard let item = try? await provider.item(id: itemID) else { return }
        let children: [MediaItem]
        switch item.kind {
        case .series, .season, .folder, .collection:
            children = (try? await provider.children(of: itemID)) ?? []
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
        seasonEpisodes[seasonID] = episodes.map(tagged)
    }

    /// Stamps an item with this detail's owning account (if any) so navigation
    /// keeps routing to the right provider.
    private func tagged(_ item: MediaItem) -> MediaItem {
        guard let sourceAccountID else { return item }
        return item.taggingSource(sourceAccountID)
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
        if let resume = item.resumePosition, resume > 1 {
            return "Resume"
        }
        return "Play"
    }
}
