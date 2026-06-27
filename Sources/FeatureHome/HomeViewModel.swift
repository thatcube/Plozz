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
    /// The shared identity-index lookup folded into every merged row so a card
    /// surfaced by one server still carries its full cross-server source set.
    private let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]

    /// In-flight content aggregation (run off the main actor) and the fire-and-
    /// forget Top Shelf publish. Tracked so ``deinit`` can cancel them — otherwise
    /// a Home model torn down mid-load (or one that just falls out of scope in a
    /// unit test) leaks detached work that outlives it, occupying the cooperative
    /// pool and, in tests, surviving the case to trip the simulator watchdog.
    // `nonisolated(unsafe)` so the nonisolated `deinit` can cancel these. Mutated
    // only on the main actor; `deinit` runs after the last reference is gone.
    private nonisolated(unsafe) var aggregationTask: Task<HomeAggregator.Content, Never>?
    private nonisolated(unsafe) var topShelfPublishTask: Task<Void, Never>?

    public init(
        accounts: [ResolvedAccount],
        aggregator: HomeAggregator = HomeAggregator(),
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] }
    ) {
        self.accounts = accounts
        self.aggregator = aggregator
        self.identitySources = identitySources
    }

    deinit {
        aggregationTask?.cancel()
        topShelfPublishTask?.cancel()
    }

    /// User-facing name for the greeting header — the primary (first) account.
    public var userName: String { accounts.first?.account.userName ?? "" }

    public func load() async {
        state = .loading

        let aggregator = self.aggregator
        let accounts = self.accounts
        let identitySources = self.identitySources
        let aggregationTask = Task.detached(priority: .userInitiated) {
            await aggregator.content(from: accounts, identitySources: identitySources)
        }
        self.aggregationTask = aggregationTask
        let merged = await aggregationTask.value
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
        // can render them while the app is closed. Tracked so teardown cancels it.
        let continueWatching = content.continueWatching
        let latest = content.latest
        topShelfPublishTask = Task.detached(priority: .utility) {
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
        mutation.applied(to: item)
    }
}
