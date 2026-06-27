#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreModels
import CoreUI

/// The focusable "Skip Intro" / "Skip Credits" button shown bottom-trailing while
/// playback is inside a server-detected intro/credits segment. Hosted in its own
/// UIKit focus context (`PlayerInputViewController`) so it can take Siri-Remote
/// focus the moment a segment begins, like the Apple TV app's skip affordance.
///
/// Select → seek past the segment (`actions.skipSegment`). Menu / swipe-up →
/// dismiss without seeking (`actions.dismissSkip`). The button only renders when
/// `model.activeSkipSegment` is non-nil; otherwise it collapses to nothing so it
/// never intercepts focus between segments.
struct SkipSegmentButton: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    let onSkip: () -> Void
    let onDismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let segment = model.activeSkipSegment {
                    Button(action: onSkip) {
                        HStack(spacing: 12) {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 24, weight: .semibold))
                            Text(segment.kind.skipActionLabel)
                                .font(.title3.weight(.semibold))
                        }
                        .padding(.horizontal, 30)
                        .padding(.vertical, 18)
                    }
                    .buttonStyle(SkipButtonStyle(focused: focused))
                    .focused($focused)
                    .onExitCommand { onDismiss() }
                    .onMoveCommand { direction in
                        // An upward swipe dismisses the affordance back to the
                        // scrub surface, matching the player's other Up gestures.
                        if direction == .up { onDismiss() }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.trailing, 80)
            .padding(.bottom, 90)
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.activeSkipSegment)
        .onAppear { focused = true }
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
