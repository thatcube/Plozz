#if canImport(SwiftUI)
import SwiftUI
import Observation

/// Tracks how deep the on-screen destination's navigation stack is, so the custom
/// navigation rail can step aside the moment a title page opens.
///
/// A tiny observable rather than a binding threaded through every destination:
/// the stacks that know their own depth (`HomeTab`, `SearchTab`) are several
/// layers below the shell that draws the chrome, and only the chrome reads this —
/// so a push invalidates the rail and nothing else.
///
/// Absent (`nil` in the environment) under the two native tab styles, which draw
/// their own chrome and manage its visibility themselves — so every reporting call
/// site is a no-op there.
///
/// Lives in `CoreUI` rather than beside the rail in `AppShell` because the stacks
/// that know their own depth are spread across feature modules (`FeatureMusic`,
/// `FeatureSettings`), and a Feature cannot import the shell.
@MainActor
@Observable
public final class NavigationChromeModel {
    /// Number of pages pushed on top of the current destination's root.
    public private(set) var stackDepth = 0

    /// Whether the rail should be off screen. A pushed page is a *detail* page —
    /// a title, a person, an episode list — and those are full-bleed by design.
    public var isChromeHidden: Bool { stackDepth > 0 }

    public init() {}

    public func setStackDepth(_ depth: Int) {
        guard stackDepth != depth else { return }
        stackDepth = depth
    }

    /// Called when the shell swaps destinations: the outgoing stack is torn down
    /// without reporting, so the rail would otherwise stay hidden.
    public func resetForDestinationChange() {
        setStackDepth(0)
    }
}

public extension View {
    /// Reports this navigation stack's depth to the shell's chrome model, so the
    /// rail hides while a detail page is on top. A no-op under the native tab
    /// styles, which don't install a chrome model.
    func reportsNavigationDepth(_ depth: Int, to chrome: NavigationChromeModel?) -> some View {
        onChange(of: depth, initial: true) { _, newDepth in
            chrome?.setStackDepth(newDepth)
        }
    }
}
#endif
