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
            additionalSources: appState.identitySnapshot.sourceRefs(for: item)
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
    private func performWatchlist(adding: Bool, on item: MediaItem) {
        let providers = watchlistProviders(for: item)
        guard !providers.isEmpty else { return }

        MediaItemMutation(itemIDs: [item.id], favorite: adding).post()
        Task {
            var anySucceeded = false
            for provider in providers {
                do {
                    try await provider.setWatchlisted(adding, item: item)
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

    /// Every `WatchlistProviding` provider that holds this title: the primary
    /// owner plus any de-duplicated cross-server alternates.
    private func watchlistProviders(for item: MediaItem) -> [any WatchlistProviding] {
        let accountIDs = item.allSourceAccountIDs
        if accountIDs.isEmpty {
            return [appState.primaryProvider as? WatchlistProviding].compactMap { $0 }
        }
        return accountIDs.compactMap { appState.provider(forAccountID: $0) as? WatchlistProviding }
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
