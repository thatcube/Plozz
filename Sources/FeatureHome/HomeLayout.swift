#if canImport(SwiftUI)
import SwiftUI

/// Layout tokens local to the Home feature's full-screen sub-pages (library
/// browse, item detail). These intentionally use a tighter horizontal inset than
/// the shared `PlozzTheme.Metrics.screenPadding` so browse/detail content reaches
/// closer to the screen edges.
enum HomeLayout {
    /// Horizontal inset for Home sub-pages — smaller than the global screen
    /// padding so dense grids and detail heroes use more of the screen width.
    static let horizontalPadding: CGFloat = 36
}

#endif
