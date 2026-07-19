#if os(iOS)
import CoreModels
import FeaturePlayback
import SwiftUI

struct PlozziOSPlaybackRequest: Identifiable {
    let id = UUID()
    let item: MediaItem
    let startPosition: TimeInterval
}

struct PlozziOSPlayerView: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PlayerViewModel?
    @State private var playerIdentity = UUID()
    @State private var handoffTask: Task<Void, Never>?
    @State private var isPresented = false

    let request: PlozziOSPlaybackRequest
    let provider: any MediaProvider

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let viewModel {
                PlayerView(
                    viewModel: viewModel,
                    showDiagnostics: appModel.settings.diagnostics.settings.isEnabled,
                    showsSharedControls: false
                )
                .id(playerIdentity)
                if viewModel.phase == .ready {
                    PlozziOSPlayerControlsOverlay(
                        viewModel: viewModel,
                        onClose: { dismiss() }
                    )
                } else {
                    closeButton
                }
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                closeButton
            }
        }
        .statusBarHidden()
        .onAppear { isPresented = true }
        .onDisappear {
            isPresented = false
            handoffTask?.cancel()
            handoffTask = nil
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = makeViewModel(
                item: request.item,
                startPosition: request.startPosition
            )
        }
        .onChange(of: viewModel?.pendingNextEpisode?.id) { _, nextID in
            guard nextID != nil,
                  let outgoing = viewModel,
                  let next = outgoing.pendingNextEpisode,
                  handoffTask == nil else {
                return
            }
            let prefetched = outgoing.consumePrefetchedNext(matching: next.id)
            handoffTask = Task { @MainActor in
                await outgoing.stop()
                let incoming = makeViewModel(
                    item: next,
                    startPosition: 0,
                    adoptedResolved: prefetched
                )
                guard !Task.isCancelled, isPresented else {
                    await incoming.stop()
                    return
                }
                viewModel = incoming
                playerIdentity = UUID()
                handoffTask = nil
            }
        }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close player")
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding()
    }

    private func makeViewModel(
        item: MediaItem,
        startPosition: TimeInterval,
        adoptedResolved: PlayerViewModel.PrefetchedPlayback? = nil
    ) -> PlayerViewModel {
        let resolver = appModel.authenticatedHTTPResolver
        let playbackSettings = appModel.settings.playback.settings
        let neighborResolver = makeNeighborResolver(for: item)
        let seriesIDResolver = makeSeriesIDResolver(for: item)
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            mediaSourceID: item.selectedVersionID,
            offlinePlaybackResolver: appModel.downloads.offlineResolver,
            behavior: appModel.settings.subtitleBehavior.settings,
            style: appModel.settings.subtitleStyle.style,
            subtitlePolicy: .inheriting(
                from: appModel.settings.subtitleBehavior.settings
            ),
            audioPolicy: .inheriting(from: playbackSettings),
            playbackSettings: playbackSettings,
            spoilerSettings: appModel.settings.spoilers.settings,
            seriesAccountFallbackID: item.sourceAccountID,
            startPosition: startPosition,
            engineFactory: EngineFactory(
                makeNative: {
                    NativeVideoEngine(
                        style: $0,
                        authenticatedHTTPResolver: resolver
                    )
                }
            ),
            authenticatedHTTPResolver: resolver,
            neighborResolver: neighborResolver,
            seriesIDResolver: seriesIDResolver,
            adoptedResolved: adoptedResolved
        )
        viewModel.onSubtitleStyleChanged = {
            appModel.settings.subtitleStyle.style = $0
        }
        return viewModel
    }

    private func makeNeighborResolver(
        for item: MediaItem
    ) -> (@Sendable () async -> (previous: MediaItem?, next: MediaItem?))? {
        guard item.kind == .episode, let seasonID = item.seasonID else { return nil }
        let provider = self.provider
        let accountID = item.sourceAccountID
        return {
            let siblings = (try? await provider.children(of: seasonID)) ?? []
            let tagged = accountID.map { id in
                siblings.map { $0.taggingSource(id) }
            } ?? siblings
            return EpisodeSequence.neighbors(of: item, in: tagged)
        }
    }

    private func makeSeriesIDResolver(
        for item: MediaItem
    ) -> (@Sendable () async -> [String: String]?)? {
        guard item.kind == .episode, let seriesID = item.seriesID else { return nil }
        let provider = self.provider
        return {
            (try? await provider.item(id: seriesID))?.providerIDs
        }
    }
}
#endif
