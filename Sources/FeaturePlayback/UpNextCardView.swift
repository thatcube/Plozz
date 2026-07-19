#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreModels
import CoreUI

/// The focusable "Up Next" card shown in the lower-right during an episode's
/// closing credits when a next episode is queued. Hosted in its own UIKit focus
/// context (`PlayerInputViewController`) so it can take Siri-Remote focus the
/// moment credits begin, like a streaming app's next-episode affordance.
///
/// Select → advance to the next episode (`actions.playUpNext`, an in-place VM
/// swap, never a seek-to-end, so the next episode never flashes the series
/// page). Menu / swipe-up → dismiss without advancing (`actions.dismissUpNext`).
/// The card only renders when `model.isPresentingUpNext` is true and no menu is
/// open (`!controlBarVisible`) — i.e. the container has actually presented it
/// during the (seek-respecting) credits window with a next episode queued — so
/// it never draws over an open menu and never collides with the Skip Credits
/// button (they share this slot and are mutually exclusive by construction).
///
/// The thumbnail is run through the user's Spoiler settings up front (in the view
/// model), so an unwatched next episode never leaks its frame. The show name and
/// season/episode number are never spoilers, so they always show.
struct UpNextCardView: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    let onPlayNext: () -> Void
    let onDismiss: () -> Void
    let onPlayPause: () -> Void
    @FocusState private var focused: Bool
    /// Measured height of the eyebrow/title/subtitle text column. The artwork is
    /// sized to match it exactly so the two align (the text is the tallest element
    /// and its height varies with the tvOS dynamic-type fonts). Seeded with a
    /// sensible default so the first frame isn't zero-height.
    @State private var mediaHeight: CGFloat = 92

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if model.isPresentingUpNext, !model.controlBarVisible, let info = model.upNext {
                    card(for: info)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Anchored bottom-right and lifted clear of the transport cluster so
            // it always floats above the scrub bar, matching the Skip button.
            .padding(.trailing, 60)
            .padding(.bottom, 200)
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.isPresentingUpNext)
        .onAppear { focused = true }
    }

    @ViewBuilder
    private func card(for info: UpNextInfo) -> some View {
        let button = Button(action: onPlayNext) {
            HStack(spacing: 22) {
                thumbnail(for: info)

                VStack(alignment: .leading, spacing: 6) {
                    Text(info.eyebrow.uppercased())
                        .font(.caption.weight(.heavy))
                        .tracking(1.4)
                        .foregroundStyle(focused ? Color.black.opacity(0.6) : Color.white.opacity(0.65))
                    // Show name leads. It's highly variable (short sitcoms →
                    // very long anime titles), so it shrinks a step, then wraps to
                    // two lines, then truncates — always staying readable.
                    Text(info.showName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(focused ? Color.black : Color.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .truncationMode(.tail)
                    if let meta = info.metaLine {
                        Text(meta)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(focused ? Color.black.opacity(0.7) : Color.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                // Publish the text column's height so the artwork can match it.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: UpNextMediaHeightKey.self, value: geo.size.height)
                    }
                )

                trailingControl
            }
            .padding(.leading, 22)
            .padding(.trailing, 32)
            .padding(.vertical, 24)
        }
        .buttonStyle(UpNextCardStyle(focused: focused))
        .focused($focused)
        .onPreferenceChange(UpNextMediaHeightKey.self) { height in
            if height > 0 { mediaHeight = height }
        }
        #if os(tvOS)
        button
            .onExitCommand { onDismiss() }
        // Play/Pause works while the card holds focus: toggle playback in place
        // (the auto-advance ring freezes because it tracks playback position)
        // without dismissing the card or losing focus.
            .onPlayPauseCommand { onPlayPause() }
            .onMoveCommand { direction in
                // An upward swipe dismisses the card, matching the player's other Up
                // gestures (which surface the transport / leave focusable overlays).
                if direction == .up { onDismiss() }
            }
        #else
        button
        #endif
    }

    @ViewBuilder
    private func thumbnail(for info: UpNextInfo) -> some View {
        // Sized to the measured text-column height at 16:9, so the artwork spans
        // exactly the same vertical extent as the eyebrow/title/subtitle block —
        // top and bottom edges aligned — instead of a fixed height that the larger
        // tvOS fonts overflow.
        Color.clear
            .frame(width: mediaHeight * 16.0 / 9.0, height: mediaHeight)
            .overlay {
                FallbackAsyncImage(urls: info.thumbnailURLs, variant: .landscapeCard) {
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.08))
                        Image(systemName: "play.rectangle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .blur(radius: info.blurThumbnail ? 18 : 0)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
    }

    /// A larger circular play affordance — a countdown ring wraps it while Auto
    /// (delay) is advancing; otherwise it's a subtle filled circle. Sized to feel
    /// like a real button against the roomier card.
    @ViewBuilder
    private var trailingControl: some View {
        ZStack {
            // Subtle circular backing so it reads as a tappable play button.
            Circle()
                .fill(focused ? Color.black.opacity(0.08) : Color.white.opacity(0.15))

            if model.skipMode == .autoDelay, let deadline = model.upNextAdvanceAtSeconds {
                let remaining = deadline - model.currentSeconds
                let fraction = min(1, max(0, remaining / SkipIntrosMode.autoSkipDelay))
                CountdownRing(fraction: fraction, focused: focused)
            }

            Image(systemName: "play.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(focused ? Color.black : Color.white)
                // Optical centering — a play triangle reads slightly left of centre.
                .offset(x: 2)
        }
        .frame(width: 60, height: 60)
    }
}

/// A clockwise-depleting countdown ring for the Up Next card's Auto (delay)
/// advance, mirroring the Skip button's remaining-time ring.
private struct CountdownRing: View {
    let fraction: Double
    let focused: Bool

    var body: some View {
        let foreground = focused ? Color.black : Color.white
        ZStack {
            Circle()
                .stroke(foreground.opacity(0.22), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(foreground, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 58, height: 58)
        .animation(.linear(duration: 0.3), value: fraction)
    }
}

/// High-contrast card surface that brightens on focus, matching the Skip button.
private struct UpNextCardStyle: ButtonStyle {
    let focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(focused ? Color.black : Color.white)
            .background(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.card, style: .continuous)
                    .fill(focused ? Color.white : Color.black.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(focused ? 0 : 0.5), lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (focused ? 1.04 : 1.0))
            .shadow(color: .black.opacity(focused ? 0.4 : 0.25), radius: focused ? 18 : 8, y: 6)
            .animation(.easeOut(duration: 0.18), value: focused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Publishes the Up Next text column's height so the artwork can match it exactly
/// (keeping the two vertically aligned across the larger tvOS fonts).
private struct UpNextMediaHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
