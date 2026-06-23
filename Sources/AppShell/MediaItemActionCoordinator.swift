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
        guard let watch = provider(for: item) as? WatchStateProviding else { return }
        guard let plan = mutationPlan(for: action, item: item, context: context) else { return }

        // Optimistic update: reflect the change in the UI immediately so the
        // watched badge flips the instant the menu dismisses, instead of after
        // the server round-trip. The network call then runs in the background and
        // only the rare failure case reconciles (reverts) the badge.
        MediaItemMutation(itemIDs: plan.affectedIDs, played: plan.played).post()
        Task { await commit(plan, using: watch) }
    }

    // MARK: - Execution

    /// What a watched-state action changes, computed synchronously (no network)
    /// so the UI can update optimistically before the request is sent.
    private struct MutationPlan {
        let action: MediaItemAction
        let targetID: String
        let affectedIDs: Set<String>
        let played: Bool
        /// Whether a failed request should roll the optimistic change back. Only
        /// the single-item toggles do; "up to here" is best-effort per item.
        let revertOnFailure: Bool
    }

    private func mutationPlan(
        for action: MediaItemAction,
        item: MediaItem,
        context: MediaItemActionContext
    ) -> MutationPlan? {
        switch action {
        case .markWatched:
            return MutationPlan(action: action, targetID: item.id, affectedIDs: [item.id], played: true, revertOnFailure: true)
        case .markUnwatched:
            return MutationPlan(action: action, targetID: item.id, affectedIDs: [item.id], played: false, revertOnFailure: true)
        case .markWatchedUpToHere:
            var ids = Set(context.precedingContainerIDs)
            ids.formUnion(MediaItemActionCatalog.siblingsToMarkUpToHere(item, in: context.orderedSiblings).map(\.id))
            ids.insert(item.id)
            return MutationPlan(action: action, targetID: item.id, affectedIDs: ids, played: true, revertOnFailure: false)
        default:
            return nil
        }
    }

    /// Sends the watched-state change(s) to the server. On failure of a
    /// revertible action, posts a compensating mutation so the optimistic badge
    /// flips back to its true state.
    private func commit(_ plan: MutationPlan, using watch: any WatchStateProviding) async {
        do {
            switch plan.action {
            case .markWatched, .markUnwatched:
                try await watch.setPlayed(plan.played, itemID: plan.targetID)
            case .markWatchedUpToHere:
                // Best-effort per item so one unreachable episode doesn't abort
                // the rest; the optimistic UI already reflects the intent.
                for id in plan.affectedIDs {
                    try? await watch.setPlayed(true, itemID: id)
                }
            default:
                break
            }
        } catch {
            PlozzLog.app.error("Media item action \(plan.action.rawValue) failed")
            if plan.revertOnFailure {
                MediaItemMutation(itemIDs: plan.affectedIDs, played: !plan.played).post()
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
