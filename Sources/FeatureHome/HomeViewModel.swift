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
        /// Whether Home is in merged mode. `true` (default) uses the classic
        /// cross-server rows (`latest`/`libraries`); `false` means the profile
        /// turned off "Merge libraries on Home" and `librarySections` carries the
        /// per-library blocks instead.
        public var mergeLibraries: Bool = true
        /// Per-library section blocks — populated only in unmerged mode. Each
        /// library's own Continue Watching / Recently Added / discovery-hub rows.
        public var librarySections: [HomeLibrarySectionGroup] = []

        public var isEmpty: Bool {
            continueWatching.isEmpty && latest.isEmpty && watchlist.isEmpty
                && libraries.isEmpty && librarySections.isEmpty
        }
    }

    public private(set) var state: LoadState<Content> = .idle

    /// The row structure to render as a skeleton while loading: the layout
    /// persisted from the previous successful load (row kinds, order **and** the
    /// card count each row rendered, so the placeholder matches the user's real
    /// Home), falling back to a default on a first-ever launch.
    public private(set) var skeletonLayout: [HomeRowLayout]

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

    /// A snapshot of the durable watch-outbox's not-yet-confirmed mutations, read
    /// at load time so the freshly-fetched Continue Watching row reflects plays the
    /// user just performed in-app that the servers haven't recorded yet (the outbox
    /// write is still queued / in-flight, or the server's Resume/OnDeck query is
    /// eventually-consistent). Without this, a reload momentarily reverts the row to
    /// stale pre-play order — the reported "Continue Watching keeps shifting / isn't
    /// what I watched last" symptom. Defaults to none so existing callers/tests are
    /// unaffected. (r8-cw-outbox-patch)
    private let pendingWatchMutations: @Sendable () async -> [WatchMutation]

    /// A snapshot of recently-applied in-progress resume writes (keyed by
    /// `"accountID:itemID"`), read at load time so the Continue Watching overlay can
    /// clamp a server's drain-time timestamp inflation back down to the play's real
    /// time. Plex's `/:/progress` stamps its own server-side view timestamp and can't
    /// backdate it, so an *offline-queued* resume write that drains late otherwise
    /// re-floats a stale title to the top of the row on the next reload. Records are
    /// short-lived, so this never overrides a genuine later play (e.g. on another
    /// client). Defaults to none so existing callers/tests are unaffected. (h2-cw-clamp)
    private let recentlyAppliedRecency: @Sendable () async -> [String: AppliedResumeRecord]

    /// In-flight content aggregation (run off the main actor) and the fire-and-
    /// forget Top Shelf publish. Tracked so ``deinit`` can cancel them — otherwise
    /// a Home model torn down mid-load (or one that just falls out of scope in a
    /// unit test) leaks detached work that outlives it, occupying the cooperative
    /// pool and, in tests, surviving the case to trip the simulator watchdog.
    // `nonisolated(unsafe)` so the nonisolated `deinit` can cancel these. Mutated
    // only on the main actor; `deinit` runs after the last reference is gone.
    private nonisolated(unsafe) var aggregationTask: Task<HomeAggregator.Content, Never>?
    /// The unmerged counterpart of `aggregationTask` (populated when the profile
    /// has turned off "Merge libraries on Home"). Tracked so `deinit` can cancel it.
    private nonisolated(unsafe) var unmergedTask: Task<HomeAggregator.UnmergedContent, Never>?
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

    /// The full visibility snapshot the currently-loaded content was aggregated
    /// for — Home-hidden **and** app-wide-disabled sets **and** the merge switch.
    /// `nil` until the first successful load. Used by ``loadIfNeeded(for:)`` to tell
    /// a genuine input change (hide/show/disable a library, or flip merge) apart
    /// from a mere view reappearance — tvOS restarts a `.task(id:)` every time Home
    /// returns from a pushed detail, so an unguarded reload would re-fetch (flashing
    /// the skeleton) and rebuild the rows (yanking focus to the top) on every
    /// back-navigation. Comparing the whole value (not just `excludedKeys`) means a
    /// disable/enable or a merged↔unmerged flip correctly forces a re-aggregation,
    /// since both change what Home fetches and renders.
    private var lastLoadedVisibility: HomeLibraryVisibility?

    public init(
        accounts: [ResolvedAccount],
        aggregator: HomeAggregator = HomeAggregator(),
        layoutStore: HomeLayoutStoring = HomeLayoutStore(),
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        currentVisibility: @escaping () -> HomeLibraryVisibility = { .default },
        pendingWatchMutations: @escaping @Sendable () async -> [WatchMutation] = { [] },
        recentlyAppliedRecency: @escaping @Sendable () async -> [String: AppliedResumeRecord] = { [:] }
    ) {
        self.accounts = accounts
        self.aggregator = aggregator
        self.layoutStore = layoutStore
        self.identitySources = identitySources
        self.currentVisibility = currentVisibility
        self.pendingWatchMutations = pendingWatchMutations
        self.recentlyAppliedRecency = recentlyAppliedRecency
        let persisted = layoutStore.load()
        self.skeletonLayout = persisted.isEmpty ? HomeRowKind.defaultSkeletonLayout : persisted
    }

    deinit {
        aggregationTask?.cancel()
        unmergedTask?.cancel()
        topShelfPublishTask?.cancel()
        reenrichTask?.cancel()
    }

    /// User-facing name for the greeting header — the primary (first) account.
    public var userName: String { accounts.first?.account.userName ?? "" }

    /// Records the row structure the view actually rendered — each row's kind and
    /// the number of cards it showed — so the next launch's skeleton matches it.
    /// Driven by the view (not derived here) because true visibility — e.g.
    /// whether the Libraries row survives the user's per-library Home-visibility
    /// choices, and how many items/tiles each row ends up with — is only known at
    /// render time. Saves only on change to avoid redundant `UserDefaults` writes.
    public func rememberLayout(_ layout: [HomeRowLayout]) {
        guard layout != skeletonLayout else { return }
        skeletonLayout = layout
        layoutStore.save(layout)
    }

    /// Loads on first appearance and re-aggregates only when the visibility
    /// snapshot actually changed since the last successful load. tvOS cancels and
    /// restarts a `.task(id:)` every time Home reappears (returning from a pushed
    /// detail), so binding `load()` directly to the task would reload on every
    /// back-navigation — flashing the skeleton and resetting focus to the top.
    /// This guard makes the reappearance a no-op while still reacting to a genuine
    /// change: hiding/showing/disabling a library, or flipping the merge switch.
    public func loadIfNeeded(for visibility: HomeLibraryVisibility) async {
        switch state {
        case .loaded, .empty:
            if lastLoadedVisibility == visibility {
                return
            }
        default:
            break
        }
        await load()
    }

    public func load() async {
        await load(showLoadingState: true)
    }

    /// Re-aggregates Home content. `showLoadingState` is `false` for a *silent*
    /// refresh (e.g. surfacing a brand-new resume after playback) — the currently
    /// loaded rows stay on screen until the fresh content swaps in, so there's no
    /// skeleton flash or focus reset for a background update.
    public func load(showLoadingState: Bool) async {
        PlozzLog.boot("HomeVM.load START vm=\(UInt(bitPattern: ObjectIdentifier(self).hashValue)) accounts=\(accounts.count) state=\(String(describing: state)) silent=\(!showLoadingState)")
        if showLoadingState { state = .loading }

        let aggregator = self.aggregator
        let accounts = self.accounts
        let identitySources = self.identitySources
        let visibility = currentVisibility()

        // Watchlist policy: an explicit user save is exempt from *Home-hidden*
        // (`excludedKeys`) — hiding a library from Home never drops a title the user
        // watchlisted. But an **app-wide disabled** library is hidden everywhere, so
        // a watchlisted title whose libraries are ALL disabled is dropped. Items
        // with no resolvable library stay (fail-open). Applied here so it also
        // governs the hero (which seeds from the watchlist), not just the row.
        let keepWatchlisted: (MediaItem) -> Bool = { item in
            item.isVisibleOnHome(isLibraryVisible: { visibility.isEnabled($0) })
        }

        // Overlay the durable outbox's not-yet-confirmed plays onto the freshly
        // fetched Continue Watching row so a reload doesn't revert it to stale
        // pre-play order while the server catches up (r8-cw-outbox-patch).
        let content: Content
        if visibility.mergeLibrariesOnHome {
            let aggregationTask = Task.detached(priority: .userInitiated) {
                await aggregator.content(from: accounts, visibility: visibility, identitySources: identitySources)
            }
            self.aggregationTask = aggregationTask
            let merged = await aggregationTask.value
            guard !Task.isCancelled else { return }
            let pending = await pendingWatchMutations()
            let appliedRecency = await recentlyAppliedRecency()
            let reconciledCW = Self.reconcileContinueWatching(merged.continueWatching, pending: pending, appliedRecency: appliedRecency)
            content = Content(
                continueWatching: reconciledCW,
                latest: merged.latest,
                watchlist: merged.watchlist.filter(keepWatchlisted),
                libraries: merged.libraries
            )
        } else {
            // Unmerged: global Continue Watching + Watchlist stay at the top, then
            // each visible library gets its own block of rows.
            let unmergedTask = Task.detached(priority: .userInitiated) {
                await aggregator.unmergedContent(from: accounts, visibility: visibility, identitySources: identitySources)
            }
            self.unmergedTask = unmergedTask
            let unmerged = await unmergedTask.value
            guard !Task.isCancelled else { return }
            let pending = await pendingWatchMutations()
            let appliedRecency = await recentlyAppliedRecency()
            let reconciledCW = Self.reconcileContinueWatching(unmerged.continueWatching, pending: pending, appliedRecency: appliedRecency)
            // Re-slice each library's Continue Watching from the reconciled feed,
            // then apply the "merge Continue Watching" choice so resumes appear in
            // exactly one place (global row OR per-library rows, never both).
            let reslicedSections = Self.reslicingLibraryContinueWatching(unmerged.librarySections, reconciledCW: reconciledCW)
            let cwMerge = Self.applyingContinueWatchingMerge(
                global: reconciledCW,
                sections: reslicedSections,
                mergeContinueWatching: visibility.mergeContinueWatchingOnHome
            )
            content = Content(
                continueWatching: cwMerge.global,
                latest: [],
                watchlist: unmerged.watchlist.filter(keepWatchlisted),
                libraries: [],
                mergeLibraries: false,
                librarySections: cwMerge.sections
            )
        }
        state = content.isEmpty ? .empty : .loaded(content)
        // Record what this content was aggregated for so a later reappearance with
        // an unchanged visibility snapshot is recognised as a no-op (see
        // `loadIfNeeded(for:)`).
        lastLoadedVisibility = visibility
        PlozzLog.boot("HomeVM.load DONE vm=\(UInt(bitPattern: ObjectIdentifier(self).hashValue)) empty=\(content.isEmpty) merged=\(content.mergeLibraries) cw=\(content.continueWatching.count) latest=\(content.latest.count) libs=\(content.libraries.count) sections=\(content.librarySections.count)")
        guard !Task.isCancelled else { return }

        // Publish the playable rows to the App Group so the Top Shelf extension
        // can render them while the app is closed. Tracked so teardown cancels it.
        // Apply the same Home-visibility filter so a hidden library's items don't
        // leak into Top Shelf. In unmerged mode there is no global Latest row, so
        // Top Shelf's "recently added" is the per-library Recently Added rows
        // flattened (already scoped to visible libraries + tagged).
        let isLibraryVisible: (String) -> Bool = { visibility.isVisible($0) }
        let continueWatching = content.continueWatching.filter { $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible) }
        let latest: [MediaItem]
        if content.mergeLibraries {
            latest = content.latest.filter { $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible) }
        } else {
            latest = content.librarySections.flatMap { group in
                group.sections.first { $0.id == "recentlyAdded" }?.items ?? []
            }
        }
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
        // A brand-new *in-progress* resume for a title that isn't on any Home row
        // yet can't be updated in place — the mutation carries only ids + state, not
        // a full card to synthesise. In-place mapping (below) would leave Continue
        // Watching unchanged, so the just-started title never appears until the next
        // full reload (relaunch). Detect that case here and trigger a *silent*
        // re-aggregation so the new card is fetched from its provider (a media
        // share reads its freshly-persisted local resume off disk) and slots in —
        // no skeleton flash, no focus reset. Gated to an in-progress resume (not a
        // finish, which *leaves* Continue Watching) that matches nothing already
        // loaded, so a normal re-watch or mark-watched never forces a reload.
        let isInProgressResume = (mutation.resumePosition ?? 0) > 0 && !(mutation.played ?? false)
        let alreadyOnHome = content.continueWatching.contains { mutation.targets($0) }
        if isInProgressResume && !alreadyOnHome {
            scheduleNewResumeReload()
        }
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
            // recency sort here: the loaded row no longer carries the per-server
            // feeds, and re-sorting a row whose just-played cards we've optimistically
            // stamped to `now` would reshuffle it out from under the user. A stable
            // partition ("just watched" → top, everyone else in place) is the correct,
            // focus-preserving reorder.
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

    /// In-flight guard so a burst of resume ticks for a not-yet-loaded title
    /// coalesces into a single silent re-aggregation instead of stacking reloads.
    private var newResumeReloadInFlight = false

    /// Silently re-aggregates Home to surface a brand-new resume that couldn't be
    /// updated in place (see ``applyWatchedState(_:)``). No-op while a reload is
    /// already running, and only ever runs against currently-loaded content so it
    /// can't fight the initial load or a visibility-driven reload.
    private func scheduleNewResumeReload() {
        guard !newResumeReloadInFlight, case .loaded = state else { return }
        newResumeReloadInFlight = true
        Task { [weak self] in
            guard let self else { return }
            await self.load(showLoadingState: false)
            self.newResumeReloadInFlight = false
        }
    }

    /// Overlays the durable watch-outbox's **not-yet-confirmed** mutations onto a
    /// freshly-fetched Continue Watching row, so a reload reflects what the user
    /// just played in-app even before every server's Resume/OnDeck query catches up.
    ///
    /// Matching is by **exact server target** — a pending mutation's
    /// `(accountID, itemID)` targets against each card's source refs (and the card's
    /// own `sourceAccountID:id` for un-merged single-source cards). No canonical-id
    /// recomputation: the outbox already addresses the precise server rows, so this
    /// can't accidentally re-merge unrelated titles.
    ///
    /// For each matched card, only when the pending action is at least as recent as
    /// the card's server-reported recency (older/superseded writes are ignored):
    ///  - a **finished** play (`played == true`) drops the card — a watched title
    ///    leaves Continue Watching, anticipating the server's own removal;
    ///  - an **in-progress** play (`resumePosition > 0`) stamps the card (and its
    ///    matching source refs) with the play's `capturedAt` recency + resume, so it
    ///    floats to the correct spot;
    ///  - anything else (e.g. a bare mark-*unwatched*) is left untouched — we never
    ///    fabricate recency for a non-play, nor invent a card the feed didn't return.
    ///
    /// The row is then re-sorted with the aggregator's exact recency comparator so
    /// the overlaid stamps take effect. Pure and side-effect-free for testability.
    ///
    /// **Drain-time inflation clamp (`appliedRecency`).** Some servers (Plex) stamp
    /// their own view timestamp on an out-of-band resume write and can't backdate it,
    /// so an *offline-queued* resume that drains late converges at the drain clock —
    /// re-floating a stale title to the top on the next reload even though nothing was
    /// re-watched. For each source we recently applied an in-progress resume to, this
    /// clamps that source's `lastPlayedAt` back **down** to the play's real
    /// `capturedAt` (recomputing the card's folded recency), but only while the record
    /// is fresh, so it can never override a genuine later play (e.g. on another
    /// client). Clamp-only-downward: worst case a card sits slightly lower, never
    /// wrongly at the top. (h2-cw-clamp)
    /// Applies the "merge Continue Watching" choice to the unmerged content.
    ///
    /// Continue Watching is shown in exactly ONE place — never both globally and
    /// per-library:
    /// - `merge == true` (default): keep the global Continue Watching row and strip
    ///   the per-library `"continueWatching"` section from every library block
    ///   (dropping a block left with no rows).
    /// - `merge == false`: hide the global row and keep the per-library rows.
    nonisolated static func applyingContinueWatchingMerge(
        global: [MediaItem],
        sections: [HomeLibrarySectionGroup],
        mergeContinueWatching: Bool
    ) -> (global: [MediaItem], sections: [HomeLibrarySectionGroup]) {
        guard mergeContinueWatching else {
            // Per-library Continue Watching is canonical; hide the global row.
            return ([], sections)
        }
        let stripped = sections.compactMap { group -> HomeLibrarySectionGroup? in
            let kept = group.sections.filter { $0.id != "continueWatching" }
            return kept.isEmpty ? nil : HomeLibrarySectionGroup(library: group.library, sections: kept)
        }
        return (global, stripped)
    }

    /// Re-derives each unmerged library block's **Continue Watching** row from the
    /// *reconciled* global feed, so a just-played title's optimistic reorder /
    /// progress (the durable-outbox overlay) shows in the per-library row too — not
    /// only the global one. The aggregator seeds these rows from the un-reconciled
    /// feed (to decide block inclusion); this overlays the reconciled slice. A block
    /// whose Continue Watching empties after reconciliation drops that row, and a
    /// block left with no rows is removed.
    nonisolated static func reslicingLibraryContinueWatching(
        _ groups: [HomeLibrarySectionGroup],
        reconciledCW: [MediaItem]
    ) -> [HomeLibrarySectionGroup] {
        groups.compactMap { group in
            let key = group.library.key
            let cw = reconciledCW.filter { $0.homeVisibilityLibraryKeys.contains(key) }
            var sections = group.sections
            let cwSection = LibrarySection(id: "continueWatching", title: "Continue Watching", style: .landscape, items: cw)
            if let idx = sections.firstIndex(where: { $0.id == "continueWatching" }) {
                if cw.isEmpty { sections.remove(at: idx) } else { sections[idx] = cwSection }
            } else if !cw.isEmpty {
                sections.insert(cwSection, at: 0)
            }
            return sections.isEmpty ? nil : HomeLibrarySectionGroup(library: group.library, sections: sections)
        }
    }

    nonisolated static func reconcileContinueWatching(
        _ items: [MediaItem],
        pending: [WatchMutation],
        appliedRecency: [String: AppliedResumeRecord] = [:],
        now: Date = Date(),
        clampFreshness: TimeInterval = 30 * 60
    ) -> [MediaItem] {
        guard !pending.isEmpty || !appliedRecency.isEmpty else { return items }

        func targetKey(_ accountID: String, _ itemID: String) -> String { accountID + "\u{1}" + itemID }
        let pendingByTarget: [String: [WatchMutation]] = pending.reduce(into: [:]) { acc, m in
            for t in m.targets { acc[targetKey(t.accountID, t.itemID), default: []].append(m) }
        }

        func newestMatch(for item: MediaItem) -> WatchMutation? {
            var keys = Set(item.sources.map { targetKey($0.accountID, $0.itemID) })
            if let account = item.sourceAccountID { keys.insert(targetKey(account, item.id)) }
            guard !keys.isEmpty else { return nil }
            var best: WatchMutation?
            for key in keys {
                for m in pendingByTarget[key] ?? [] where best == nil || m.capturedAt > best!.capturedAt {
                    best = m
                }
            }
            return best
        }

        var overlaid: [MediaItem] = []
        overlaid.reserveCapacity(items.count)
        for rawItem in items {
            // Undo any server drain-time timestamp inflation before the pending
            // overlay reads the card's recency, so an offline-drained Plex resume
            // can't leave a stale play floating at the top.
            let item = appliedRecency.isEmpty
                ? rawItem
                : clampInflatedRecency(rawItem, appliedRecency: appliedRecency, now: now, clampFreshness: clampFreshness)
            guard let m = newestMatch(for: item) else { overlaid.append(item); continue }
            // Ignore a pending write the server has already superseded with a newer play.
            guard m.capturedAt >= (item.lastPlayedAt ?? .distantPast) else { overlaid.append(item); continue }

            if m.played == true {
                // Finished / marked-watched: the title leaves Continue Watching.
                continue
            }
            guard let resume = m.resumePosition, resume > 0 else {
                // A non-play mutation (e.g. mark-unwatched) — don't reorder or drop.
                overlaid.append(item)
                continue
            }
            var updated = item
            updated.lastPlayedAt = m.capturedAt
            updated.resumePosition = resume
            let targetKeys = Set(m.targets.map { targetKey($0.accountID, $0.itemID) })
            updated.sources = updated.sources.map { ref in
                guard targetKeys.contains(targetKey(ref.accountID, ref.itemID)) else { return ref }
                var r = ref
                if (r.lastPlayedAt ?? .distantPast) < m.capturedAt { r.lastPlayedAt = m.capturedAt }
                r.resumePosition = resume
                return r
            }
            overlaid.append(updated)
        }
        return HomeAggregator.sortedByRecency(overlaid)
    }

    /// Clamps a card's server-reported recency **down** to the real play time for any
    /// source we recently applied an in-progress resume to, undoing a server's
    /// drain-time timestamp inflation (see ``reconcileContinueWatching``). Only fires
    /// while the record is fresh (`now − appliedAt ≤ clampFreshness`, device clock)
    /// and only when the server shows something newer than the true play — so it can
    /// never lower a genuine later play made elsewhere. Downward-only.
    nonisolated private static func clampInflatedRecency(
        _ item: MediaItem,
        appliedRecency: [String: AppliedResumeRecord],
        now: Date,
        clampFreshness: TimeInterval
    ) -> MediaItem {
        func recordKey(_ accountID: String, _ itemID: String) -> String { accountID + ":" + itemID }
        func freshCapture(_ accountID: String, _ itemID: String) -> Date? {
            guard let record = appliedRecency[recordKey(accountID, itemID)],
                  now.timeIntervalSince(record.appliedAt) <= clampFreshness else { return nil }
            return record.capturedAt
        }

        var updated = item
        if !updated.sources.isEmpty {
            var didClamp = false
            updated.sources = updated.sources.map { ref in
                guard let capturedAt = freshCapture(ref.accountID, ref.itemID),
                      let reported = ref.lastPlayedAt, reported > capturedAt else { return ref }
                didClamp = true
                var r = ref
                r.lastPlayedAt = capturedAt
                return r
            }
            guard didClamp else { return item }
            // Re-fold the card's recency from the clamped sources (most-recent-wins);
            // only ever lower it, never raise.
            if let folded = MediaItemMerger.unifiedWatchState(from: updated.sources).lastPlayedAt,
               folded < (updated.lastPlayedAt ?? .distantFuture) {
                updated.lastPlayedAt = folded
            }
            return updated
        }
        // Un-merged single-source card: no source refs, recency is on the item.
        if let account = item.sourceAccountID,
           let capturedAt = freshCapture(account, item.id),
           let reported = item.lastPlayedAt, reported > capturedAt {
            updated.lastPlayedAt = capturedAt
        }
        return updated
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
