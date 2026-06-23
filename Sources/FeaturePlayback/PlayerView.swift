#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import CoreModels
import CoreUI

/// Full-screen playback using Plozz's **custom** player: an `AVPlayer` rendered
/// into an `AVPlayerLayer` with a hand-built transport overlay and Siri Remote
/// handling (`CustomPlayerContainer`). Going custom is what lets us show
/// Infuse-style trickplay scrubbing thumbnails — the native
/// `AVPlayerViewController` exposes no hook for server-provided scrub previews.
/// `PlayerViewModel` still owns resume, progress reporting, the transcode
/// fallback, and caption styling.
public struct PlayerView: View {
    @State private var viewModel: PlayerViewModel
    @State private var diagnosticsSampler = PlaybackDiagnosticsSampler()
    @Environment(\.dismiss) private var dismiss
    private let showDiagnostics: Bool
    private let themePalette: ThemePalette

    public init(viewModel: PlayerViewModel, showDiagnostics: Bool = false, themePalette: ThemePalette = .dark) {
        _viewModel = State(initialValue: viewModel)
        self.showDiagnostics = showDiagnostics
        self.themePalette = themePalette
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.phase {
            case .loading:
                ZStack {
                    VideoSurfaceContainer(engine: viewModel.videoEngine)
                        .id(viewModel.engineToken)
                        .ignoresSafeArea()
                    ProgressView("Loading…")
                        .font(.title2)
                        .tint(.white)
                }

            case .ready:
                CustomPlayerContainer(
                    engine: viewModel.videoEngine,
                    model: viewModel.controls,
                    actions: PlayerActions(
                        seek: { target in viewModel.requestSeek(to: target) },
                        togglePlayPause: { viewModel.togglePlayPause() },
                        selectAudio: { viewModel.selectAudioOption(id: $0) },
                        selectSubtitle: { viewModel.selectSubtitleOption(id: $0) },
                        setPlaybackSpeed: { viewModel.setPlaybackSpeed($0) },
                        setAudioDelay: { viewModel.setAudioDelay($0) },
                        setSubtitleDelay: { viewModel.setSubtitleDelay($0) },
                        setDialogEnhance: { viewModel.setDialogEnhanceEnabled($0) },
                        dismiss: { dismiss() }
                    ),
                    trickplay: viewModel.trickplay,
                    themePalette: ThemePaletteBox(
                        makeOverlay: { model in
                            AnyView(PlayerControlsOverlay(model: model, palette: themePalette))
                        },
                        makeControlBar: { model, actions, onExitToSurface in
                            AnyView(PlayerControlBar(
                                model: model,
                                palette: themePalette,
                                actions: actions,
                                onExitToSurface: onExitToSurface
                            ))
                        }
                    )
                )
                // Rebuild the host when the engine is swapped (cross-engine
                // fallback) so it re-hosts the new engine's bare video surface.
                .id(viewModel.engineToken)
                .ignoresSafeArea()

            case let .failed(error):
                PlaybackErrorView(message: error.userMessage) { dismiss() }
            }
        }
        .overlay(alignment: .topLeading) {
            // Keep diagnostics off during load/failure while mpv is initializing;
            // this avoids extra SwiftUI preference/layout churn on the crash path.
            if showDiagnostics, viewModel.phase == .ready {
                PlaybackDiagnosticsOverlay(diagnostics: diagnosticsSampler.latest)
                    .environment(\.themePalette, themePalette)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .task {
            await viewModel.load()
            if showDiagnostics { startSampling() }
        }
        .onChange(of: showDiagnostics) { _, enabled in
            if enabled {
                startSampling()
            } else {
                diagnosticsSampler.stop()
            }
        }
        .onChange(of: viewModel.diagnosticsToken) { _, _ in
            // A request resolved (initial load, cross-engine swap, or transcode
            // retry) and the engine is committed — seed the overlay with the
            // engine + source facts now, even before/if load() reaches ready.
            if showDiagnostics { startSampling() }
        }
        .onChange(of: viewModel.playerInstanceID) { _, _ in
            // The native engine created its live AVPlayer (initial load or
            // transcode fallback); restart sampling to pick up live per-tick
            // metrics now that there's a player to read.
            if showDiagnostics { startSampling() }
        }
        .onDisappear {
            diagnosticsSampler.stop()
            Task { await viewModel.stop() }
        }
    }

    /// Starts the diagnostics sampler against the active engine. `viewModel.player`
    /// is the live `AVPlayer` for the native engine and `nil` for VLCKit/mpv — in
    /// the latter case the sampler publishes the metadata-only baseline plus the
    /// engine name, so the overlay works on every engine.
    private func startSampling() {
        diagnosticsSampler.start(
            player: viewModel.player,
            mode: viewModel.deliveryMode,
            metadata: viewModel.sourceMetadata,
            engineName: viewModel.engineDisplayName
        )
    }
}

/// Graceful playback error state with a way back.
private struct PlaybackErrorView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.yellow)
            Text("Can’t play this right now")
                .font(.title).bold()
                .foregroundStyle(.white)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
            Button("Back", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
    }
}

#endif
