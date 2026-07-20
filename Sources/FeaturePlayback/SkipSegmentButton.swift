#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreModels
import CoreUI

/// The focusable "Skip Intro" / "Skip Credits" button shown in the lower-right,
/// lifted to sit just above the scrub bar, while playback is inside a
/// server-detected intro/credits segment. Hosted in its own UIKit focus context
/// (`PlayerInputViewController`) so it can take Siri-Remote focus the moment a
/// segment begins, like the Apple TV app's skip affordance.
///
/// Select → seek past the segment (`actions.skipSegment`). Menu / swipe-up →
/// dismiss without seeking (`actions.dismissSkip`). The button only renders when
/// `model.isPresentingSkipButton` is true and no menu is open
/// (`!controlBarVisible`) — i.e. the container has actually presented it for the
/// active segment — so it collapses to nothing between segments and never draws
/// over an open menu or intercepts focus the container hasn't handed it.
///
/// A slim bar beneath the label depletes over the segment's window so the viewer
/// can see, at a glance, how much longer the button will remain before it clears.
struct SkipSegmentButton: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    let onSkip: () -> Void
    let onDismiss: () -> Void
    let onPlayPause: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if model.isPresentingSkipButton, !model.controlBarVisible, let segment = model.activeSkipSegment {
                    skipControl(for: segment)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let notice = model.autoSkipNotice, !model.controlBarVisible {
                    autoSkipNotice(notice)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Anchored bottom-right but lifted clear of the transport cluster
            // (scrubber + button row) so it always sits *above* the scrub bar.
            // Trailing inset matches the control bar's 60pt edge for alignment.
            .padding(.trailing, 60)
            .padding(.bottom, 200)
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.isPresentingSkipButton)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.autoSkipNotice)
        .onAppear { focused = true }
    }

    @ViewBuilder
    private func skipControl(for segment: MediaSegment) -> some View {
        let button = Button(action: onSkip) {
            HStack(spacing: 18) {
                Text(segment.kind.skipActionLabel)
                RemainingRing(fraction: ringFraction(for: segment), focused: focused)
            }
            .padding(.leading, 28)
            .padding(.trailing, 18)
            .padding(.vertical, 14)
        }
        .buttonStyle(SkipButtonStyle(focused: focused))
        .focused($focused)
        #if os(tvOS)
        button
            .onExitCommand { onDismiss() }
        // Play/Pause works while the button holds focus: toggle playback in place
        // (the ring freezes because it tracks playback position) without leaving
        // the affordance. Matches Brandon's ask — pause without losing the button.
            .onPlayPauseCommand { onPlayPause() }
            .onMoveCommand { direction in
                // An upward swipe dismisses the affordance, matching the player's
                // other Up gestures (which surface the transport / leave the button).
                if direction == .up { onDismiss() }
            }
        #else
        button
        #endif
    }

    /// The countdown ring's remaining fraction. In Auto (delay) it depletes over
    /// the auto-skip wait (so the viewer sees "skipping in…"); otherwise it shows
    /// how much of the segment window remains before the button auto-dismisses.
    private func ringFraction(for segment: MediaSegment) -> Double {
        if model.skipMode == .autoDelay, let deadline = model.autoSkipAtSeconds {
            let remaining = deadline - model.currentSeconds
            return min(1, max(0, remaining / SkipIntrosMode.autoSkipDelay))
        }
        return segment.remainingFraction(at: model.currentSeconds)
    }

    /// Passive confirmation shown after an instant auto-skip (no button). Uses the
    /// system Liquid Glass material on tvOS 26+, with a translucent fallback on
    /// older systems — no custom capsule styling.
    @ViewBuilder
    private func autoSkipNotice(_ notice: AutoSkipNotice) -> some View {
        let label = HStack(spacing: 14) {
            Image(systemName: "forward.fill")
            Text(notice.label)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)

        if #available(iOS 26.0, tvOS 26.0, *) {
            label.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            label.background(
                Capsule(style: .continuous).fill(.ultraThinMaterial)
            )
        }
    }
}

/// The depleting "time remaining" indicator: a countdown ring that drains
/// clockwise from full to empty as the segment plays out, mirroring the circular
/// countdown on the Quick Connect / Plex link QR screens. Position samples in
/// ~300ms steps, so the trim is animated linearly to glide between updates.
private struct RemainingRing: View {
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
        .frame(width: 38, height: 38)
        .animation(.linear(duration: 0.3), value: fraction)
    }
}

/// High-contrast pill that reads clearly over any frame, brightening on focus.
private struct SkipButtonStyle: ButtonStyle {
    let focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(focused ? Color.black : Color.white)
            .background(
                Capsule(style: .continuous)
                    .fill(focused ? Color.white : Color.black.opacity(0.55))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(focused ? 0 : 0.5), lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : (focused ? 1.06 : 1.0))
            .shadow(color: .black.opacity(focused ? 0.4 : 0.25), radius: focused ? 18 : 8, y: 6)
            .animation(.easeOut(duration: 0.18), value: focused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif
