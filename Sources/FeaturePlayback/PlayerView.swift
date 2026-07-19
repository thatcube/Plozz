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
    private let showsSharedControls: Bool

    public init(
        viewModel: PlayerViewModel,
        showDiagnostics: Bool = false,
        themePalette: ThemePalette = .dark,
        showsSharedControls: Bool = true
    ) {
        _viewModel = State(initialValue: viewModel)
        self.showDiagnostics = showDiagnostics
        self.themePalette = themePalette
        self.showsSharedControls = showsSharedControls
    }


    public var body: some View {
        configuredPlayerStack
        .onChange(of: viewModel.shouldDismiss) { _, shouldDismiss in
            // Playback finished; close the player so it never freezes on the final
            // frame. Use the HDR-aware path so finishing a Dolby Vision/HDR title
            // fades cleanly back to SDR instead of flashing.
            if shouldDismiss { dismissSmoothly() }
        }
        .onChange(of: viewModel.effectiveDynamicRange) { oldRange, newRange in
            hdrTransition.reconcile(
                from: oldRange,
                to: newRange,
                inheritedPreservedRange: viewModel.inheritedPreservedDynamicRange
            )
        }
        .onChange(of: viewModel.dynamicRangeTransitionToken) { _, _ in
            if viewModel.effectiveDynamicRange.isAwaitingEngineProbe {
                hdrTransition.restartProbeTransition()
            }
        }
        .modifier(DisplaySettleObserver { hdrTransition.displayDidSettle() })
        .onChange(of: scenePhase) { _, phase in
            // The TV Home button / sleep / app suspension never fires the view's
            // onDisappear, so stop() (and its final convergence write) would never
            // run on that path — and the engine would keep decoding audio behind the
            // Home screen until the OS suspends us. Pause on inactive, record the
            // real background transition, then rebuild the engine when active again.
            switch phase {
            case .active:
                Task { await viewModel.resumeAfterBackground() }
            case .inactive:
                viewModel.suspendForBackground()
            case .background:
                viewModel.didEnterBackground()
            @unknown default:
                viewModel.suspendForBackground()
            }
        }
        .onDisappear {
            diagnosticsSampler.stop()
            Task { await viewModel.stop() }
        }
    }

    /// `playerStack` plus the appearance + diagnostics lifecycle observers,
    /// split out of `body` so the ~10 chained lifecycle modifiers type-check as
    /// two shorter chains instead of one (the combined `body` measured
    /// ~148-181ms). These observers are order-independent, so relocating them
    /// across the split is a pure compile-time change with identical behavior.
    private var configuredPlayerStack: some View {
        playerStack
        .onAppear {
            hdrTransition.synchronize(
                with: viewModel.effectiveDynamicRange,
                inheritedPreservedRange: viewModel.inheritedPreservedDynamicRange
            )
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
    }

    /// The visual layer stack (base + HDR veil + spinner + diagnostics), split
    /// out of `body` so the type-checker isn't composing the overlay chain and
    /// the ~10 lifecycle modifiers as one expression. Pure extraction.
    private var playerStack: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            phaseContent
        }
        // HDR/Dolby-Vision veil: a black layer above everything that hides the
        // panel's HDMI display-mode re-sync. Opacity is driven by the transition
        // model (0 = clear, 1 = black) and always returns to 0 (settle or timeout).
        .overlay { hdrVeilOverlay }
        // Single bring-up spinner: shown while resolving/loading AND while
        // `.ready` but the engine hasn't presented its first frame yet, so the
        // viewer sees one continuous indicator from tap → first frame (no black
        // gap, no second in-player spinner on an engine swap). Above the HDR veil
        // so it stays visible during an HDMI display-mode switch.
        .overlay { bringUpSpinnerOverlay }
        .animation(.easeInOut(duration: 0.2), value: viewModel.showBringUpSpinner)
        .overlay(alignment: .topLeading) { diagnosticsOverlay }
    }

    /// The HDR/Dolby-Vision exit veil content, extracted from `body` so its
    /// opacity/animation chain type-checks on its own. Pure extraction.
    private var hdrVeilOverlay: some View {
        Color.black
            .opacity(hdrTransition.veilOpacity)
            .ignoresSafeArea()
            .allowsHitTesting(hdrTransition.veilOpacity > 0.01)
            .animation(.easeInOut(duration: 0.35), value: hdrTransition.veilOpacity)
    }

    /// The single bring-up spinner overlay content, extracted from `body`.
    /// Pure extraction — identical gating and transition.
    @ViewBuilder
    private var bringUpSpinnerOverlay: some View {
        if viewModel.showBringUpSpinner {
            LoadingMessagesView(spinnerTint: .white, messageColor: .white.opacity(0.85))
                .ignoresSafeArea()
                .transition(.opacity)
        }
    }

    /// The diagnostics overlay content, extracted from `body`. Pure extraction —
    /// identical gating (only while `.ready` and diagnostics enabled).
    @ViewBuilder
    private var diagnosticsOverlay: some View {
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

    /// The phase-driven main content, split out of `body` so the type-checker
    /// isn't inferring the `ZStack` + `switch` + the large `.ready` container as
    /// one expression (the combined `body` measured ~148-181ms). Pure view
    /// extraction — identical structure and behavior.
    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .loading:
            // Black backdrop that hosts the (not-yet-presenting) engine
            // surface. The bring-up spinner is a top-level overlay
            // (`showBringUpSpinner`) so it spans this and the `.ready`-but-
            // awaiting-first-frame window as one continuous indicator.
            VideoSurfaceContainer(engine: viewModel.videoEngine)
                .id(viewModel.engineToken)
                .ignoresSafeArea()

        case .ready:
            readyPlayerContainer

        case let .failed(error):
            PlaybackErrorView(message: error.userMessage) { dismiss() }
        }
    }

    /// The `.ready`-phase custom player, extracted so its large initializer (the
    /// `PlayerActions` closure bundle + `ThemePaletteBox` factories) type-checks
    /// on its own instead of inflating `body`. Pure extraction — no behavior change.
    private var readyPlayerContainer: some View {
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
                searchRemoteSubtitles: { viewModel.searchRemoteSubtitles(language: $0) },
                refreshRemoteSubtitleSearch: { viewModel.refreshRemoteSubtitleSearch() },
                downloadRemoteSubtitle: { viewModel.downloadAndLoadRemoteSubtitle($0) },
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
            authenticatedHTTPResolver:
                viewModel.authenticatedHTTPResolver,
            showsSharedControls: showsSharedControls,
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
        guard viewModel.requiresHDRExitVeil else {
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
            sourceFileName: viewModel.diagnosticsSourceFileName,
            streamURL: viewModel.diagnosticsStreamURL,
            engineTelemetry: { viewModel.engineLiveTelemetry },
            probedFacts: { viewModel.engineProbedFacts }
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
