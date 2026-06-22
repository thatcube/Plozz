#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// Layout tokens local to the Home feature's full-screen sub-pages (library
/// browse, item detail). Kept in lock-step with the shared
/// `PlozzTheme.Metrics.screenPadding` so every page — Home rows, library grid,
/// and detail heroes — shares one consistent, tight horizontal inset.
enum HomeLayout {
    /// Horizontal inset for Home sub-pages. Mirrors the global screen padding so
    /// content lines up edge-to-edge with the rest of the app.
    static let horizontalPadding: CGFloat = PlozzTheme.Metrics.screenPadding
}

#endif
