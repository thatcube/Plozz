#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI

/// An action that opens the full-screen Now Playing screen, plumbed down the
/// Music tab's view tree so the scrolling `NowPlayingCard` (which now lives
/// inside each page's header, not as a fixed overlay) can trigger it from deep
/// in the navigation stack without threading a closure through every screen.
private struct OpenNowPlayingKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openNowPlaying: () -> Void {
        get { self[OpenNowPlayingKey.self] }
        set { self[OpenNowPlayingKey.self] = newValue }
    }
}

/// The compact, focusable "Now Playing" affordance shown while audio is loaded.
/// Selecting it opens the full Now Playing screen.
///
/// Unlike the old fixed top-trailing pill, this card lives **inside each page's
/// header and scrolls with the page**. It self-hides when nothing is playing, so
/// it can be dropped into any header and a placement with no active playback
/// simply renders nothing. The open action comes from `\.openNowPlaying` in the
/// environment, injected once at the Music tab root.
struct NowPlayingCard: View {
    var controller: AudioPlaybackController
    @Environment(\.openNowPlaying) private var openNowPlaying

    /// Maximum width for the title/subtitle column. Wider than the old pill so
    /// the average song title + "Artist · Album" line fits without truncation.
    var textWidth: CGFloat = 320

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        if controller.hasActivePlayback, let track = controller.currentTrack {
            Button(action: openNowPlaying) {
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
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let subtitle = track.subtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: textWidth, alignment: .leading)

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
                .padding(.leading, 12)
                .padding(.trailing, 22)
                .padding(.vertical, 10)
                .contentShape(shape)
            }
            .buttonStyle(NowPlayingCardButtonStyle())
            .focusEffectDisabled()
            .background(.thinMaterial, in: shape)
            .clipShape(shape)
        }
    }
}

/// A gentle lift + shadow when the Now Playing card is focused, in keeping with
/// the app's card focus language.
private struct NowPlayingCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            configuration.label
                .overlay {
                    shape.stroke(.white.opacity(isFocused ? 0.5 : 0), lineWidth: 1)
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
