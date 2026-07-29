#if os(tvOS) && canImport(UIKit)
import SwiftUI
import UIKit

/// Stops a Back press from quitting the app while nothing is focused.
///
/// Dismissing a native context menu leaves a short window in which the focus
/// engine has released the lifted card but has not yet settled focus back onto
/// the page. A Back press landing in that window has no in-app responder to
/// receive it, so tvOS routes it to the system and the app exits — the user
/// asked to close a menu and lost the whole app.
///
/// The rule here is deliberately narrow: **swallow Back only while the focus
/// system reports no focused item.** That is exactly the broken state, and it is
/// a state the user can never have meant "exit" from, because every legitimate
/// Back press happens with something focused. Anything focused and this
/// recognizer declines the press entirely, so `onExitCommand`, `NavigationStack`
/// pops and quitting from the real root all behave exactly as before.
///
/// Researching this first mattered: the tempting fixes are worse. A blanket
/// Menu recognizer breaks AVKit's own remote handling and can trap the user in
/// the app; a timed post-dismissal window can't be driven by anything real,
/// because SwiftUI exposes no context-menu dismissal callback, and a fixed
/// duration is wrong across devices. Apple's own guidance is that Back opens the
/// parent — at the true root that IS the Home screen, so this must never
/// intercept there.
///
/// Attached to the window rather than to this representable's own view: a small
/// sibling view is not reliably in the press event path.
public struct TVBackButtonGuard: UIViewRepresentable {
    public init() {}

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        // The window only exists once the view joins the hierarchy.
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        // Scene restoration can hand us a new window; re-attaching is a no-op
        // when it is the one we already guard.
        context.coordinator.attach(to: uiView.window)
    }

    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var guardedWindow: UIWindow?
        private var recognizer: UITapGestureRecognizer?

        func attach(to window: UIWindow?) {
            guard let window, window !== guardedWindow else { return }
            if let recognizer { guardedWindow?.removeGestureRecognizer(recognizer) }

            let tap = UITapGestureRecognizer(target: self, action: #selector(swallowBack))
            tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            tap.delegate = self
            window.addGestureRecognizer(tap)

            guardedWindow = window
            recognizer = tap
        }

        /// Deliberately empty. The press has already been consumed by being
        /// recognized; doing nothing is the whole point. Focus settles a moment
        /// later and the next Back press routes normally.
        @objc private func swallowBack() {}

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive press: UIPress
        ) -> Bool {
            guard press.type == .menu else { return false }
            // Declining leaves the press untouched for the normal responder
            // chain, which is what must happen in every state except the broken
            // one.
            return shouldSwallow
        }

        /// Whether the focus engine currently has a focused item anywhere.
        ///
        /// `nil` here means the press would fall through to the system.
        /// The states in which a Back press cannot have meant "quit the app".
        ///
        /// Both conditions were arrived at by measuring on device rather than
        /// reasoning:
        ///
        ///   * Focus sitting on the CONTEXT MENU itself. This is the real case —
        ///     the focus engine keeps reporting the menu's own cell while the
        ///     menu animates away, so the press finds no in-app responder and
        ///     tvOS quits. "Focus is nil" never fired here, and the menu's SwiftUI
        ///     content never reports appear/disappear on tvOS, so neither of the
        ///     obvious signals exists.
        ///   * Nothing focused at all — kept as a backstop for any other
        ///     transient state.
        ///
        /// Swallowing here cannot strand the viewer: tvOS dismisses an open menu
        /// through its own gesture handling, which this recognizer does not
        /// replace, and once the menu is gone focus returns to the page and this
        /// stops firing.
        @MainActor
        private var shouldSwallow: Bool {
            if focusIsInsideContextMenu { return true }
            return !hasFocusedItem
        }

        /// Whether the focused item belongs to a native context menu.
        ///
        /// Matched on class-name shape rather than a hardcoded private symbol, and
        /// read-only: if Apple renames these internals the check simply stops
        /// matching and behaviour reverts to what it was before this guard
        /// existed. That is an acceptable failure mode for a fix whose absence is
        /// "the app occasionally quits"; a hard dependency on a private class
        /// would not be.
        private var focusIsInsideContextMenu: Bool {
            guard let guardedWindow,
                  let system = UIFocusSystem.focusSystem(for: guardedWindow),
                  let focused = system.focusedItem
            else { return false }

            if Self.isContextMenuClass(type(of: focused)) { return true }
            var view = (focused as? UIView)?.superview
            while let current = view {
                if Self.isContextMenuClass(type(of: current)) { return true }
                view = current.superview
            }
            return false
        }

        private static func isContextMenuClass(_ type: Any.Type) -> Bool {
            String(describing: type).contains("ContextMenu")
        }

        private var hasFocusedItem: Bool {
            guard let guardedWindow,
                  let system = UIFocusSystem.focusSystem(for: guardedWindow)
            else {
                // No focus system to consult — stay out of the way rather than
                // risk trapping the user in the app.
                return true
            }
            return system.focusedItem != nil
        }
    }
}

public extension View {
    /// See ``TVBackButtonGuard``. Install once, at the app's root.
    func tvBackButtonGuard() -> some View {
        background(TVBackButtonGuard().frame(width: 0, height: 0))
    }
}
#endif
