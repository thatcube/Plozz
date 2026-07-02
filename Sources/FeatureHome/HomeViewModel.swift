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
        reenrichTask?.cancel()
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
        if reflectsPlayback {
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
            // recency sort here: that sort's carry-forward anchor is computed per
            // *feed* (pre-interleave, see `HomeAggregator.effectiveRecency`) and the
            // loaded row no longer carries those feeds, so re-sorting it would drop
            // every untimestamped "Next Up" card to the bottom and reshuffle the row
            // out from under the user. A stable partition ("just watched" → top,
            // everyone else in place) is the correct, focus-preserving reorder.
            let played = stamped.filter { mutation.targets($0) }
            let rest = stamped.filter { !mutation.targets($0) }
            content.continueWatching = played + rest
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
    public func scheduleReenrich() {
        reenrichTask?.cancel()
        reenrichTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reenrichDebounce)
            guard !Task.isCancelled, let self else { return }
            self.reenrich()
        }
    }

    private func apply(_ mutation: MediaItemMutation, to item: MediaItem) -> MediaItem {
        mutation.applied(to: item)
    }
}
