#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI

/// The full-screen Now Playing surface: large artwork, track/artist/album, a
/// quality badge, a full-width analog Liquid Glass scrub bar with the play/pause
/// button beside it, and a row of equally-sized Liquid Glass transport buttons
/// below. Single centered column — no Up Next list. Observes the shared
/// `AudioPlaybackController`.
struct NowPlayingView: View {
    @Bindable var controller: AudioPlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var scrubModel = MusicScrubModel()

    /// Uniform size for every transport control so the row reads evenly.
    private let controlSize: CGFloat = 64

    var body: some View {
        ZStack {
            background
            VStack(spacing: 36) {
                MusicArtworkImage(
                    url: controller.currentTrack?.artworkURL,
                    systemPlaceholder: "music.note",
                    asyncFallbackURL: trackFallback(controller.currentTrack)
                )
                    .frame(width: 420, height: 420)
                    .shadow(radius: 30)

                VStack(spacing: 8) {
                    Text(controller.currentTrack?.title ?? "Not Playing")
                        .font(.system(size: 46, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                    if let subtitle = controller.currentTrack?.subtitle {
                        Text(subtitle)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    }
                    qualityBadge
                }

                scrubRow
                transportRow
            }
            .frame(maxWidth: 960)
            .padding(.horizontal, 80)
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title2)
                    .padding(24)
            }
            .buttonStyle(.plain)
            .padding(32)
        }
        .onAppear { syncScrubModel() }
        .onChange(of: controller.currentTime) { _, _ in syncScrubModel() }
        .onChange(of: controller.duration) { _, _ in syncScrubModel() }
    }

    private func syncScrubModel() {
        scrubModel.duration = controller.duration
        if !scrubModel.isScrubbing { scrubModel.currentSeconds = controller.currentTime }
        scrubModel.onCommit = { target in
            Task { await controller.seek(to: target) }
        }
    }

    @ViewBuilder
    private var background: some View {
        if let track = controller.currentTrack {
            FallbackAsyncImage(
                urls: [track.artworkURL].compactMap { $0 },
                asyncFallbackURL: MusicArtworkFallback.artistImage(name: track.artistName ?? "")
            ) {
                Color.black
            }
            .ignoresSafeArea()
            .overlay(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.35))
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var qualityBadge: some View {
        if let quality = controller.currentQuality {
            HStack(spacing: 10) {
                Image(systemName: quality.isDirectPlay ? "waveform" : "arrow.triangle.2.circlepath")
                    .font(.headline)
                Text(quality.headline)
                    .font(.headline)
                if let detail = quality.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(qualityTint.opacity(0.6), lineWidth: 1))
            .foregroundStyle(qualityTint)
            .padding(.top, 4)
        }
    }

    private var qualityTint: Color {
        guard let quality = controller.currentQuality else { return .secondary }
        if !quality.isDirectPlay { return .orange }
        return quality.isLossless ? .green : .primary
    }

    /// Play/pause beside a full-width analog scrub bar (+ elapsed/remaining times).
    private var scrubRow: some View {
        HStack(spacing: 28) {
            transportButton(
                icon: controller.isPlaying ? "pause.fill" : "play.fill",
                prominent: true
            ) { controller.togglePlayPause() }

            VStack(spacing: 10) {
                MusicScrubBar(model: scrubModel)
                    .frame(height: 44)
                HStack {
                    Text(MusicFormat.duration(scrubModel.displaySeconds))
                    Spacer()
                    Text(MusicFormat.duration(controller.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Every other control, evenly sized, on the row below.
    private var transportRow: some View {
        HStack(spacing: 28) {
            transportButton(
                icon: "shuffle",
                prominent: controller.isShuffled,
                tint: controller.isShuffled ? Color.accentColor : .primary
            ) { controller.toggleShuffle() }

            transportButton(icon: "backward.fill") { controller.previous() }
            transportButton(icon: "forward.fill") { controller.next() }

            transportButton(
                icon: repeatIcon,
                prominent: controller.repeatMode != .off,
                tint: controller.repeatMode == .off ? .primary : Color.accentColor
            ) { controller.cycleRepeatMode() }
        }
    }

    private func transportButton(
        icon: String,
        prominent: Bool = false,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: controlSize, height: controlSize)
        }
        .musicGlassButton(prominent: prominent)
    }

    private var repeatIcon: String {
        switch controller.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    /// Best-effort album-cover fallback for `track`, used only when the server
    /// ships no artwork. `nil` track / blank fields yield no fallback.
    private func trackFallback(_ track: MusicTrack?) -> (@Sendable () async -> URL?)? {
        guard let track else { return nil }
        return MusicArtworkFallback.trackCover(
            title: track.title,
            album: track.albumTitle,
            artist: track.artistName
        )
    }
}

private extension View {
    /// The system Liquid Glass button style (tvOS 26+), falling back to the
    /// bordered styles on older systems. `prominent` highlights play/active toggles.
    @ViewBuilder
    func musicGlassButton(prominent: Bool) -> some View {
        if #available(tvOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}
#endif
