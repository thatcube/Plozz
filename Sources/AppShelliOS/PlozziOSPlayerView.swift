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

    let request: PlozziOSPlaybackRequest
    let provider: any MediaProvider

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let viewModel {
                PlayerView(
                    viewModel: viewModel,
                    showDiagnostics: appModel.settings.diagnostics.settings.isEnabled
                )
                .id(request.id)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.white)
            .padding()
            .accessibilityLabel("Close player")
        }
        .statusBarHidden()
        .task {
            guard viewModel == nil else { return }
            viewModel = makeViewModel()
        }
    }

    private func makeViewModel() -> PlayerViewModel {
        let item = request.item
        let resolver = appModel.authenticatedHTTPResolver
        let playbackSettings = appModel.settings.playback.settings
        let neighborResolver = makeNeighborResolver(for: item)
        let seriesIDResolver = makeSeriesIDResolver(for: item)
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            mediaSourceID: item.selectedVersionID,
            behavior: appModel.settings.subtitleBehavior.settings,
            style: appModel.settings.subtitleStyle.style,
            subtitlePolicy: .inheriting(
                from: appModel.settings.subtitleBehavior.settings
            ),
            audioPolicy: .inheriting(from: playbackSettings),
            playbackSettings: playbackSettings,
            spoilerSettings: appModel.settings.spoilers.settings,
            seriesAccountFallbackID: item.sourceAccountID,
            startPosition: request.startPosition,
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
            seriesIDResolver: seriesIDResolver
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
