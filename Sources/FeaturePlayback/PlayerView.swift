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

    public init(viewModel: PlayerViewModel, showDiagnostics: Bool = false) {
        _viewModel = State(initialValue: viewModel)
        self.showDiagnostics = showDiagnostics
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
                if let player = viewModel.player {
                    SystemPlayerView(player: player)
                        .ignoresSafeArea()
                }

            case let .failed(error):
                PlaybackErrorView(message: error.userMessage) { dismiss() }
            }
        }
        .overlay(alignment: .topLeading) {
            if showDiagnostics, case .ready = viewModel.phase {
                PlaybackDiagnosticsOverlay(diagnostics: diagnosticsSampler.latest)
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

/// Thin `UIViewControllerRepresentable` bridge to `AVPlayerViewController`.
private struct SystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        // Native transport + info panels; keep the platform experience.
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

#endif
