#if canImport(SwiftUI)
import SwiftUI

/// How far the page's content has been pushed in from the leading edge to make
/// room for the custom navigation rail, in points. `0` under the two native tab
/// styles, which draw their own chrome and need no inset.
///
/// ### Why this exists
/// The rail insets **content** — a hero's title/overview/buttons, a row header,
/// a poster grid — because those must never sit under the navigation. It must NOT
/// inset **full-bleed artwork**: a hero backdrop is meant to run to the physical
/// screen edge, and letting the inset narrow it leaves a dead band down the side
/// of the picture.
///
/// SwiftUI's usual tool for that split is `safeAreaPadding` plus `ignoresSafeArea`,
/// which does not work here. The page is a `NavigationStack` that manages its own
/// safe area, so a safe-area inset applied by the shell never reaches the surfaces
/// inside it — changing the amount moved nothing at all. Publishing the number and
/// letting each surface apply REAL padding to its own content is what actually
/// works, and it keeps artwork out of it by construction.
private struct PlozzNavigationContentInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    /// The leading inset the navigation chrome has applied to page content.
    var plozzNavigationContentInset: CGFloat {
        get { self[PlozzNavigationContentInsetKey.self] }
        set { self[PlozzNavigationContentInsetKey.self] = newValue }
    }
}

#endif
