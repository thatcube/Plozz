#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

// Input-timing layer for the hero's directional navigation, relocated verbatim
// from HomeHeroView. It does NOT make the focus/paging decisions (those remain in
// HomeHeroView) — it only records physical arrow begin/end phases and gates early
// key-repeat. The navigation behavior itself is unchanged here; this file exists
// purely to shrink the view. (The paging still has known double-navigation/edge
// quirks we've been unable to improve without regressing it — deliberately left
// exactly as-is.)

/// Distinguishes a physical arrow's first focus move from early key-repeat moves
/// emitted while that same press is held. Repeats resume after the standard
/// deliberate-hold delay; with no active physical press, every move is an
/// indirect-touch swipe and remains unrestricted.
@MainActor
final class HeroDirectionalPressGate {
    private let repeatDelay: TimeInterval
    private let now: () -> TimeInterval
    private var leftHeld = false
    private var rightHeld = false
    private var handledLeft = false
    private var handledRight = false
    private var leftBeganAt: TimeInterval = 0
    private var rightBeganAt: TimeInterval = 0

    init(
        repeatDelay: TimeInterval = 0.45,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.repeatDelay = repeatDelay
        self.now = now
    }

    func began(_ direction: HeroFocusDirection) {
        switch direction {
        case .left:
            if !leftHeld {
                leftHeld = true
                handledLeft = false
                leftBeganAt = now()
            }
        case .right:
            if !rightHeld {
                rightHeld = true
                handledRight = false
                rightBeganAt = now()
            }
        }
    }

    func ended(_ direction: HeroFocusDirection) {
        switch direction {
        case .left:
            leftHeld = false
            handledLeft = false
        case .right:
            rightHeld = false
            handledRight = false
        }
    }

    func shouldHandle(_ direction: HeroFocusDirection) -> Bool {
        switch direction {
        case .left:
            guard leftHeld else { return true }
            if !handledLeft {
                handledLeft = true
                return true
            }
            return now() - leftBeganAt >= repeatDelay
        case .right:
            guard rightHeld else { return true }
            if !handledRight {
                handledRight = true
                return true
            }
            return now() - rightBeganAt >= repeatDelay
        }
    }
}

/// Installs a passive press-lifecycle observer on the window without replacing or
/// wrapping the hero's SwiftUI focus leaf. The recognizer never succeeds, never
/// cancels/delays delivery, and cannot compete with other recognizers; it only
/// records arrow begin/end phases for ``HeroDirectionalPressGate``.
struct HeroDirectionalPressMonitor: UIViewRepresentable {
    var capturesLeft: Bool
    let gate: HeroDirectionalPressGate
    /// Fired when a physical **Select** click completes while the caller deems the
    /// hero focused. Routes Select through this reliable window-level observer
    /// instead of relying solely on the SwiftUI `.onTapGesture`, which the focus
    /// engine can silently swallow when the hero's `@FocusState` desyncs from the
    /// real focus during rapid paging (the "all hero buttons go dead" bug). The
    /// caller gates on hero focus and de-dupes against the tap path.
    var onSelect: (() -> Void)?

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.monitor.gate = gate
        view.monitor.capturesLeft = capturesLeft
        view.monitor.onSelect = onSelect
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        uiView.monitor.gate = gate
        uiView.monitor.capturesLeft = capturesLeft
        uiView.monitor.onSelect = onSelect
    }

    final class InstallerView: UIView {
        let monitor = PressLifecycleRecognizer()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard monitor.view !== window else { return }
            monitor.view?.removeGestureRecognizer(monitor)
            window?.addGestureRecognizer(monitor)
        }

        deinit {
            monitor.view?.removeGestureRecognizer(monitor)
        }
    }

    final class PressLifecycleRecognizer: UIGestureRecognizer {
        var capturesLeft = true
        weak var gate: HeroDirectionalPressGate?
        /// Invoked on a completed Select click (see `HeroDirectionalPressMonitor`).
        var onSelect: (() -> Void)?

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            allowedPressTypes = [
                NSNumber(value: UIPress.PressType.leftArrow.rawValue),
                NSNumber(value: UIPress.PressType.rightArrow.rawValue),
                NSNumber(value: UIPress.PressType.select.rawValue)
            ]
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        convenience init() {
            self.init(target: nil, action: nil)
        }

        override func pressesBegan(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent
        ) {
            for press in presses {
                switch press.type {
                case .leftArrow where capturesLeft:
                    HeroFocusDiagnostics.emit("began physical Left")
                    gate?.began(.left)
                case .rightArrow:
                    HeroFocusDiagnostics.emit("began physical Right")
                    gate?.began(.right)
                default:
                    break
                }
            }
        }

        override func pressesChanged(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent
        ) {
        }

        override func pressesEnded(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent
        ) {
            finish(presses)
            state = .failed
        }

        override func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent
        ) {
            finish(presses)
            state = .failed
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        private func finish(_ presses: Set<UIPress>) {
            for press in presses {
                switch press.type {
                case .leftArrow:
                    HeroFocusDiagnostics.emit("ended physical Left")
                    gate?.ended(.left)
                case .rightArrow:
                    HeroFocusDiagnostics.emit("ended physical Right")
                    gate?.ended(.right)
                case .select:
                    // A completed Select click. The caller's closure gates on hero
                    // focus and de-dupes against the SwiftUI tap path, so this is a
                    // no-op unless the tap was swallowed (the desync dead state).
                    onSelect?()
                default:
                    break
                }
            }
        }
    }
}

/// A barely visible, mode-aware edge that separates solid hero text from artwork.
struct HeroTextLegibilityShadow: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content.shadow(
            color: (colorScheme == .dark ? Color.black : Color.white).opacity(0.4),
            radius: 4,
            y: 1
        )
    }
}
#endif
