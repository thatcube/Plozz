import Foundation
import Observation
import CoreModels
import CoreNetworking
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

    /// The row structure to render as a skeleton while loading: the layout
    /// persisted from the previous successful load (so the placeholder matches the
    /// user's real Home), falling back to a default on a first-ever launch.
    public private(set) var skeletonLayout: [HomeRowKind]

    private let accounts: [ResolvedAccount]
    private let aggregator: HomeAggregator
    private let layoutStore: HomeLayoutStoring
    /// The shared identity-index lookup folded into every merged row so a card
    /// surfaced by one server still carries its full cross-server source set.
    private let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]
    /// Reads the user's *current* per-library Home-visibility at load time, so a
    /// reload (e.g. after a library is hidden) re-aggregates against the latest
    /// choices. Drives the provider's library-scoped fetch for hidden-aware
    /// accounts; the per-item row filter still lives in the view so toggles that
    /// need no re-fetch (Plex, already-tagged items) apply instantly.
    private let currentVisibility: () -> HomeLibraryVisibility

    /// In-flight content aggregation (run off the main actor) and the fire-and-
    /// forget Top Shelf publish. Tracked so ``deinit`` can cancel them — otherwise
    /// a Home model torn down mid-load (or one that just falls out of scope in a
    /// unit test) leaks detached work that outlives it, occupying the cooperative
    /// pool and, in tests, surviving the case to trip the simulator watchdog.
    // `nonisolated(unsafe)` so the nonisolated `deinit` can cancel these. Mutated
    // only on the main actor; `deinit` runs after the last reference is gone.
    private nonisolated(unsafe) var aggregationTask: Task<HomeAggregator.Content, Never>?
    private nonisolated(unsafe) var topShelfPublishTask: Task<Void, Never>?

    /// The hidden-library set the currently-loaded content was aggregated for.
    /// `nil` until the first successful load. Used by ``loadIfNeeded(excludedKeys:)``
    /// to tell a genuine input change (hide/show a library) apart from a mere view
    /// reappearance — tvOS restarts a `.task(id:)` every time Home returns from a
    /// pushed detail, so an unguarded reload would re-fetch (flashing the skeleton)
    /// and rebuild the rows (yanking focus to the top) on every back-navigation.
    private var lastLoadedExcludedKeys: Set<String>?

    public init(
        accounts: [ResolvedAccount],
        aggregator: HomeAggregator = HomeAggregator(),
        layoutStore: HomeLayoutStoring = HomeLayoutStore(),
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        currentVisibility: @escaping () -> HomeLibraryVisibility = { .default }
    ) {
        self.accounts = accounts
        self.aggregator = aggregator
        self.layoutStore = layoutStore
        self.identitySources = identitySources
        self.currentVisibility = currentVisibility
        let persisted = layoutStore.load()
        self.skeletonLayout = persisted.isEmpty ? HomeRowKind.defaultSkeletonLayout : persisted
    }

    deinit {
        aggregationTask?.cancel()
        topShelfPublishTask?.cancel()
    }

    /// User-facing name for the greeting header — the primary (first) account.
    public var userName: String { accounts.first?.account.userName ?? "" }

    /// Records the row structure the view actually rendered so the next launch's
    /// skeleton matches it. Driven by the view (not derived here) because true
    /// visibility — e.g. whether the Libraries row survives the user's
    /// per-library Home-visibility choices — is only known at render time. Saves
    /// only on change to avoid redundant `UserDefaults` writes.
    public func rememberLayout(_ kinds: [HomeRowKind]) {
        guard kinds != skeletonLayout else { return }
        skeletonLayout = kinds
        layoutStore.save(kinds)
    }

    /// Loads on first appearance and re-aggregates only when the hidden-library
    /// set actually changed since the last successful load. tvOS cancels and
    /// restarts a `.task(id:)` every time Home reappears (returning from a pushed
    /// detail), so binding `load()` directly to the task would reload on every
    /// back-navigation — flashing the skeleton and resetting focus to the top.
    /// This guard makes the reappearance a no-op while still reacting to a genuine
    /// visibility change.
    public func loadIfNeeded(excludedKeys: Set<String>) async {
        switch state {
        case .loaded, .empty:
            if lastLoadedExcludedKeys == excludedKeys {
                return
            }
        default:
            break
        }
        await load()
    }

    public func load() async {
        PlozzLog.boot("HomeVM.load START vm=\(UInt(bitPattern: ObjectIdentifier(self).hashValue)) accounts=\(accounts.count) state=\(String(describing: state))")
        state = .loading

        let aggregator = self.aggregator
        let accounts = self.accounts
        let identitySources = self.identitySources
        let visibility = currentVisibility()
        let aggregationTask = Task.detached(priority: .userInitiated) {
            await aggregator.content(from: accounts, visibility: visibility, identitySources: identitySources)
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
        // Record what this content was aggregated for so a later reappearance with
        // an unchanged hidden-library set is recognised as a no-op (see
        // `loadIfNeeded(excludedKeys:)`).
        lastLoadedExcludedKeys = visibility.excludedKeys
        PlozzLog.boot("HomeVM.load DONE vm=\(UInt(bitPattern: ObjectIdentifier(self).hashValue)) empty=\(content.isEmpty) cw=\(content.continueWatching.count) latest=\(content.latest.count) libs=\(content.libraries.count)")
        guard !Task.isCancelled else { return }

        // Publish the playable rows to the App Group so the Top Shelf extension
        // can render them while the app is closed. Tracked so teardown cancels it.
        // Apply the same Home-visibility filter so a hidden library's items don't
        // leak into Top Shelf.
        let isLibraryVisible: (String) -> Bool = { visibility.isVisible($0) }
        let continueWatching = content.continueWatching.filter { $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible) }
        let latest = content.latest.filter { $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible) }
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
        // A resume/progress change means the user actually *played* the title just
        // now, so bump its recency and re-sort Continue Watching to float it to the
        // front without a full reload. A bare mark-watched / favourite toggle from
        // the context menu carries no progress and must NOT reorder the row — the
        // user's focus stays put while the badge flips in place.
        let reflectsPlayback = (mutation.resumePosition ?? 0) > 0
            || (mutation.playedPercentage.map { $0 > 0 && $0 < 1 } ?? false)
        if reflectsPlayback {
            let now = Date()
            let stamped = content.continueWatching.map { item -> MediaItem in
                var updated = apply(mutation, to: item)
                if mutation.itemIDs.contains(item.id) { updated.lastPlayedAt = now }
                return updated
            }
            content.continueWatching = HomeAggregator.sortedByRecency(stamped)
        } else {
            content.continueWatching = content.continueWatching.map { apply(mutation, to: $0) }
        }
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
