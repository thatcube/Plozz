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

/// Whether the Now Playing card is currently focused, injected by its button
/// style so the card's inner content (title, subtitle, equalizer) can flip its
/// colors to match the contrast-inverted focused fill. Mirrors the Settings
/// rows' `settingsRowIsFocused` pattern.
private struct NowPlayingCardFocusedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var nowPlayingCardFocused: Bool {
        get { self[NowPlayingCardFocusedKey.self] }
        set { self[NowPlayingCardFocusedKey.self] = newValue }
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

    /// When true the card stretches to fill its container's width (equalizer
    /// pinned to the trailing edge) so it can line up with sibling controls.
    var fillWidth: Bool = false

    var body: some View {
        if controller.hasActivePlayback, let track = controller.currentTrack {
            Button(action: openNowPlaying) {
                NowPlayingCardContent(
                    track: track,
                    isPlaying: controller.isPlaying,
                    textWidth: textWidth,
                    fillWidth: fillWidth
                )
            }
            // A fully custom ButtonStyle (rather than `.plain`) so tvOS doesn't
            // draw its own focus plate over our inverted fill — `.plain` keeps a
            // system hover plate that `.focusEffectDisabled()` doesn't fully
            // remove, which read as a grey overlay covering the contrast flip.
            .buttonStyle(NowPlayingCardButtonStyle())
            .focusEffectDisabled()
        }
    }
}

/// The Now Playing card's inner content. Reads `\.nowPlayingCardFocused`
/// (injected by `NowPlayingCardButtonStyle`) so its text and equalizer flip to
/// the inverted foreground when the card is focused.
private struct NowPlayingCardContent: View {
    let track: MusicTrack
    let isPlaying: Bool
    let textWidth: CGFloat
    var fillWidth: Bool = false

    @Environment(\.nowPlayingCardFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    // Idle: liquid glass with normal theme content colors.
    // Focused: solid contrast-flip fill, so content inverts to stay legible.
    //   Light theme focus → black card, white content.
    //   Dark / OLED focus → white card, black content.
    private var focusForeground: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
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
                    .foregroundStyle(isFocused ? AnyShapeStyle(focusForeground) : AnyShapeStyle(.primary))
                if let subtitle = track.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(isFocused ? AnyShapeStyle(focusForeground.opacity(0.72)) : AnyShapeStyle(.secondary))
                }
            }
            .frame(maxWidth: textWidth, alignment: .leading)

            if fillWidth { Spacer(minLength: 12) }

            Group {
                if isPlaying {
                    // Flip the equalizer bars to the inverted foreground on focus
                    // so they stay legible on the solid contrast fill.
                    NowPlayingEqualizer(isAnimating: true, tint: isFocused ? focusForeground : nil)
                        .frame(width: 22)
                } else {
                    Image(systemName: "pause.fill")
                        .font(.subheadline)
                        .foregroundStyle(isFocused ? AnyShapeStyle(focusForeground.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 28)
        .padding(.vertical, 16)
        .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
    }
}

/// Theme-aware focus treatment for the Now Playing card: the whole card flips
/// contrast on focus (light theme → black fill, dark/OLED → white fill), an
/// opaque fill fading in over the idle material, plus a lift + shadow. Injects
/// `\.nowPlayingCardFocused` so the card's content flips its colors to match.
private struct NowPlayingCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorScheme) private var colorScheme

        // Match the browsing tiles below: same rounded glass corner radius.
        private let shape = RoundedRectangle(
            cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius,
            style: .continuous
        )

        // Focused fill is the contrast flip: black card on a light theme, white
        // card on a dark/OLED theme. Idle uses liquid glass instead.
        private var focusFill: Color { colorScheme == .dark ? .white : .black }

        var body: some View {
            configuration.label
                .environment(\.nowPlayingCardFocused, isFocused)
                .contentShape(shape)
                // Idle = the same Liquid Glass surface as the cards below; on focus
                // a solid contrast fill cross-fades in so the playing item flips to
                // a high-contrast block.
                .background {
                    Color.clear
                        .plozzGlassCard(
                            cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius,
                            isFocused: false
                        )
                        .overlay { shape.fill(focusFill).opacity(isFocused ? 1 : 0) }
                }
                .clipShape(shape)
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.03 : 1.06) : 1)
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0.18), radius: isFocused ? 18 : 8, y: isFocused ? 8 : 4)
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
