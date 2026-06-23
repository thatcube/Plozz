#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI

/// A slim persistent bar shown at the bottom of the Music tab **only while audio
/// is loaded**. It is focusable (reachable by swiping down from the grid) but
/// does not auto-grab focus on appearance, per the focus-engine requirement.
/// Selecting it opens the full Now Playing screen.
struct MiniPlayerBar: View {
    @Bindable var controller: AudioPlaybackController
    let onOpen: () -> Void

    var body: some View {
        if controller.hasActivePlayback, let track = controller.currentTrack {
            HStack(spacing: 20) {
                Button(action: onOpen) {
                    HStack(spacing: 16) {
                        MusicArtworkImage(
                            url: track.artworkURL,
                            systemPlaceholder: "music.note",
                            cornerRadius: 8,
                            asyncFallbackURL: MusicArtworkFallback.trackCover(
                                title: track.title,
                                album: track.albumTitle,
                                artist: track.artistName
                            )
                        )
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.headline).lineLimit(1)
                            if let subtitle = track.subtitle {
                                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 64, height: 64)
                }
                .buttonStyle(.plain)

                Button { controller.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .frame(width: 64, height: 64)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                ProgressBar(fraction: controller.progressFraction)
                    .frame(height: 4)
            }
        }
    }
}

/// A simple non-interactive progress indicator (the mini-player and Now Playing
/// scrubber share it). Seeking is done via on-screen buttons / the remote's
/// change-playback-position command.
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.2))
                Rectangle().fill(.tint)
                    .frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
    }
}

extension AudioPlaybackController {
    /// 0...1 progress of the current track, safe when duration is unknown.
    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }
}
#endif
