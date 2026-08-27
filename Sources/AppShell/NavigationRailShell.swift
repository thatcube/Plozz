#if os(tvOS)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// The container for ``NavigationStyle/rail``: the custom navigation rail on the
/// leading edge with the selected destination filling the rest of the screen.
///
/// Two layout rules make this feel right on a TV:
/// - the content clears the **collapsed** rail, while the expanded rail overlays
///   stationary content, so opening navigation never moves or relayouts a poster
///   grid mid-scroll; and
/// - the whole rail — and its inset — goes away while a detail page is pushed, so
///   a title page is full-bleed exactly as it is under the native chrome.
///
/// `Content` is a stored value, not a `@ViewBuilder` closure: the chrome model
/// this view observes ticks on every push/pop, and storing the built content means
/// the destination is handed back unchanged rather than rebuilt from scratch on
/// each of those ticks.
struct NavigationRailShell<Content: View>: View {
    let profile: Profile
    let entries: [NavigationRailLibraryEntry]
    let showsMusic: Bool
    @Binding var selection: NavigationRailDestination
    let onOpenProfileSwitcher: () -> Void
    let chrome: NavigationChromeModel
    let content: Content

    /// Scopes appearance-time default focus so the CONTENT is focused first. Without
    /// it the rail — a stack of focusable rows sitting at the leading edge — can win
    /// the initial pick, which would open the navigation every time the app launches
    /// or the viewer switches destination.
    @Namespace private var focusScopeID
    /// Whether focus is inside the rail, reported up from it.
    @State private var railExpanded = false
    /// Bumped each time the catcher takes a Left press, so the rail claims focus.
    @State private var focusRequestToken = 0
    /// Bumped each time a Right press inside the rail resolves to nothing, so focus
    /// returns to the page.
    @State private var railReturnToken = 0

    var body: some View {
        let hidden = chrome.isChromeHidden
        return ZStack(alignment: .leading) {
            content
                // The rail makes room for itself by PUBLISHING an inset, never by
                // insetting this container.
                //
                // Insetting the container here — with padding or a safe area —
                // narrows the page as a whole, which drags the Home hero's
                // full-bleed artwork in with it and leaves a black band down the
                // side of the picture. Each surface instead applies this to its own
                // CONTENT (a row's cards, the hero's text column) and leaves its
                // artwork alone.
                .environment(
                    \.plozzNavigationContentInset,
                    hidden ? 0 : NavigationRailMetrics.contentInset
                )
                // Content is the scope's preferred focus ONLY while the rail does
                // not hold focus. Opening the rail changes its focusable subtree;
                // leaving this unconditional can re-assert content focus in the
                // same transaction and immediately close the rail again.
                .prefersDefaultFocus(!railExpanded, in: focusScopeID)


            // Left opens the navigation from anywhere, and Right leaves it from
            // anywhere — including across a grid or rail whose own focus section
            // would otherwise absorb the press. See `NavigationRailEdgeCatcher`;
            // both are fallbacks for a press that resolved to nothing, so no
            // existing behaviour in either direction changes.
            if !hidden {
                NavigationRailEdgeCatcher(
                    onOpenNavigation: { focusRequestToken &+= 1 },
                    onLeaveNavigation: { railReturnToken &+= 1 },
                    railHasFocus: railExpanded,
                    isEnabled: true
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            if !hidden {
                NavigationRailView(
                    profile: profile,
                    entries: entries,
                    showsMusic: showsMusic,
                    selection: $selection,
                    isExpandedOutward: $railExpanded,
                    onOpenProfileSwitcher: onOpenProfileSwitcher,
                    focusRequestToken: focusRequestToken,
                    focusReleaseToken: railReturnToken
                )
                // Breaks out of the title-safe area so the icons sit in the empty
                // margin down the side of the picture rather than inside the
                // page's own content column.
                .ignoresSafeArea(edges: .leading)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .focusScope(focusScopeID)
        .animation(.easeInOut(duration: 0.26), value: hidden)
        .animation(NavigationRailMetrics.expandAnimation, value: railExpanded)
        .onChange(of: selection) { _, _ in
            // The outgoing destination's stack is torn down without reporting, so
            // without this the rail would stay hidden after leaving a detail page
            // by switching destinations rather than by pressing Back.
            chrome.resetForDestinationChange()
        }
    }
}
#endif
