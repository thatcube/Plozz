#if os(tvOS)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// The container for ``NavigationStyle/rail``: the custom navigation rail on the
/// leading edge with the selected destination filling the rest of the screen.
///
/// Two layout rules make this feel right on a TV:
/// - the content is inset by the **collapsed** rail width and the rail *overlays*
///   the page when it expands, so opening the navigation never relayouts a poster
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

    /// How far the page slides right while the rail is expanded.
    ///
    /// The page MOVES rather than being covered. Covering it meant the expanded
    /// rail needed an opaque panel to stay readable — which read as a slab bolted
    /// over the picture — and, worse, it occluded the very cards a Right press
    /// needs to land on, so leaving the rail could fail. Sliding solves both.
    private var pageShift: CGFloat {
        NavigationRailMetrics.expandedWidth - NavigationRailMetrics.collapsedWidth
    }

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
                .offset(x: railExpanded && !hidden ? pageShift : 0)
                .prefersDefaultFocus(true, in: focusScopeID)

            if !hidden {
                NavigationRailView(
                    profile: profile,
                    entries: entries,
                    showsMusic: showsMusic,
                    selection: $selection,
                    isExpandedOutward: $railExpanded,
                    onOpenProfileSwitcher: onOpenProfileSwitcher
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
