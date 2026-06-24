#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
#if canImport(AVKit)
import AVKit
#endif
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
    /// Smooths the HDR/Dolby-Vision HDMI display-mode switch by fading to black
    /// around it (with a timeout so it can never strand on black).
    @State private var hdrTransition = HDRTransitionModel()
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
                    LoadingMessagesView(spinnerTint: .white, messageColor: .white.opacity(0.85))
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
                        dismiss: { dismissSmoothly() }
                    ),
                    scrubPreview: viewModel.scrubPreview,
                    themePalette: ThemePaletteBox(
                        makeControls: { model, actions, onExitToSurface in
                            AnyView(PlayerControls(
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
        // HDR/Dolby-Vision veil: a black layer above everything that hides the
        // panel's HDMI display-mode re-sync. Opacity is driven by the transition
        // model (0 = clear, 1 = black) and always returns to 0 (settle or timeout).
        .overlay {
            Color.black
                .opacity(hdrTransition.veilOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(hdrTransition.veilOpacity > 0.01)
                .animation(.easeInOut(duration: 0.35), value: hdrTransition.veilOpacity)
        }
        .overlay(alignment: .topLeading) {
            // Keep diagnostics off during load/failure while mpv is initializing;
            // this avoids extra SwiftUI preference/layout churn on the crash path.
            if viewModel.controls.diagnosticsEnabled, viewModel.phase == .ready {
                PlaybackDiagnosticsOverlay(diagnostics: diagnosticsSampler.latest)
                    .environment(\.themePalette, themePalette)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .task {
            viewModel.controls.diagnosticsEnabled = showDiagnostics
            await viewModel.load()
            if viewModel.controls.diagnosticsEnabled { startSampling() }
        }
        .onChange(of: viewModel.controls.diagnosticsEnabled) { _, enabled in
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
            if viewModel.controls.diagnosticsEnabled { startSampling() }
        }
        .onChange(of: viewModel.playerInstanceID) { _, _ in
            // The native engine created its live AVPlayer (initial load or
            // transcode fallback); restart sampling to pick up live per-tick
            // metrics now that there's a player to read.
            if viewModel.controls.diagnosticsEnabled { startSampling() }
        }
        .onChange(of: viewModel.shouldDismiss) { _, shouldDismiss in
            // Playback finished on an auto-dismiss player (a trailer); close it.
            if shouldDismiss { dismiss() }
        }
        .onChange(of: viewModel.displayMode) { oldMode, newMode in
            // The display is being driven to a new dynamic range (initial resolve
            // on the native engine, or a cross-engine swap). If the HDMI display
            // mode will switch, fade to black so the panel re-sync is hidden.
            hdrTransition.beginTransition(from: oldMode, to: newMode)
        }
        .modifier(DisplaySettleObserver { hdrTransition.displayDidSettle() })
        .onDisappear {
            diagnosticsSampler.stop()
            Task { await viewModel.stop() }
        }
    }

    /// Dismiss with an HDR-aware fade: when leaving HDR/Dolby-Vision content the
    /// display will snap back to SDR, so fade to black first to hide it, then
    /// dismiss. SDR playback dismisses immediately (no mode switch to hide).
    private func dismissSmoothly() {
        guard !hdrTransition.isVeiled, viewModel.displayMode.isHDR else {
            dismiss()
            return
        }
        hdrTransition.raiseVeil()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            dismiss()
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

/// Observes the tvOS display manager and reports when an HDMI display-mode switch
/// finishes, so the HDR veil can fade back in exactly when the panel has settled.
/// A no-op on platforms without `AVDisplayManager` (e.g. macOS test builds).
private struct DisplaySettleObserver: ViewModifier {
    let onSettle: () -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.onReceive(
            NotificationCenter.default.publisher(for: .AVDisplayManagerModeSwitchEnd)
        ) { _ in
            onSettle()
        }
        #else
        content
        #endif
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
