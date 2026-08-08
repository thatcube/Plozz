#if canImport(SwiftUI)
import CoreUI
import FeatureHomeCore

/// The Home tab's session-scoped handles: things owned **above** the tab so
/// that SwiftUI churn inside the tab tree cannot destroy them.
///
/// Both members are here for the same reason. A `TabView` re-hosts its tabs
/// when its content changes, which discards each tab's `@State` — measured on
/// device as happening on the second body pass of every launch, triggered by
/// whatever unrelated observable changed first (music availability one launch,
/// theme-music settings the next). Anything the Home tab must keep across that
/// — its view model, with a four-account load already seconds in — has to be
/// owned by a stabler view and handed down.
///
/// Grouping them also keeps `HomeTab`'s already-wide initializer from growing;
/// past a certain arity the Swift type-checker gives up on the `TabView` body
/// entirely.
struct HomeTabRuntime {
    /// Holds the Home view model across tab re-hosting, rebuilt only when
    /// ``scopeKey`` changes.
    let homeViewModel: LazyViewState<HomeViewModel>
    /// Identity of the account/profile scope the view model belongs to.
    let scopeKey: String
    /// A Top Shelf deep link awaiting routing. Carried by reference so no view
    /// in the tab tree becomes a subscriber of it.
    let pendingPlay: PendingPlayRequest
    /// The capture rig's screen requests, carried by reference for the same
    /// reason as ``pendingPlay``. Never populated outside DEBUG.
    let screenshotDirector: ScreenshotDirector
}
#endif
