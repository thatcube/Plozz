#if canImport(UIKit)
import SwiftUI
import UIKit

/// The axis/intent of a reveal gesture performed on the hidden Now Playing
/// transport. Vertical (and Select) reveals land focus on the play/pause
/// button; horizontal reveals land it on the scrub bar (scrubbing is a
/// horizontal gesture).
enum NowPlayingReveal {
    case vertical
    case horizontal
}

/// A transparent, focusable UIKit surface shown while the Now Playing transport
/// is hidden and across the brief reveal hand-off. It intercepts Siri-Remote
/// **arrow presses** (via press-typed tap recognizers) and **swipes** (via an
/// indirect pan) and reports the reveal axis so the caller can reveal the
/// controls and place focus.
///
/// Why this works where SwiftUI-only fixes didn't: a directional *press* is
/// delivered to the focus engine as a **focus-move** the engine resolves in the
/// *same* pass as any state change (a *swipe* queues no move — that's why swipes
/// alone used to work). No `@FocusState`/`defaultFocus`/`resetFocus` set in that
/// pass can beat the move. The fix is structural: while this surface is mounted
/// it is the **only** focusable view (the caller keeps the transport
/// non-focusable across the reveal window), so the move is absorbed here
/// harmlessly; the caller then unmounts this surface and places focus on a later
/// pass, turning the hand-off into a neutral relocation. As belt-and-suspenders
/// the view also vetoes any focus move away from itself while it holds focus, so
/// a press can never relocate focus onto a control that is being revealed.
struct NowPlayingRevealSurface: UIViewRepresentable {
    var onReveal: (NowPlayingReveal) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onReveal: onReveal) }

    func makeUIView(context: Context) -> FocusView {
        let view = FocusView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator

        // Arrow / Select *presses* — each consumed as a discrete tap action so no
        // focus-move is queued behind it.
        view.addGestureRecognizer(coordinator.pressRecognizer(.upArrow, #selector(Coordinator.pressedVertical)))
        view.addGestureRecognizer(coordinator.pressRecognizer(.downArrow, #selector(Coordinator.pressedVertical)))
        view.addGestureRecognizer(coordinator.pressRecognizer(.leftArrow, #selector(Coordinator.pressedHorizontal)))
        view.addGestureRecognizer(coordinator.pressRecognizer(.rightArrow, #selector(Coordinator.pressedHorizontal)))
        view.addGestureRecognizer(coordinator.pressRecognizer(.select, #selector(Coordinator.pressedVertical)))

        // Trackpad *swipes* — resolved to an axis once past a small dead zone.
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: FocusView, context: Context) {
        context.coordinator.onReveal = onReveal
    }

    /// A transparent view that advertises itself as focusable so tvOS parks
    /// Siri-Remote focus on it while the transport is hidden — the presses/swipes
    /// above are then delivered here rather than moving focus onto a control.
    /// While it holds focus it also vetoes any move *away* from itself, so a
    /// directional press can't relocate focus onto a control revealed in the same
    /// pass. It never blocks itself from *receiving* focus, and once the caller
    /// removes it from the hierarchy the hand-off relocation proceeds normally.
    final class FocusView: UIView {
        override var canBecomeFocused: Bool { true }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            if isFocused, context.nextFocusedItem !== self { return false }
            return super.shouldUpdateFocus(in: context)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onReveal: (NowPlayingReveal) -> Void
        /// One reveal per pan gesture — set once the swipe crosses the dead zone
        /// so a single swipe doesn't fire repeatedly as it continues.
        private var panResolved = false

        init(onReveal: @escaping (NowPlayingReveal) -> Void) {
            self.onReveal = onReveal
        }

        func pressRecognizer(_ type: UIPress.PressType, _ action: Selector) -> UITapGestureRecognizer {
            let recognizer = UITapGestureRecognizer(target: self, action: action)
            recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
            return recognizer
        }

        @objc func pressedVertical() { onReveal(.vertical) }
        @objc func pressedHorizontal() { onReveal(.horizontal) }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                panResolved = false
            case .changed:
                guard !panResolved else { return }
                let translation = gesture.translation(in: view)
                // Wait for a deliberate movement before committing to an axis so a
                // tiny drift doesn't reveal the wrong way.
                let deadZone: CGFloat = 24
                guard max(abs(translation.x), abs(translation.y)) >= deadZone else { return }
                panResolved = true
                onReveal(abs(translation.x) > abs(translation.y) ? .horizontal : .vertical)
            default:
                break
            }
        }
    }
}
#endif
