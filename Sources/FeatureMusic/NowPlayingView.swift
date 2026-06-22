#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI

/// The full-screen Now Playing surface: large artwork, track/artist/album,
/// a scrubber, transport (prev / play-pause / next), shuffle & repeat toggles,
/// and the Up Next queue. Observes the shared `AudioPlaybackController`.
struct NowPlayingView: View {
    @Bindable var controller: AudioPlaybackController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            background
            HStack(alignment: .top, spacing: 64) {
                nowPlayingColumn
                    .frame(maxWidth: 760)
                upNextColumn
                    .frame(maxWidth: 560)
            }
            .padding(64)
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
    }

    @ViewBuilder
    private var background: some View {
        if let track = controller.currentTrack, let url = track.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.black
            }
            .ignoresSafeArea()
            .overlay(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.35))
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    private var nowPlayingColumn: some View {
        VStack(alignment: .leading, spacing: 32) {
            MusicArtworkImage(url: controller.currentTrack?.artworkURL, systemPlaceholder: "music.note")
                .frame(width: 420, height: 420)
                .shadow(radius: 30)

            VStack(alignment: .leading, spacing: 8) {
                Text(controller.currentTrack?.title ?? "Not Playing")
                    .font(.system(size: 48, weight: .bold))
                    .lineLimit(2)
                if let subtitle = controller.currentTrack?.subtitle {
                    Text(subtitle)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            scrubber
            transport
        }
    }

    private var scrubber: some View {
        VStack(spacing: 8) {
            ProgressBar(fraction: controller.progressFraction)
                .frame(height: 6)
                .clipShape(Capsule())
            HStack {
                Text(MusicFormat.duration(controller.currentTime))
                Spacer()
                Text(MusicFormat.duration(controller.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 36) {
            Button { controller.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title2)
                    .foregroundStyle(controller.isShuffled ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            Button { controller.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .buttonStyle(.plain)

            Button { controller.togglePlayPause() } label: {
                Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
            }
            .buttonStyle(.plain)

            Button { controller.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .buttonStyle(.plain)

            Button { controller.cycleRepeatMode() } label: {
                Image(systemName: repeatIcon)
                    .font(.title2)
                    .foregroundStyle(controller.repeatMode == .off ? .secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    private var repeatIcon: String {
        switch controller.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    @ViewBuilder
    private var upNextColumn: some View {
        if controller.upNext.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Up Next")
                    .font(.title2.weight(.semibold))
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(controller.upNext.enumerated()), id: \.element.id) { offset, track in
                            Button {
                                controller.play(at: controller.index + 1 + offset)
                            } label: {
                                HStack(spacing: 16) {
                                    MusicArtworkImage(url: track.artworkURL, systemPlaceholder: "music.note", cornerRadius: 6)
                                        .frame(width: 56, height: 56)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title).font(.headline).lineLimit(1)
                                        if let subtitle = track.subtitle {
                                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Text(MusicFormat.duration(track.duration))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                // Never clip a focused row's lift, shadow or border.
                .scrollClipDisabled()
            }
        }
    }
}
#endif
