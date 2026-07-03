import CoreModels

/// The direction of a left/right move command on the hero carousel.
public enum HeroFocusDirection: Sendable, Equatable {
    case left
    case right
}

/// What a left/right move on the hero should do. Pure result the view applies.
public enum HeroFocusOutcome: Equatable, Sendable {
    /// An interior move between buttons of the *current* item — move focus to
    /// this button index. (The focus engine would do this natively; modelled so
    /// the whole behaviour is testable in one place.)
    case moveButton(Int)
    /// Advance the carousel to `toItem`, keeping focus on `keepButton` for the
    /// new item. The caller clamps `keepButton` to the destination item's actual
    /// button count (a Seerr/featured slide may expose fewer buttons than a
    /// library title).
    case advance(toItem: Int, keepButton: Int)
    /// Let the system handle the move — used at the first item's left edge in
    /// Sidebar mode so Left opens the side navigation instead of wrapping.
    case escape
    /// The move is blocked with nothing to do (e.g. a single-item carousel at an
    /// edge). Focus stays put.
    case blocked
}

/// Pure reducer for the Home hero carousel's focus/paging behaviour.
///
/// Encodes the exact model brandon specified:
/// - L/R moves focus **between the hero's buttons** normally (interior moves).
/// - At the **last (right-most) button, Right advances** the carousel to the
///   next item and **keeps the same button index** — so holding/spamming Right
///   pages through items one by one. Forward paging **always wraps** (last →
///   first).
/// - At the **first (left-most) button, Left goes to the previous item**, again
///   keeping the button index. Backward paging **wraps only in Top-Bar
///   navigation**.
/// - In **Sidebar** navigation, when on the **first item** and the **left-most
///   button**, Left **escapes to the side navigation** instead of wrapping —
///   preventing a focus fight with the sidebar. (Top-Bar has no left chrome, so
///   there Left wraps backward to the last item.)
///
/// SwiftUI-free and exhaustively testable.
public enum HeroCarouselFocus {
    public static func resolve(
        direction: HeroFocusDirection,
        itemIndex: Int,
        itemCount: Int,
        focusedButton: Int,
        buttonCount: Int,
        navigationStyle: NavigationStyle
    ) -> HeroFocusOutcome {
        guard itemCount > 0, buttonCount > 0 else { return .blocked }
        let lastButton = buttonCount - 1

        switch direction {
        case .right:
            // Interior: move to the next button.
            if focusedButton < lastButton {
                return .moveButton(focusedButton + 1)
            }
            // At the right edge: advance forward (always wraps). A single-item
            // carousel has nowhere to go.
            guard itemCount > 1 else { return .blocked }
            let next = (itemIndex + 1) % itemCount
            return .advance(toItem: next, keepButton: focusedButton)

        case .left:
            // Interior: move to the previous button.
            if focusedButton > 0 {
                return .moveButton(focusedButton - 1)
            }
            // At the left edge of the FIRST item, behaviour depends on nav chrome.
            if itemIndex == 0 {
                switch navigationStyle {
                case .sidebar:
                    // Hand the move to the system so the sidebar opens; don't wrap.
                    return .escape
                case .tabBar:
                    // No left chrome to fight — wrap backward to the last item.
                    guard itemCount > 1 else { return .blocked }
                    return .advance(toItem: itemCount - 1, keepButton: focusedButton)
                }
            }
            // Any later item: step to the previous item, keeping the button index.
            return .advance(toItem: itemIndex - 1, keepButton: focusedButton)
        }
    }
}
