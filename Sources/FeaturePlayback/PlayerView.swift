#if canImport(SwiftUI)
import SwiftUI
import AVKit
import CoreModels
import CoreUI

/// Full-screen playback using the **native** `AVPlayerViewController`.
///
/// Using the system player gives Plozz the platform-standard transport bar,
/// scrubbing, Siri Remote gestures, and the built-in audio/subtitle picker
/// (populated from the stream's media selection groups) for free — we only
/// deviate from native where the spec requires (in-app caption styling, resume,
/// and progress reporting, handled by `PlayerViewModel`).
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
                ProgressView("Loading…")
                    .font(.title2)
                    .tint(.white)

            case .ready:
                EnginePlayerView(viewModel: viewModel)
                    .ignoresSafeArea()

            case let .failed(error):
                PlaybackErrorView(message: error.userMessage) { dismiss() }
            }
        }
        .overlay(alignment: .topLeading) {
            if showDiagnostics, case .ready = viewModel.phase {
                PlaybackDiagnosticsOverlay(diagnostics: diagnosticsSampler.latest)
                    .environment(\.themePalette, themePalette)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .task {
            await viewModel.load()
            if showDiagnostics, let player = viewModel.player {
                diagnosticsSampler.start(
                    player: player,
                    isTranscoding: viewModel.isTranscoding,
                    metadata: viewModel.sourceMetadata
                )
            }
        }
        .onChange(of: showDiagnostics) { _, enabled in
            if enabled, let player = viewModel.player {
                diagnosticsSampler.start(
                    player: player,
                    isTranscoding: viewModel.isTranscoding,
                    metadata: viewModel.sourceMetadata
                )
            } else {
                diagnosticsSampler.stop()
            }
        }
        .onChange(of: viewModel.playerInstanceID) { _, _ in
            // The transcode fallback swaps in a new player; restart sampling so
            // diagnostics keep tracking the live stream.
            if showDiagnostics, let player = viewModel.player {
                diagnosticsSampler.start(
                    player: player,
                    isTranscoding: viewModel.isTranscoding,
                    metadata: viewModel.sourceMetadata
                )
            }
        }
        .onDisappear {
            diagnosticsSampler.stop()
            Task { await viewModel.stop() }
        }
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

/// Thin `UIViewControllerRepresentable` bridge to the engine-vended player view
/// controller. The active `VideoEngine` owns the controller and keeps it fed by
/// the live player (re-pointing it across a transcode-fallback swap), so this
/// bridge just renders whatever the engine hands back without knowing the
/// concrete player type.
private struct EnginePlayerView: UIViewControllerRepresentable {
    let viewModel: PlayerViewModel

    func makeUIViewController(context: Context) -> UIViewController {
        viewModel.makePlayerViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        // The engine manages the controller's player internally; nothing to do.
    }
}

#endif
