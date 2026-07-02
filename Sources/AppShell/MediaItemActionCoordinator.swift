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
            additionalSources: appState.identitySnapshot.sourceRefs(for: item),
            crossServerSync: appState.playbackModel.settings.syncWatchAcrossServers
        ) else { return }

        var ids = Set(mutation.targets.map(\.itemID))
        ids.insert(item.id)
        MediaItemMutation(itemIDs: ids, played: played).post()

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
        MediaItemMutation(itemIDs: ids, played: true).post()
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

        MediaItemMutation(itemIDs: [item.id], favorite: adding).post()
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
                MediaItemMutation(itemIDs: [item.id], favorite: !adding).post()
            }
        }
    }

    /// Every server holding this title paired with the item retargeted to that
    /// server's own id. One target per distinct account (the card's own sources
    /// win over index entries), so no server is double-written.
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
            // is a no-op there and repoints only the alternate servers.
            return (provider: provider, item: item.selectingSource(ref))
        }
    }

    /// The per-server references for a (possibly merged) title, one per distinct
    /// account: the card's own `sources` first, then any additional server the
    /// live identity index knows. Empty only for an untagged single-account item.
    private func unionedSourceRefs(for item: MediaItem) -> [MediaSourceRef] {
        var refs = item.sources
        var seenAccounts = Set(refs.map(\.accountID))
        for ref in appState.identitySnapshot.sourceRefs(for: item)
        where seenAccounts.insert(ref.accountID).inserted {
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
