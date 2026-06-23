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
        case .goToSeason, .goToMovie:
            // Navigation is handled in the view layer, never here.
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
            case .goToSeason, .goToMovie:
                break
            }
        } catch {
            PlozzLog.app.error("Media item action \(plan.action.rawValue) failed")
            if plan.revertOnFailure {
                MediaItemMutation(itemIDs: plan.affectedIDs, played: !plan.played).post()
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
