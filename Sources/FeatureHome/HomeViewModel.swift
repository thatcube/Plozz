import Foundation
import Observation
import CoreModels
import TopShelfKit

/// Loads and holds the unified Home screen's content rows, merged across every
/// active account/provider. Home-visibility filtering of the Libraries row is
/// applied reactively in the view (against the shared visibility model) so the
/// network result is held unfiltered and toggles take effect without a reload.
@MainActor
@Observable
public final class HomeViewModel {
    public struct Content: Equatable, Sendable {
        public var continueWatching: [MediaItem]
        public var latest: [MediaItem]
        /// The unified Watchlist row, merged across `WatchlistProviding` accounts.
        public var watchlist: [MediaItem]
        /// Every discovered library (unfiltered), tagged with its owning account.
        public var libraries: [AggregatedLibrary]

        public var isEmpty: Bool {
            continueWatching.isEmpty && latest.isEmpty && watchlist.isEmpty && libraries.isEmpty
        }
    }

    public private(set) var state: LoadState<Content> = .idle

    private let accounts: [ResolvedAccount]
    private let aggregator: HomeAggregator

    public init(
        accounts: [ResolvedAccount],
        aggregator: HomeAggregator = HomeAggregator()
    ) {
        self.accounts = accounts
        self.aggregator = aggregator
    }

    /// User-facing name for the greeting header — the primary (first) account.
    public var userName: String { accounts.first?.account.userName ?? "" }

    public func load() async {
        state = .loading

        let aggregator = self.aggregator
        let accounts = self.accounts
        let merged = await Task.detached(priority: .userInitiated) {
            await aggregator.content(from: accounts)
        }.value
        guard !Task.isCancelled else { return }
        let content = Content(
            continueWatching: merged.continueWatching,
            latest: merged.latest,
            watchlist: merged.watchlist,
            libraries: merged.libraries
        )
        state = content.isEmpty ? .empty : .loaded(content)
        guard !Task.isCancelled else { return }

        // Publish the playable rows to the App Group so the Top Shelf extension
        // can render them while the app is closed.
        let continueWatching = content.continueWatching
        let latest = content.latest
        Task.detached(priority: .utility) {
            TopShelfPublisher.publish(continueWatching: continueWatching, latest: latest)
        }
    }

    /// Applies a watched-state or watchlist mutation to the loaded rows **in
    /// place** so the affected cards just flip their badge. Items are kept in
    /// their rows (rather than refetched/removed) so the user's focus is
    /// preserved exactly where it was when they invoked the menu. A watchlist
    /// add/remove also inserts/removes the title from the Watchlist row.
    public func applyWatchedState(_ mutation: MediaItemMutation) {
        guard case var .loaded(content) = state else { return }
        content.continueWatching = content.continueWatching.map { apply(mutation, to: $0) }
        content.latest = content.latest.map { apply(mutation, to: $0) }
        content.watchlist = updatedWatchlist(content.watchlist, mutation: mutation, in: content)
        state = .loaded(content)
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
            let present = Set(updated.map(\.id))
            let candidates = (content.continueWatching + content.latest)
                .filter { mutation.itemIDs.contains($0.id) && !present.contains($0.id) }
            var seen = present
            for candidate in candidates where seen.insert(candidate.id).inserted {
                var copy = candidate
                copy.isFavorite = true
                updated.insert(copy, at: 0)
            }
        } else {
            updated.removeAll { mutation.itemIDs.contains($0.id) }
        }
        return updated
    }

    private func apply(_ mutation: MediaItemMutation, to item: MediaItem) -> MediaItem {
        guard mutation.itemIDs.contains(item.id) else { return item }
        var copy = item
        if let played = mutation.played { copy.isPlayed = played }
        if let favorite = mutation.favorite { copy.isFavorite = favorite }
        return copy
    }
}
