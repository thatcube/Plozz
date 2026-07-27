import Observation
import SwiftUI

/// Tracks how many detail pages are currently on a navigation stack, so a page
/// can tell whether it is the one on top or has a child pushed over it.
///
/// A `NavigationStack` does **not** fire `onDisappear` on the view a push covers,
/// so a page cannot otherwise notice it has been covered. The pushed page's own
/// `onAppear`/`onDisappear` *do* fire, which makes them the reliable signal.
///
/// This matters because tvOS re-establishes focus by geometry when the stack
/// changes, landing on the topmost focusable control — the hero Play button. The
/// series page treats Play gaining focus as "the user pressed up out of the
/// episode browser" and restores the hero, which collapses the browser and hides
/// the cast with it. Verified on device: that happens as the child is *pushed*,
/// not when it is popped. Knowing a child is on top lets the page ignore focus
/// changes it did not cause, rather than trying to undo them afterwards.
@MainActor
@Observable
public final class DetailStackDepth {
    /// The number of detail pages currently on the stack.
    public private(set) var depth = 0

    public init() {}

    public func pageAppeared() {
        depth += 1
    }

    public func pageDismissed() {
        depth = max(0, depth - 1)
    }
}
