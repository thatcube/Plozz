#if os(tvOS)
import SwiftUI
import UIKit

/// Resolves a directional press that had nowhere else to go: Left opens the
/// navigation rail, Right returns focus to the page.
///
/// ### Why this is not a focusable view
/// Left must reach the navigation from anywhere on the page, and no amount of
/// geometry achieves that. The page's grids and rails are `.focusSection()`s, and
/// so is the rail; moving Left off a poster therefore asks the focus engine to
/// leave one section and enter another, which it frequently declines. That is why
/// Left worked from a page header (whose section has nothing to its left, forcing
/// a clean exit) and did nothing from the grid below it — and why adding a
/// full-height focusable target down the leading edge changed nothing: the target
/// was always there and focusable, the engine simply never moved to it.
///
/// ### What this does instead
/// A passive recognizer on the window observes Left presses without consuming
/// them, so every existing Left behaviour is untouched — stepping between hero
/// buttons, paging the carousel, moving along a row. It then checks whether focus
/// actually moved. Only when it did NOT — a Left that went nowhere — does the
/// rail claim focus.
///
/// The same is true leaving the rail. Right out of a rail row only reached the
/// page when something happened to sit level with it — the hero's buttons are far
/// down the screen, so Right from Home or Search did nothing at all. A Right that
/// resolves to nothing hands focus back to the page instead.
///
/// This is deliberately a *fallback* rather than an interception: neither
/// direction can steal a press that had a real use, and a press that dead ends
/// anywhere in the app still does the obvious thing.
struct NavigationRailEdgeCatcher: UIViewRepresentable {
    /// Called when a Left press resolved to nothing, so the rail should take focus.
    var onOpenNavigation: () -> Void
    /// Called when a Right press inside the rail resolved to nothing, so focus
    /// should return to the page.
    var onLeaveNavigation: () -> Void
    /// Whether the rail currently holds focus. Decides which direction is the
    /// meaningful one: Left into the rail, or Right back out of it.
    var railHasFocus: Bool
    /// Whether the catcher is listening at all — false while the rail is hidden
    /// (a detail page).
    var isEnabled: Bool

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.recognizer.onOpenNavigation = onOpenNavigation
        view.recognizer.onLeaveNavigation = onLeaveNavigation
        view.recognizer.railHasFocus = railHasFocus
        view.recognizer.isEnabled = isEnabled
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        uiView.recognizer.onOpenNavigation = onOpenNavigation
        uiView.recognizer.onLeaveNavigation = onLeaveNavigation
        uiView.recognizer.railHasFocus = railHasFocus
        uiView.recognizer.isEnabled = isEnabled
    }

    /// Hosts the recognizer on the window.
    ///
    /// The recognizer has to live on the window, not on this view: a press is
    /// delivered to the focused element's responder chain, which a zero-size view
    /// off to one side is never part of.
    final class InstallerView: UIView {
        let recognizer = LeftPressRecognizer()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard recognizer.view !== window else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }

        deinit {
            MainActor.assumeIsolated {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }
    }

    /// Observes directional presses and reports the ones that changed nothing.
    final class LeftPressRecognizer: UIGestureRecognizer {
        var onOpenNavigation: (() -> Void)?
        var onLeaveNavigation: (() -> Void)?
        var railHasFocus = false

        /// How long to wait before deciding a press went nowhere.
        ///
        /// This is dead time on the fallback path — the rail cannot open until it
        /// elapses — so it is kept as short as the check allows. A focus update
        /// completes within a frame or two (~16-33ms); 70ms is several frames of
        /// margin while staying under the threshold where a delay reads as lag.
        private static let settleDelay = Duration.milliseconds(70)

        private var pendingCheck: Task<Void, Never>?

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            allowedPressTypes = [
                NSNumber(value: UIPress.PressType.leftArrow.rawValue),
                NSNumber(value: UIPress.PressType.rightArrow.rawValue)
            ]
            // Purely an observer: it must never swallow the press, delay it, or
            // interfere with the gestures that implement normal navigation.
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        convenience init() {
            self.init(target: nil, action: nil)
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            // Only the direction that would cross the rail boundary is watched:
            // Left while focus is on the page, Right while it is in the rail.
            let watched: UIPress.PressType = railHasFocus ? .rightArrow : .leftArrow
            guard isEnabled, presses.contains(where: { $0.type == watched }) else {
                super.pressesBegan(presses, with: event)
                return
            }

            let before = Self.focusedItem()
            let wasInRail = railHasFocus
            pendingCheck?.cancel()
            pendingCheck = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.settleDelay)
                guard !Task.isCancelled, let self, self.isEnabled else { return }
                // Focus moved, so the press had a genuine use and neither the
                // navigation nor the page needs to intervene.
                guard Self.focusedItem() === before else { return }
                if wasInRail {
                    self.onLeaveNavigation?()
                } else {
                    self.onOpenNavigation?()
                }
            }

            // Never recognise: the press belongs to whatever the page does with it.
            state = .failed
            super.pressesBegan(presses, with: event)
        }

        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }

        /// The element that currently holds focus, or `nil` if there is none.
        @MainActor
        private static func focusedItem() -> UIFocusItem? {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else {
                return nil
            }
            return UIFocusSystem(for: window)?.focusedItem
        }
    }
}
#endif
