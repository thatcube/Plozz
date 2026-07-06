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
    @Environment(\.scenePhase) private var scenePhase
    /// The app-root window veil (injected by `RootView`). On HDR/DV exit the player
    /// engages it so black survives the dismiss into Home and covers the TV's slow
    /// physical panel switch. Optional so previews/tests without it fall back to the
    /// player-only veil behavior rather than trapping on a missing environment.
    @Environment(DisplayVeilModel.self) private var displayVeil: DisplayVeilModel?
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
                    subtitleModel: viewModel.liveSubtitles,
                    actions: PlayerActions(
                        seek: { target in viewModel.requestSeek(to: target) },
                        togglePlayPause: { viewModel.togglePlayPause() },
                        selectAudio: { viewModel.selectAudioOption(id: $0) },
                        selectSubtitle: { viewModel.selectSubtitleOption(id: $0) },
                        selectSecondarySubtitle: { viewModel.selectSecondarySubtitleOption(id: $0) },
                        setPlaybackSpeed: { viewModel.setPlaybackSpeed($0) },
                        setAudioDelay: { viewModel.setAudioDelay($0) },
                        setSubtitleDelay: { viewModel.setSubtitleDelay($0) },
                        setDialogEnhance: { viewModel.setDialogEnhanceEnabled($0) },
                        setSubtitleStyle: { viewModel.applySubtitleStyle($0) },
                        playNextEpisode: { if let next = viewModel.nextEpisode { viewModel.playEpisode(next) } },
                        playPreviousEpisode: { if let prev = viewModel.previousEpisode { viewModel.playEpisode(prev) } },
                        restart: { viewModel.requestSeek(to: 0) },
                        skipSegment: { viewModel.skipActiveSegment() },
                        autoSkipSegment: { viewModel.autoSkipActiveSegment() },
                        dismissSkip: { viewModel.dismissActiveSkipSegment() },
                        playUpNext: { viewModel.playNextEpisode() },
                        dismissUpNext: { viewModel.dismissUpNextCard() },
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
                        },
                        makeSkipButton: { model, onSkip, onDismiss, onPlayPause in
                            AnyView(SkipSegmentButton(
                                model: model,
                                palette: themePalette,
                                onSkip: onSkip,
                                onDismiss: onDismiss,
                                onPlayPause: onPlayPause
                            ))
                        },
                        makeUpNextCard: { model, onPlayNext, onDismiss, onPlayPause in
                            AnyView(UpNextCardView(
                                model: model,
                                palette: themePalette,
                                onPlayNext: onPlayNext,
                                onDismiss: onDismiss,
                                onPlayPause: onPlayPause
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
            // Keep diagnostics off during load/failure while Plozzigen is initializing;
            // this avoids extra SwiftUI preference/layout churn on the crash path.
            if viewModel.controls.diagnosticsEnabled, viewModel.phase == .ready {
                PlaybackDiagnosticsOverlay(diagnostics: diagnosticsSampler.latest)
                    .environment(\.themePalette, themePalette)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
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
            // Playback finished; close the player so it never freezes on the final
            // frame. Use the HDR-aware path so finishing a Dolby Vision/HDR title
            // fades cleanly back to SDR instead of flashing.
            if shouldDismiss { dismissSmoothly() }
        }
        .onChange(of: viewModel.displayMode) { oldMode, newMode in
            // The display is being driven to a new dynamic range (initial resolve
            // on the native engine, or a cross-engine swap). If the HDMI display
            // mode will switch, fade to black so the panel re-sync is hidden.
            hdrTransition.beginTransition(from: oldMode, to: newMode)
        }
        .modifier(DisplaySettleObserver { hdrTransition.displayDidSettle() })
        .onChange(of: scenePhase) { _, phase in
            // The TV Home button / sleep / app suspension never fires the view's
            // onDisappear, so stop() (and its final convergence write) would never
            // run on that path — and the engine would keep decoding audio behind the
            // Home screen until the OS suspends us. Take a durable checkpoint at the
            // live position AND pause playback as we leave active, so the latest
            // position is captured and audio doesn't keep playing in the background.
            if phase != .active {
                viewModel.suspendForBackground()
            }
        }
        .onDisappear {
            diagnosticsSampler.stop()
            Task { await viewModel.stop() }
        }
    }

    /// Dismiss with an HDR-aware fade that keeps the screen fully black from the
    /// moment exit begins until **after** the display has physically switched back
    /// to SDR, so there is no flash on the player-dismiss → Home handoff — even on
    /// TVs whose panel switches a beat *after* tvOS reports `displayDidSettle`.
    ///
    /// SDR playback dismisses immediately (no mode switch to hide). For HDR/DV we:
    ///   1. raise the **player** veil and let it reach solid black (pre-empt) — this
    ///      hides the switch while the player's `fullScreenCover` is still up;
    ///   2. engage the **window** veil (`DisplayVeilModel`) at the app root, which
    ///      sits *beneath* the cover and survives the dismiss into Home;
    ///   3. stop playback — this resets `preferredDisplayCriteria`, so the TV starts
    ///      switching HDR/DV → SDR behind the black veil;
    ///   4. dismiss promptly: the cover tears down onto the already-black window
    ///      veil, which holds through the slow physical switch and fades out after
    ///      an adaptive post-settle buffer (capped so it can never stick).
    ///
    /// If no window veil is available (previews/tests), fall back to the player-only
    /// behavior: wait for the in-player settle/timeout before dismissing.
    private func dismissSmoothly() {
        guard viewModel.contentDisplayMode.isHDR else {
            dismiss()
            return
        }
        guard !hdrTransition.isExiting else { return }
        hdrTransition.beginExit(isHDR: true)
        let windowVeil = displayVeil
        windowVeil?.engage()
        Task { @MainActor in
            // 1. Let the player veil reach solid black before tearing the HDR
            //    surface down, so the switch never shows through a half-faded frame.
            await hdrTransition.awaitVeilOpaque()
            // 2. Stop playback: resets `preferredDisplayCriteria`, so the TV starts
            //    switching HDR/DV → SDR behind black. Run concurrently so the final
            //    server progress report never prolongs the black.
            Task { await viewModel.stop() }
            if windowVeil != nil {
                // 3. The window veil now owns coverage through the physical switch —
                //    dismiss straight onto it (black under black, no gap).
                dismiss()
            } else {
                // No window veil (previews/tests): keep the legacy behavior of
                // gating the dismiss on the in-player settle (or safety timeout).
                await hdrTransition.waitForExit()
                dismiss()
            }
        }
    }

    /// Starts the diagnostics sampler against the active engine. `viewModel.player`
    /// is the live `AVPlayer` for the native engine and `nil` for Plozzigen — in
    /// the latter case the sampler publishes the metadata-only baseline plus the
    /// engine name, so the overlay works on every engine.
    private func startSampling() {
        diagnosticsSampler.start(
            player: viewModel.player,
            mode: viewModel.deliveryMode,
            metadata: viewModel.sourceMetadata,
            engineName: viewModel.engineDisplayName,
            capabilities: viewModel.mediaCapabilities,
            sourceProvider: viewModel.sourceProvider,
            serverName: viewModel.serverName,
            streamURL: viewModel.diagnosticsStreamURL,
            engineTelemetry: { viewModel.engineLiveTelemetry }
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
