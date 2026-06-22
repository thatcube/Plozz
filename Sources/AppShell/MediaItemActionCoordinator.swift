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
        let supportsWatchState = (provider(for: item) as? WatchStateProviding) != nil
        return MediaItemActionCatalog.actions(
            for: item,
            supportsWatchState: supportsWatchState,
            context: context
        )
    }

    func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {
        guard let watch = provider(for: item) as? WatchStateProviding else { return }
        Task { await run(action, on: item, context: context, using: watch) }
    }

    // MARK: - Execution

    private func run(
        _ action: MediaItemAction,
        on item: MediaItem,
        context: MediaItemActionContext,
        using watch: any WatchStateProviding
    ) async {
        do {
            let played: Bool
            var affectedIDs: Set<String> = [item.id]
            switch action {
            case .markWatched:
                played = true
                try await watch.setPlayed(true, itemID: item.id)
            case .markUnwatched:
                played = false
                try await watch.setPlayed(false, itemID: item.id)
            case .markWatchedUpToHere:
                played = true
                affectedIDs = try await markUpToHere(item, context: context, using: watch)
            case .goToSeason:
                // Navigation is handled in the view layer, never here.
                return
            }
            MediaItemMutation(itemIDs: affectedIDs, played: played).post()
        } catch {
            // Best-effort: a failed toggle simply won't reflect on the next
            // refresh. Never surface a transient network error for a background
            // menu action on tvOS.
            PlozzLog.app.error("Media item action \(action.rawValue) failed")
        }
    }

    /// Marks every earlier season in full, then each preceding episode in the
    /// current season up to and including the target. Per-item failures are
    /// tolerated so one unreachable episode doesn't abort the rest. Returns every
    /// id that was marked watched so screens can update them in place.
    private func markUpToHere(
        _ item: MediaItem,
        context: MediaItemActionContext,
        using watch: any WatchStateProviding
    ) async throws -> Set<String> {
        var affected: Set<String> = []
        for containerID in context.precedingContainerIDs {
            try? await watch.setPlayed(true, itemID: containerID)
            affected.insert(containerID)
        }
        let episodes = MediaItemActionCatalog.siblingsToMarkUpToHere(item, in: context.orderedSiblings)
        for episode in episodes {
            try? await watch.setPlayed(true, itemID: episode.id)
            affected.insert(episode.id)
        }
        return affected
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
