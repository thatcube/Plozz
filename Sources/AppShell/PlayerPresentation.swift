#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHome
import FeatureMusic
import FeaturePlayback
import MediaTransportCore
import MetadataKit
import FeatureSearch
import FeatureSettings
import FeatureProfiles
import ProviderTrailers
import RatingsService
import TraktService
import SeerService
import SimklService
import AniListService
import MALService
import LastFmService

/// Hosts the full-screen player and builds its ``PlayerViewModel`` exactly once,
/// off the render path.
///
/// Constructing the view model inline inside a `.fullScreenCover` content closure
/// is a trap: SwiftUI re-invokes that closure on every parent render, and because
/// ``PlayerView`` keeps the model in `@State` (the first value wins), every extra
/// invocation builds a throwaway `PlayerViewModel` — and a throwaway
/// `NativeVideoEngine` at its `init` — that is discarded immediately. Under the
/// player's own `@Observable` mutation churn this becomes self-reinforcing: each
/// render spawns engines that storm `AttributeGraph`, which drives more renders.
/// On device this showed up as the live VM/Native instance counters racing
/// upward (Native far ahead of VM, since every model makes a native engine before
/// it ever routes to an engine), thermal throttling, and growing lag the longer the
/// player stayed up.
///
/// Building the model in `.task`, gated by this view's identity, fires the factory
/// once per presentation instead of once per render.
///
/// **Episode advance**: when a `PlayerViewModel` sets its `pendingNextEpisode`,
/// this view swaps the VM in-place — the `Color.black` ZStack stays up so the
/// full-screen cover never dismisses and the series page never flashes through.
@MainActor
struct PlayerPresentation: View {
    let make: (PlayRequest, PlayerViewModel.PrefetchedPlayback?) -> PlayerViewModel
    /// Re-selects the next-best source after the current target fails to start,
    /// excluding every account already attempted; `nil` means no untried source
    /// remains, so the player's own error state stays on screen (r8-play-failover).
    let makeFailover: (_ failedItem: MediaItem, _ tried: Set<String>) -> MediaItem?
    let showDiagnostics: Bool
    let themePalette: ThemePalette

    /// The currently-active play request; changes when auto-advancing episodes.
    @State private var activeRequest: PlayRequest
    @State private var viewModel: PlayerViewModel?
    /// Source account IDs already attempted for the active title, so failover never
    /// re-tries a server that already failed and can detect true exhaustion. Reset
    /// whenever the title changes (episode auto-advance).
    @State private var triedAccountIDs: Set<String> = []

    init(
        request: PlayRequest,
        make: @escaping (PlayRequest, PlayerViewModel.PrefetchedPlayback?) -> PlayerViewModel,
        makeFailover: @escaping (_ failedItem: MediaItem, _ tried: Set<String>) -> MediaItem?,
        showDiagnostics: Bool,
        themePalette: ThemePalette
    ) {
        self.make = make
        self.makeFailover = makeFailover
        self.showDiagnostics = showDiagnostics
        self.themePalette = themePalette
        self._activeRequest = State(initialValue: request)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let viewModel {
                PlayerView(
                    viewModel: viewModel,
                    showDiagnostics: showDiagnostics,
                    themePalette: themePalette
                )
                .id(activeRequest.id)
            }
        }
        .task {
            if viewModel == nil {
                HandoffDiagnostics.emit(
                    "presentation READY trace=\(activeRequest.traceID.uuidString.prefix(8)) "
                        + "item=\(activeRequest.item.id) "
                        + "tapToPresentation=\(HandoffDiagnostics.ms(activeRequest.requestedAt))"
                )
                viewModel = make(activeRequest, nil)
                HandoffDiagnostics.emit(
                    "viewModel CREATED trace=\(activeRequest.traceID.uuidString.prefix(8)) "
                        + "item=\(activeRequest.item.id) "
                        + "tapToModel=\(HandoffDiagnostics.ms(activeRequest.requestedAt))"
                )
            }
        }
        .onChange(of: viewModel?.pendingNextEpisode?.id) { _, nextID in
            guard nextID != nil, let next = viewModel?.pendingNextEpisode else { return }
            // Adopt the next episode's prefetched resolution (if ready) BEFORE
            // stop() runs, so the incoming player skips the network resolve and
            // reuses the already-open session rather than the old player releasing
            // it. `nil` when the prefetch didn't finish → the new player resolves
            // normally (no regression).
            let consumed = viewModel?.consumePrefetchedNext(matching: next.id)
            // Keep the panel's HDR/DV mode across a same-range hand-off so the TV
            // doesn't flap DV→SDR→DV between episodes (needs the prefetched next's
            // source facts, so it's a no-op on a prefetch miss).
            let preserveDisplay = viewModel?.shouldPreserveDisplayMode(forNext: consumed) ?? false
            let prefetched = consumed?.inheritingPreservedDisplayMode(preserveDisplay)
            Task { @MainActor in
                // Stop + scrobble the finished episode before swapping.
                await viewModel?.stop(preserveDisplayMode: preserveDisplay)
                // Create the new VM and update the request in one synchronous
                // block so SwiftUI batches the render: the .id change forces a
                // fresh PlayerView that picks up the new VM via @State init.
                let newRequest = PlayRequest(item: next, startPosition: 0)
                // A new title starts its own failover attempt history.
                triedAccountIDs = []
                viewModel = make(newRequest, prefetched)
                activeRequest = newRequest
            }
        }
        .onChange(of: viewModel?.phase) { _, phase in
            // Playback failed to start on the routed server. Silently retarget to
            // the next-best untried source (a dead/unreachable copy falls through to
            // another server's copy) and re-present at the same resume point. When
            // no untried source remains, the player's `.failed` error stays visible.
            guard case .failed = phase else { return }
            let failedAccountID = activeRequest.item.selectedSourceAccountID
                ?? activeRequest.item.sourceAccountID
            var attempted = triedAccountIDs
            if let failedAccountID { attempted.insert(failedAccountID) }
            guard let nextItem = makeFailover(activeRequest.item, attempted) else {
                triedAccountIDs = attempted
                return
            }
            Task { @MainActor in
                await viewModel?.stop()
                let newRequest = PlayRequest(
                    item: nextItem,
                    startPosition: activeRequest.startPosition
                )
                triedAccountIDs = attempted
                viewModel = make(newRequest, nil)
                activeRequest = newRequest
            }
        }
    }
}
#endif
