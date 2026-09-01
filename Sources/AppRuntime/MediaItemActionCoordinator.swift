import Foundation
import CoreModels
import CoreNetworking

/// App-level handler behind every card's press-and-hold menu.
///
/// It is the one place that knows how to turn a `MediaItem` (tagged with its
/// owning `sourceAccountID`) back into a concrete provider, perform the chosen
/// action against the server, and tell visible screens to refresh. Cards reach
/// it through the SwiftUI environment (`\.mediaItemActionHandler`) so no closure
/// has to be threaded through every row and grid.
///
/// Resolution is always live through injected app-runtime seams so account and
/// profile changes are picked up without rebuilding the handler.
@MainActor
public final class MediaItemActionCoordinator: MediaItemActionHandling {
    private let providerResolver: (String?) -> (any MediaProvider)?
    private let providerCapabilityResolver:
        (String?) -> (
            supportsWatchState: Bool,
            supportsWatchlist: Bool,
            supportsMetadataRefresh: Bool
        )?
    private let additionalSources: (MediaItem) -> [MediaSourceRef]
    private let primaryAccountID: () -> String?
    private let crossServerWatchSyncEnabled: () -> Bool
    private let enqueueWatchMutation: (WatchMutation) -> Void
    private let universalWatchlistEnabled: () -> Bool
    private let watchlistMembership: (MediaItem) -> Bool
    /// A cheap value that changes whenever anything membership depends on changes.
    private let watchlistMembershipRevision: () -> UInt64
    private let performUniversalWatchlist:
        @MainActor (Bool, MediaItem) async -> Bool
    private let presentUniversalWatchlistFeedback:
        @MainActor (String, LocalizedStringResource) -> Void
    private let beginUniversalWatchlistFanOut:
        @MainActor (Bool, MediaItem) -> Void
    private let resolveDurableWatchlist: ([MediaItem]) -> [MediaItem]
    private let durableWatchlistPresentationReady: () -> Bool
    private let rehydratePersistedArtworkItems:
        ([MediaItem]) -> [MediaItem]
    private let seedLegacyUniversalWatchlist: ([MediaItem]) async -> Void
    /// Current offline state for an item, or `nil` on a surface without download
    /// capability. Injected as a closure so AppRuntime needn't depend on
    /// MediaDownloads — and so tvOS, which has no downloads, simply omits it.
    /// Cached provider CAPABILITIES per account id.
    ///
    /// Building a menu needs only three `is` checks, but `providerResolver`
    /// constructs a live provider — which reads the Keychain, JSON-decodes the
    /// persisted account list, and loads credential-journal state. SwiftUI calls
    /// `actions(for:)` from every card's `body`, so during a scroll that ran per
    /// card per frame: a Time Profiler capture on iPad put
    /// `MediaItemActionCoordinator.actions(for:context:)` in 27% of all samples,
    /// with `AccountPersisting.token(for:)` alone at 24.6%.
    ///
    /// Capabilities are a property of the account's provider TYPE, so they can't
    /// change without the account set changing — `invalidateCapabilityCache()`
    /// covers that.
    private var capabilityCache: [String: ProviderCapabilities] = [:]

    /// Cached watchlist MEMBERSHIP per item, for the same reason as the capability
    /// cache above and on exactly the same hot path.
    ///
    /// Answering "is this watchlisted" resolves the item's universal identity, which
    /// walks the identity index's transitive component graph and builds alias
    /// evidence. That is fine once per item; it is not fine per card per frame, which
    /// is what `actions(for:)` runs at. Measured on the Apple TV before this cache:
    /// sustained 200–500 ms main-thread stalls on an idle Home with the view body
    /// re-evaluating 1–6 times a second.
    ///
    /// Keyed by the item's own coordinates — cheap and stable — and thrown away
    /// wholesale whenever the identity index, the alias ledger or the watchlist
    /// changes, so a heart can never be answered from a stale world.
    private var membershipCache: [String: Bool] = [:]
    private var membershipRevision: UInt64?
    private var watchlistChangeObserver: (any NSObjectProtocol)?

    /// The watchlist state the viewer has most recently ASKED for, per title,
    /// while the durable write catches up.
    ///
    /// The button has to answer the moment it is pressed, and the truth it would
    /// otherwise read cannot: `performUniversalWatchlist` awaits the alias ledger,
    /// which is an actor hop and a durable write, and only then announces. Brandon
    /// measured the gap at 2-3 seconds — the toast said "Removed" while the button
    /// still read Added.
    ///
    /// So membership answers from intent while one is recorded. This is not the
    /// button lying: a press the app has accepted and is committed to completing
    /// is part of the state, and the write below is what makes it true. The intent
    /// is dropped the moment the durable read agrees, and reverted if the write
    /// fails, so the two can never end up disagreeing silently.
    private var watchlistIntents: [String: Bool] = [:]

    /// Titles with a write in flight. One writer per title, so a burst of presses
    /// cannot interleave: without this, two taps race two `resolveOrCreate` +
    /// write sequences that can land out of order and leave the durable state on
    /// the LOSING press. The writer re-reads ``watchlistIntents`` after each pass
    /// and keeps going until it has written what the viewer last asked for.
    private var watchlistWriters: Set<String> = []

    /// Watchlist notifications this coordinator is itself about to cause.
    ///
    /// A successful local write posts `universalWatchlistDidChange`, and the
    /// observer below answers that by discarding the whole membership memo. For
    /// a change we made ourselves that is pure waste — we already patched the one
    /// entry that moved — and it is expensive waste, because every remaining entry
    /// then has to be resolved again from cold while the viewer waits for the
    /// button to move. Our own echo is counted here and skipped; a change from
    /// anywhere else still discards the memo, which is what that observer is for.
    private var expectedSelfWatchlistNotifications = 0

    /// The key both the read and the write use to talk about one title. Shared
    /// deliberately: the last three watchlist defects were all one truth reached
    /// by two paths that derived their key differently.
    /// How long a written-and-confirmed intent may outlive a durable read that
    /// still disagrees with it, before the read wins anyway.
    private static let watchlistIntentGrace: TimeInterval = 5

    private static func membershipKey(_ item: MediaItem) -> String {
        "\(item.sourceAccountID ?? "-"):\(item.id)"
    }

    private struct ProviderCapabilities {
        let supportsWatchState: Bool
        let supportsWatchlist: Bool
        let supportsMetadataRefresh: Bool
    }

    private let downloadState: (MediaItem) -> MediaItemDownloadState??
    private let performDownloadAction: (MediaItemAction, MediaItem) -> Void

    public init(
        providerResolver: @escaping (String?) -> (any MediaProvider)?,
        providerCapabilityResolver: @escaping (String?) -> (
            supportsWatchState: Bool,
            supportsWatchlist: Bool,
            supportsMetadataRefresh: Bool
        )? = { _ in nil },
        additionalSources: @escaping (MediaItem) -> [MediaSourceRef] = { _ in [] },
        primaryAccountID: @escaping () -> String?,
        crossServerWatchSyncEnabled: @escaping () -> Bool,
        enqueueWatchMutation: @escaping (WatchMutation) -> Void,
        universalWatchlistEnabled: @escaping () -> Bool = { false },
        watchlistMembership: @escaping (MediaItem) -> Bool = { _ in false },
        watchlistMembershipRevision: @escaping () -> UInt64 = { 0 },
        performUniversalWatchlist:
            @escaping @MainActor (Bool, MediaItem) async -> Bool = { _, _ in
                false
            },
        presentUniversalWatchlistFeedback:
            @escaping @MainActor (
                String,
                LocalizedStringResource
            ) -> Void = { _, _ in },
        beginUniversalWatchlistFanOut:
            @escaping @MainActor (Bool, MediaItem) -> Void = { _, _ in },
        resolveDurableWatchlist: @escaping ([MediaItem]) -> [MediaItem] = {
            $0.filter(\.isFavorite)
        },
        durableWatchlistPresentationReady: @escaping () -> Bool = { true },
        rehydratePersistedArtworkItems:
            @escaping ([MediaItem]) -> [MediaItem] = { $0 },
        seedLegacyUniversalWatchlist: @escaping ([MediaItem]) async -> Void = { _ in },
        downloadState: @escaping (MediaItem) -> MediaItemDownloadState?? = { _ in nil },
        performDownloadAction: @escaping (MediaItemAction, MediaItem) -> Void = { _, _ in }
    ) {
        self.providerResolver = providerResolver
        self.providerCapabilityResolver = providerCapabilityResolver
        self.additionalSources = additionalSources
        self.primaryAccountID = primaryAccountID
        self.crossServerWatchSyncEnabled = crossServerWatchSyncEnabled
        self.enqueueWatchMutation = enqueueWatchMutation
        self.universalWatchlistEnabled = universalWatchlistEnabled
        self.watchlistMembership = watchlistMembership
        self.watchlistMembershipRevision = watchlistMembershipRevision
        self.performUniversalWatchlist = performUniversalWatchlist
        self.presentUniversalWatchlistFeedback =
            presentUniversalWatchlistFeedback
        self.beginUniversalWatchlistFanOut = beginUniversalWatchlistFanOut
        self.resolveDurableWatchlist = resolveDurableWatchlist
        self.durableWatchlistPresentationReady =
            durableWatchlistPresentationReady
        self.rehydratePersistedArtworkItems =
            rehydratePersistedArtworkItems
        self.seedLegacyUniversalWatchlist = seedLegacyUniversalWatchlist
        self.downloadState = downloadState
        self.performDownloadAction = performDownloadAction
        // Every membership memo drops together, or none of them mean anything.
        //
        // `announceUniversalWatchlistDidChange` invalidates the process-wide
        // membership set, but this per-item memo is keyed on the same O(1) count
        // revision and so is blind to exactly the changes that set was: a removal
        // of a title whose presence came from a destination's own list, or a
        // remote sync that adds and drops the same number of titles. A local
        // toggle clears it outright below; this covers every OTHER way the
        // watchlist moves.
        watchlistChangeObserver = NotificationCenter.default.addObserver(
            forName: .universalWatchlistDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Our own write, already accounted for entry by entry.
                if self.expectedSelfWatchlistNotifications > 0 {
                    self.expectedSelfWatchlistNotifications -= 1
                    return
                }
                self.membershipCache.removeAll(keepingCapacity: true)
                self.membershipRevision = nil
            }
        }
    }

    deinit {
        if let watchlistChangeObserver {
            NotificationCenter.default.removeObserver(watchlistChangeObserver)
        }
    }

    /// Tell the watchlist controls to re-ask, and nothing else to do any work.
    ///
    /// The coordinator is not `@Observable` — deliberately, since `actions(for:)`
    /// runs from view bodies and mutates the memo above — so changing intent moves
    /// nothing on its own and the surfaces need telling.
    ///
    /// This deliberately does NOT raise `universalWatchlistDidChange`. Doing that
    /// was the first attempt and it made the very thing it was fixing worse: that
    /// notification runs Home's full identity re-resolve and a content-store save
    /// on the main thread, so the frame carrying the button's new state couldn't
    /// be drawn until it finished. Nothing durable has changed at this point
    /// anyway — a press has been accepted, which is exactly what the cheap
    /// notification means.
    private func announceWatchlistIntentChanged() {
        NotificationCenter.default.post(
            name: .watchlistIntentDidChange,
            object: nil
        )
    }

    public func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
        // A not-in-library discovery (Seerr) title has a synthetic `seer:<tmdbId>`
        // id that isn't addressable on any provider, so watch-state / watchlist /
        // refresh actions would silently fail — offer none (the discovery detail
        // page surfaces a Request affordance instead). This deliberately excludes
        // *owned* featured titles (available/partiallyAvailable), which resolve to a
        // real library copy via the identity index and keep their working actions.
        let isExternalDiscovery = TitleClassifier.isDiscoveryRouting(
            item,
            identitySources: additionalSources(item)
        )
        // An unaired episode exists on no server, so every action here — watch
        // state, watchlist, refresh, download — would silently fail.
        guard !item.isUpcomingUnaired else { return [] }
        let capabilities = isExternalDiscovery
            ? ProviderCapabilities(
                supportsWatchState: false,
                supportsWatchlist: false,
                supportsMetadataRefresh: false
            )
            : capabilities(for: item)
        let universalEnabled = universalWatchlistEnabled()
        return MediaItemActionCatalog.actions(
            for: item,
            supportsWatchState: capabilities.supportsWatchState,
            supportsWatchlist: universalEnabled
                ? false
                : capabilities.supportsWatchlist,
            isWatchlisted: universalEnabled
                ? cachedWatchlistMembership(item)
                : nil,
            supportsMetadataRefresh: capabilities.supportsMetadataRefresh,
            downloadState: isExternalDiscovery ? nil : downloadState(item),
            context: context
        )
    }

    public func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {
        switch action {
        case .markWatched, .markUnwatched, .markWatchedUpToHere:
            performWatchState(action, on: item, context: context)
        case .addToWatchlist, .removeFromWatchlist:
            performWatchlist(adding: action == .addToWatchlist, on: item)
        case .refreshMetadata:
            performRefresh(on: item)
        case .removeFromContinueWatching:
            performRemoveFromContinueWatching(on: item)
        case .startDownload, .pauseDownload, .resumeDownload, .removeDownload:
            performDownloadAction(action, item)
        case .goToSeason, .goToMovie, .goToEpisode:
            // Navigation is handled in the view layer, never here.
            break
        }
    }

    // MARK: - Watched state

    private func performWatchState(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {
        switch action {
        case .markWatched, .markUnwatched:
            performPlayedToggle(played: action == .markWatched, on: item, action: action)
        case .markWatchedUpToHere:
            performMarkUpToHere(on: item, context: context)
        default:
            break
        }
    }

    /// Marks a whole title played/unplayed across **every** server that holds it,
    /// durably. The optimistic `MediaItemMutation` flips the badge immediately; the
    /// real fan-out is delegated to the ``WatchMutationOutbox`` so the write survives
    /// an asleep server, an offline app, or a kill mid-write, and is mirrored to
    /// Trakt (write-if-missing, never delete) when marking watched. No brittle
    /// revert-on-all-fail: a queued write retries until it lands ("fail toward
    /// writing").
    private func performPlayedToggle(played: Bool, on item: MediaItem, action: MediaItemAction) {
        guard let mutation = WatchMutationFactory.playedToggle(
            item: item,
            played: played,
            primaryAccountID: primaryAccountID(),
            additionalSources: additionalSources(item),
            crossServerSync: crossServerWatchSyncEnabled()
        ) else { return }

        var ids = Set(mutation.targets.map(\.itemID))
        ids.insert(item.id)
        // Account-scope the optimistic post to the exact (account,item) copies the
        // fan-out targeted (the origin is always among them), mirroring
        // `AppState.publishOptimisticWatchState`. Without this the bare `itemID` set
        // would false-match an unrelated title that happens to share a Plex
        // ratingKey on another server, flipping the wrong card's watched badge.
        let scoped = Set(mutation.targets.map(\.id))
        MediaItemMutation(
            itemIDs: ids,
            scopedItemIDs: scoped,
            played: played,
            resumePosition: played ? 0 : nil,
            playedPercentage: played ? 1 : nil
        ).post()

        enqueueWatchMutation(mutation)
    }

    /// Clears the title's saved position on every server holding it, taking it off
    /// Continue Watching without claiming it was watched.
    ///
    /// The optimistic post carries `resumePosition: 0`, which every surface already
    /// reads as "no longer in progress" — the card leaves the row at once and its
    /// progress bar goes, with no refetch and no focus change. The durable write
    /// then goes through the same outbox as every other watch action, so it
    /// survives an asleep server or a kill mid-write.
    ///
    /// `played` is deliberately left `nil`: the viewer said take it off the row,
    /// which is not a claim about having seen it.
    private func performRemoveFromContinueWatching(on item: MediaItem) {
        guard let mutation = WatchMutationFactory.removeFromContinueWatching(
            item: item,
            primaryAccountID: primaryAccountID(),
            additionalSources: additionalSources(item),
            crossServerSync: crossServerWatchSyncEnabled()
        ) else { return }

        var ids = Set(mutation.targets.map(\.itemID))
        ids.insert(item.id)
        let scoped = Set(mutation.targets.map(\.id))
        MediaItemMutation(
            itemIDs: ids,
            scopedItemIDs: scoped,
            resumePosition: 0,
            playedPercentage: 0
        ).post()

        enqueueWatchMutation(mutation)
    }

    /// "Mark watched up to here" stays scoped to the primary server: the preceding
    /// siblings are this server's episode ids, which don't map 1:1 onto another
    /// server's library, so fanning them out isn't meaningful. Best-effort per
    /// item so one unreachable episode doesn't abort the rest.
    private func performMarkUpToHere(on item: MediaItem, context: MediaItemActionContext) {
        guard let watch = provider(for: item) as? WatchStateProviding else { return }
        var ids = Set(context.precedingContainerIDs)
        ids.formUnion(MediaItemActionCatalog.siblingsToMarkUpToHere(item, in: context.orderedSiblings).map(\.id))
        ids.insert(item.id)
        // Account-scope the optimistic post so a Plex ratingKey shared with an
        // unrelated title on another server can't flip the wrong card. Every id
        // here is this server's own episode id, so they all carry the item's origin
        // account. Falls back to bare-id matching for an untagged item.
        let scoped: Set<String> = item.sourceAccountID.map { account in
            Set(ids.map { "\(account):\($0)" })
        } ?? []
        MediaItemMutation(
            itemIDs: ids,
            scopedItemIDs: scoped,
            played: true,
            resumePosition: 0,
            playedPercentage: 1
        ).post()
        Task {
            for id in ids {
                try? await watch.setPlayed(true, itemID: id)
            }
        }
    }

    // MARK: - Watchlist

    /// Adds or removes the item from the watchlist. The optimistic `favorite`
    /// mutation flips the badge / Home row immediately; the write then fans out
    /// across **every** account that holds this (possibly merged) title and can
    /// express a watchlist, so a save lands on both the user's Jellyfin Favorites
    /// and their Plex Watchlist when a title exists on both servers.
    ///
    /// Each server is written with the item **retargeted to that server's own id**
    /// (`selectingSource`): a favorite write is addressed by `item.id`, which is
    /// the *primary* server's local id (a Jellyfin item id or Plex ratingKey). Sent
    /// unchanged to another server it would hit a wrong / nonexistent id and the
    /// save would silently miss. The target set unions the card's own `sources`
    /// with the live identity index — the same source of truth the mark-watched
    /// fan-out uses — so a title only one server surfaced still saves everywhere.
    private func performWatchlist(adding: Bool, on item: MediaItem) {
        if universalWatchlistEnabled() {
            let performUniversalWatchlist = self.performUniversalWatchlist
            let presentFeedback = self.presentUniversalWatchlistFeedback
            let beginFanOut = self.beginUniversalWatchlistFanOut
            // Confirm FIRST, then do the work.
            //
            // The ledger write posts `.universalWatchlistDidChange` before it
            // returns, and every surface holding a watchlist rebuilds off that. The
            // toast used to be raised after all of it, so it was set and expired
            // while the main thread was still busy and no frame was ever drawn with
            // it on screen — a single press appeared to do nothing, and only a
            // second press within the display window (which resets the timer) made
            // one visible. Acknowledging the press before the storm is also simply
            // what the viewer expects: the confirmation belongs to the tap.
            let feedback = Self.universalWatchlistFeedback(adding: adding)
            presentFeedback(feedback.icon, feedback.text)

            // Record the intent BEFORE any await, and tell the world at once, so
            // the press is on screen this frame instead of after the ledger write.
            let key = Self.membershipKey(item)
            watchlistIntents[key] = adding
            announceWatchlistIntentChanged()

            // One writer per title. A second press while a write is in flight only
            // updates the intent above; the running writer picks it up when it
            // comes back round. That is what makes the button survive spamming —
            // presses can't each spawn a racing write and land out of order.
            guard !watchlistWriters.contains(key) else { return }
            watchlistWriters.insert(key)

            Task { @MainActor in
                defer {
                    self.watchlistWriters.remove(key)
                    self.announceWatchlistIntentChanged()
                }
                // Keep writing until what's on disk is what the viewer last asked
                // for. Re-read each pass: they may have pressed again mid-write.
                while let desired = self.watchlistIntents[key] {
                    // A successful write posts exactly one notification; claim it
                    // before it can be delivered.
                    self.expectedSelfWatchlistNotifications += 1
                    guard await performUniversalWatchlist(desired, item) else {
                        // It failed, so nothing was posted — give the claim back
                        // rather than swallow someone else's change later.
                        self.expectedSelfWatchlistNotifications -= 1
                        // Take the acknowledgement back rather than leaving a
                        // confirmation standing for something that did not happen,
                        // and drop the intent so the button falls back to the truth
                        // instead of showing a state we failed to reach.
                        self.watchlistIntents[key] = nil
                        presentFeedback(
                            "exclamationmark.triangle.fill",
                            LocalizedStringResource(
                                "watchlist.feedback.failed",
                                defaultValue: "Couldn't update Watchlist",
                                comment: "Transient message shown when saving a title to, or removing it from, the Watchlist did not succeed."
                            )
                        )
                        return
                    }
                    // Patch the one title that changed; do NOT throw the memo away.
                    //
                    // Discarding it made the press expensive in proportion to how
                    // much was on screen. Every entry had to be resolved again from
                    // cold on the next body pass, and resolving one is the identity
                    // graph walk this memo exists to avoid — on a series page, with
                    // a hero and a full episode rail asking `actions(for:)`, that is
                    // dozens of walks standing between the press and the frame that
                    // would show its result. It was worst on the FIRST press, when
                    // nothing was warm yet, which is exactly the shape Brandon saw:
                    // five to ten seconds cold, quick every time after.
                    //
                    // Adopting the new revision alongside the patch is the point: the
                    // count moved, so the next read would otherwise treat every entry
                    // as stale and discard them all anyway. One local toggle changes
                    // one title, and we know which and what to, so the rest of the
                    // memo is still true.
                    self.membershipRevision = self.watchlistMembershipRevision()
                    self.membershipCache[key] = desired
                    beginFanOut(desired, item)

                    // Pressed again while that was in flight? Write the new answer.
                    guard self.watchlistIntents[key] == desired else { continue }
                    // Hand back to the durable read once it agrees.
                    if self.watchlistMembership(item) == desired {
                        self.watchlistIntents[key] = nil
                        return
                    }
                    // It doesn't agree, even though the write succeeded. Keep
                    // showing what we actually wrote — but only briefly. Holding
                    // it indefinitely would be the stuck override this design
                    // exists to avoid, so let the read win shortly and converge
                    // on one answer either way.
                    Task { @MainActor in
                        try? await Task.sleep(
                            for: .seconds(Self.watchlistIntentGrace)
                        )
                        if self.watchlistIntents[key] == desired {
                            self.watchlistIntents[key] = nil
                            self.announceWatchlistIntentChanged()
                        }
                    }
                    return
                }
            }
            return
        }
        let targets = watchlistTargets(for: item)
        guard !targets.isEmpty else { return }

        // Account-scope the optimistic post to this card's real copies so a Plex
        // ratingKey shared with an unrelated title on another server can't flip the
        // wrong card's favorite badge. Derived from the same unioned source set the
        // fan-out writes to, plus the card's own (account,item) self-key so a
        // single-source card (empty `sources`) is still scoped rather than falling
        // back to a collision-prone bare id. Empty only for an untagged item.
        var scoped = Set(unionedSourceRefs(for: item).map(\.id))
        if let account = item.sourceAccountID { scoped.insert("\(account):\(item.id)") }
        MediaItemMutation(itemIDs: [item.id], scopedItemIDs: scoped, favorite: adding).post()
        Task {
            var anySucceeded = false
            for target in targets {
                do {
                    try await target.provider.setWatchlisted(adding, item: target.item)
                    anySucceeded = true
                } catch {
                    PlozzLog.app.error("Watchlist \(adding ? "add" : "remove") failed on a provider")
                }

            }
            // If every provider failed, revert the optimistic change.
            if !anySucceeded {
                MediaItemMutation(itemIDs: [item.id], scopedItemIDs: scoped, favorite: !adding).post()
            }
        }
    }

    private static func universalWatchlistFeedback(
        adding: Bool
    ) -> (icon: String, text: LocalizedStringResource) {
        if adding {
            return (
                "bookmark.fill",
                LocalizedStringResource(
                    "watchlist.feedback.added",
                    defaultValue: "Added to Watchlist",
                    comment: "Transient confirmation after a title is saved locally to the user's Watchlist."
                )
            )
        }
        return (
            "bookmark.slash",
            LocalizedStringResource(
                "watchlist.feedback.removing",
                defaultValue: "Removing from Watchlist…",
                comment: "Transient acknowledgement shown when removal from the Watchlist begins."
            )
        )
    }

    /// Every distinct copy of this title paired with the item retargeted to that
    /// copy's own id. One target per distinct **(account, item)** — favouriting is a
    /// per-item operation on both Jellyfin and Plex, so a title a single server
    /// holds twice (e.g. the same movie in two libraries, folded into one card by a
    /// shared external id) must have BOTH copies written, while genuinely distinct
    /// servers are each written once.
    private func watchlistTargets(for item: MediaItem) -> [(provider: any WatchlistProviding, item: MediaItem)] {
        let refs = unionedSourceRefs(for: item)
        guard !refs.isEmpty else {
            // Untagged single-account item: write to the primary as-is.
            let provider = providerResolver(item.sourceAccountID) as? WatchlistProviding
            return provider.map { [(provider: $0, item: item)] } ?? []
        }
        return refs.compactMap { ref in
            guard let provider = providerResolver(ref.accountID) as? WatchlistProviding else { return nil }
            // The primary's own ref already points at `item.id`, so `selectingSource`
            // is a no-op there and repoints only the alternate copies.
            return (provider: provider, item: item.selectingSource(ref))
        }
    }

    /// The per-copy references for a (possibly merged) title, one per distinct
    /// **(account, item)**: the card's own `sources` first, then any additional
    /// copy the live identity index knows that the card didn't already carry.
    /// Empty only for an untagged single-account item.
    ///
    /// Deduped by the full `(account, item)` ref id — NOT by account — because
    /// favouriting is per-item: a single server can hold the same title twice
    /// (two libraries → two item ids folded into one card) and each copy needs its
    /// own write, so collapsing to one-per-account would silently leave the second
    /// copy un-favourited.
    private func unionedSourceRefs(for item: MediaItem) -> [MediaSourceRef] {
        var refs = item.sources
        var seen = Set(refs.map(\.id))
        for ref in additionalSources(item)
        where seen.insert(ref.id).inserted {
            refs.append(ref)
        }
        return refs
    }

    // MARK: - Refresh metadata

    /// Fire-and-forget server-side metadata refresh. Never blocks the UI and
    /// posts no optimistic mutation (nothing changes client-side until the next
    /// fetch); a failure is logged only.
    private func performRefresh(on item: MediaItem) {
        guard let refresher = provider(for: item) as? MetadataRefreshing else { return }
        let itemID = item.id
        Task {
            do {
                try await refresher.refreshMetadata(itemID: itemID)
            } catch {
                PlozzLog.app.error("Refresh metadata failed for item \(itemID)")
            }
        }
    }

    // MARK: - Provider resolution

    /// The provider that owns `item`, by its tagged account; falls back to the
    /// primary provider for untagged (single-account) items.
    private func provider(for item: MediaItem) -> (any MediaProvider)? {
        providerResolver(item.sourceAccountID)
    }

    /// Capabilities for the item's owning account, resolving the provider at most
    /// once per account rather than once per menu build.
    private func capabilities(for item: MediaItem) -> ProviderCapabilities {
        // Untagged items fall back to the primary provider; key them separately so
        // they don't collide with a real account id.
        let key = item.sourceAccountID ?? "\u{0}primary"
        if let cached = capabilityCache[key] { return cached }
        guard let value = providerCapabilityResolver(item.sourceAccountID) else {
            return ProviderCapabilities(
                supportsWatchState: false,
                supportsWatchlist: false,
                supportsMetadataRefresh: false
            )
        }
        let resolved = ProviderCapabilities(
            supportsWatchState: value.supportsWatchState,
            supportsWatchlist: value.supportsWatchlist,
            supportsMetadataRefresh: value.supportsMetadataRefresh
        )
        capabilityCache[key] = resolved
        return resolved
    }

    /// Drop cached capabilities. Called when the account set changes (sign-in/out,
    /// profile switch) so a new or removed account is re-evaluated.
    public func invalidateAccountCaches() {
        capabilityCache.removeAll()
        membershipCache.removeAll()
        membershipRevision = nil
    }

    /// Watchlist membership for `item`, resolved once per world rather than once per
    /// card body. See `membershipCache`.
    private func cachedWatchlistMembership(_ item: MediaItem) -> Bool {
        // The item's own coordinates, not its identity: deriving the identity is the
        // expensive thing being avoided. Two rows showing the same title on the same
        // server share a key and an answer, which is correct — they are one copy.
        let key = Self.membershipKey(item)
        // An accepted press outranks the durable read until that read catches up.
        // Checked before the revision bookkeeping so the answer is stable across
        // the several world changes one write kicks off.
        if let intent = watchlistIntents[key] { return intent }
        let revision = watchlistMembershipRevision()
        if membershipRevision != revision {
            membershipRevision = revision
            membershipCache.removeAll(keepingCapacity: true)
        }
        if let cached = membershipCache[key] { return cached }
        let resolved = watchlistMembership(item)
        membershipCache[key] = resolved
        return resolved
    }

    public func isWatchlisted(_ item: MediaItem) -> Bool {
        universalWatchlistEnabled()
            ? cachedWatchlistMembership(item)
            : item.isFavorite
    }

    public func durableWatchlistItems(
        from candidates: [MediaItem]
    ) -> [MediaItem] {
        universalWatchlistEnabled()
            ? resolveDurableWatchlist(candidates)
            : candidates.filter(\.isFavorite)
    }

    public func isDurableWatchlistPresentationReady() -> Bool {
        !universalWatchlistEnabled() || durableWatchlistPresentationReady()
    }

    public func rehydratePersistedArtwork(
        _ items: [MediaItem]
    ) -> [MediaItem] {
        rehydratePersistedArtworkItems(items)
    }

    public func seedLegacyWatchlist(_ items: [MediaItem]) async {
        guard universalWatchlistEnabled() else { return }
        await seedLegacyUniversalWatchlist(items)
    }
}
