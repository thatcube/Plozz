#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI

/// The compact, focusable "Now Playing" affordance that floats in the
/// **top-trailing corner** of the Music tab while audio is loaded. Selecting it
/// opens the full Now Playing screen.
///
/// It floats top-trailing (not a pinned bottom bar) on purpose: a focusable bar
/// pinned to the bottom sits "below" the content in the tvOS focus graph, so
/// pressing **down** through a vertical track list fights the focus engine and
/// jumps into the bar. A top-trailing element is only reachable by moving
/// *up/right*, so it never competes with downward list navigation.
struct NowPlayingPill: View {
    @Bindable var controller: AudioPlaybackController

    let onOpen: () -> Void

    var body: some View {
        if controller.hasActivePlayback, let track = controller.currentTrack {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    MusicArtworkImage(
                        url: track.artworkURL,
                        systemPlaceholder: "music.note",
                        cornerRadius: 6,
                        asyncFallbackURL: MusicArtworkFallback.trackCover(
                            title: track.title,
                            album: track.albumTitle,
                            artist: track.artistName
                        )
                    )
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let subtitle = track.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 220, alignment: .leading)

                    Group {
                        if controller.isPlaying {
                            NowPlayingEqualizer(isAnimating: true)
                                .frame(width: 22)
                        } else {
                            Image(systemName: "pause.fill")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 22)
                .padding(.vertical, 10)
                .contentShape(Capsule())
            }
            .buttonStyle(NowPlayingPillButtonStyle())
            .focusEffectDisabled()
            .background(.thinMaterial, in: Capsule())
            .clipShape(Capsule())
        }
    }
}

/// A gentle lift + shadow when the floating Now Playing pill is focused, in
/// keeping with the app's card focus language.
private struct NowPlayingPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .overlay {
                    Capsule().stroke(.white.opacity(isFocused ? 0.5 : 0), lineWidth: 1)
                }
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.03 : 1.06) : 1)
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 18, y: 8)
                .animation(.easeOut(duration: 0.16), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
