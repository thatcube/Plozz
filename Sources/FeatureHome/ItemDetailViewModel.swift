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

    /// Episodes for each season of a series, loaded lazily the first time a
    /// season is shown/focused and cached so re-focusing a tab is instant. Keyed
    /// by season id. Observed by `SeriesDetailView` to populate its episode rail.
    public private(set) var seasonEpisodes: [String: [MediaItem]] = [:]
    private var loadingSeasons: Set<String> = []

    private let provider: any MediaProvider
    private let itemID: String
    private let ratingsProvider: any ExternalRatingsProviding
    /// The account this item belongs to, propagated so the detail item and its
    /// children stay tagged with their owning provider as the user drills down
    /// (children come from the provider untagged). `nil` outside aggregated flows.
    private let sourceAccountID: String?

    public init(
        provider: any MediaProvider,
        itemID: String,
        ratingsProvider: any ExternalRatingsProviding = DisabledRatingsProvider(),
        sourceAccountID: String? = nil
    ) {
        self.provider = provider
        self.itemID = itemID
        self.ratingsProvider = ratingsProvider
        self.sourceAccountID = sourceAccountID
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
