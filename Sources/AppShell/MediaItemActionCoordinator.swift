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
/// Resolution is always live (it asks `AppState` on demand) so account / profile
/// changes are picked up without rebuilding the handler.
@MainActor
final class MediaItemActionCoordinator: MediaItemActionHandling {
    private unowned let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
        // A not-in-library discovery (Seerr) title has a synthetic `seer:<tmdbId>`
        // id that isn't addressable on any provider, so watch-state / watchlist /
        // refresh actions would silently fail — offer none (the discovery detail
        // page surfaces a Request affordance instead). This deliberately excludes
        // *owned* featured titles (available/partiallyAvailable), which resolve to a
        // real library copy via the identity index and keep their working actions.
        guard !item.isNotInLibraryDiscovery else { return [] }
        let provider = provider(for: item)
        return MediaItemActionCatalog.actions(
            for: item,
            supportsWatchState: provider is WatchStateProviding,
            supportsWatchlist: provider is WatchlistProviding,
            supportsMetadataRefresh: provider is MetadataRefreshing,
            context: context
        )
    }

    func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {
        switch action {
        case .markWatched, .markUnwatched, .markWatchedUpToHere:
            performWatchState(action, on: item, context: context)
        case .addToWatchlist, .removeFromWatchlist:
            performWatchlist(adding: action == .addToWatchlist, on: item)
        case .refreshMetadata:
            performRefresh(on: item)
        case .goToSeason, .goToMovie:
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
            primaryAccountID: appState.primaryActiveAccount?.id,
            additionalSources: appState.identityIndex.identitySnapshot.sourceRefs(for: item),
            crossServerSync: appState.profileSettings.playbackModel.settings.syncWatchAcrossServers
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

        appState.enqueueWatchMutation(mutation)
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
            let provider = (item.sourceAccountID.flatMap { appState.provider(forAccountID: $0) }
                ?? appState.primaryProvider) as? WatchlistProviding
            return provider.map { [(provider: $0, item: item)] } ?? []
        }
        return refs.compactMap { ref in
            guard let provider = appState.provider(forAccountID: ref.accountID) as? WatchlistProviding else { return nil }
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
        for ref in appState.identityIndex.identitySnapshot.sourceRefs(for: item)
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
        if let accountID = item.sourceAccountID,
           let provider = appState.provider(forAccountID: accountID) {
            return provider
        }
        return appState.primaryProvider
    }
}
