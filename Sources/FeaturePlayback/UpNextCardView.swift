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
/// The card only renders when `model.upNextActive` is true — a next episode is
/// queued and the live position is inside the (seek-respecting) credits window —
/// so it never collides with the Skip Credits button (they share this slot and
/// are mutually exclusive by construction).
///
/// The thumbnail and title are run through the user's Spoiler settings up front
/// (in the view model), so an unwatched next episode never leaks its frame.
struct UpNextCardView: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    let onPlayNext: () -> Void
    let onDismiss: () -> Void
    let onPlayPause: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if model.upNextActive, let info = model.upNext {
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
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.upNextActive)
        .onAppear { focused = true }
    }

    @ViewBuilder
    private func card(for info: UpNextInfo) -> some View {
        Button(action: onPlayNext) {
            HStack(spacing: 22) {
                thumbnail(for: info)

                VStack(alignment: .leading, spacing: 4) {
                    Text(info.eyebrow.uppercased())
                        .font(.caption.weight(.heavy))
                        .tracking(1.4)
                        .foregroundStyle(focused ? Color.black.opacity(0.65) : Color.white.opacity(0.7))
                    Text(info.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if let subtitle = info.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(focused ? Color.black.opacity(0.7) : Color.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 280, alignment: .leading)

                trailingControl
            }
            .padding(.leading, 18)
            .padding(.trailing, 26)
            .padding(.vertical, 16)
        }
        .buttonStyle(UpNextCardStyle(focused: focused))
        .focused($focused)
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
    }

    @ViewBuilder
    private func thumbnail(for info: UpNextInfo) -> some View {
        FallbackAsyncImage(urls: info.thumbnailURLs) {
            ZStack {
                Rectangle().fill(Color.white.opacity(0.08))
                Image(systemName: "play.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: 176, height: 99)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .blur(radius: info.blurThumbnail ? 18 : 0)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    /// A countdown ring while Auto (delay) is advancing; otherwise a Play glyph.
    @ViewBuilder
    private var trailingControl: some View {
        if model.skipMode == .autoDelay, let deadline = model.upNextAdvanceAtSeconds {
            let remaining = deadline - model.currentSeconds
            let fraction = min(1, max(0, remaining / SkipIntrosMode.autoSkipDelay))
            ZStack {
                CountdownRing(fraction: fraction, focused: focused)
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(focused ? Color.black : Color.white)
            }
        } else {
            Image(systemName: "play.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(focused ? Color.black : Color.white)
                .frame(width: 38, height: 38)
        }
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
                .stroke(foreground.opacity(0.22), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(foreground, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 40, height: 40)
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(focused ? Color.white : Color.black.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(focused ? 0 : 0.5), lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (focused ? 1.04 : 1.0))
            .shadow(color: .black.opacity(focused ? 0.4 : 0.25), radius: focused ? 18 : 8, y: 6)
            .animation(.easeOut(duration: 0.18), value: focused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif
