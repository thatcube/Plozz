#if canImport(SwiftUI)
import SwiftUI
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// Shared geometry for the Home **hero** so the real hero (`HomeHeroView`), the
/// Home layout that pulls the rows up under it (`HomeView`), and the loading
/// **skeleton** (`HomeSkeletonView`) all read from ONE source of truth. Without
/// this, the skeleton's placeholder positions and the Continue-Watching "peek"
/// would silently drift out of alignment with the loaded hero whenever a value is
/// tuned in one place but not the others.
enum HomeHeroLayout {
    /// Full-screen hero height — the backdrop fills the display top-to-bottom.
    static var screenHeight: CGFloat {
        #if canImport(UIKit)
        UIScreen.main.bounds.height
        #else
        1080
        #endif
    }

    /// Full-screen hero width.
    static var screenWidth: CGFloat {
        #if canImport(UIKit)
        UIScreen.main.bounds.width
        #else
        1920
        #endif
    }

    /// Distance the hero content column (logo / metadata / overview / buttons /
    /// dots) is lifted off the bottom edge of the full-screen hero, so it sits in
    /// the lower third — paired with ``rowOverlap`` to land Continue Watching just
    /// beneath the paging dots.
    static let contentBottomInset: CGFloat = 222

    /// Vertical spacing between the hero content column's stacked elements.
    static let contentColumnSpacing: CGFloat = 12

    /// How far the rows are pulled up so the first row (Continue Watching) peeks in
    /// just below the hero's paging dots — the Apple TV look.
    static let rowOverlap: CGFloat = 132

    /// Leading inset for the hero content column (matches the rows' screen inset).
    static var contentLeadingPadding: CGFloat { PlozzTheme.Metrics.heroLeadingPadding }
}

/// The one box every tvOS hero wordmark is fitted into — shared by Home (both the
/// UIKit and SwiftUI renderers) and the detail page.
///
/// Home and the detail page have different text columns, 496pt and 620pt, and each
/// hero used to size its logo against its own. A wide wordmark was therefore drawn
/// at 496pt on Home and 620pt on the detail page: the same show, a quarter larger
/// on one screen than the other, for no reason a viewer could see. A logo is the
/// show's identity rather than a member of the column beneath it, so it is sized
/// once here and drawn identically wherever it appears.
///
/// Held to the **narrower** of the two columns. Taking the detail page's 620pt
/// instead would push Home's wordmark a quarter past the 496pt column its own
/// metadata and description are capped to — the exact overhang that cap exists to
/// prevent — whereas holding the detail page to 496pt overruns nothing.
enum HeroLogoLayout {
    /// Nominal budget: Home's text column, and a wordmark height to match.
    static let budget = CGSize(width: 496, height: 160)

    /// The nominal box handed to `HeroLogoArtwork` / `HeroLogoFit.fittedSize`.
    ///
    /// Pinned, not raw: `HeroLogoFit` reads its box as a budget and lets a wide
    /// shape flex a quarter past it, so passing the column straight through would
    /// draw the logo wider than the column it is being held to. The width the pin
    /// takes is returned as height, so no logo shrinks for being pinned — see
    /// ``HeroLogoFit/pinnedBox(budget:drawnWidth:maxHeight:)``.
    static let box: CGSize = HeroLogoFit.pinnedBox(
        budget: budget,
        drawnWidth: budget.width
    )

    /// The same box resolved against a column that may be narrower than the budget
    /// (a smaller screen, or a hero inset further than usual). Returns ``box``
    /// unchanged at the normal width.
    static func box(fitting availableWidth: CGFloat) -> CGSize {
        let column = min(availableWidth, budget.width)
        guard column < budget.width else { return box }
        return HeroLogoFit.pinnedBox(
            budget: CGSize(width: column, height: budget.height),
            drawnWidth: column
        )
    }
}

#endif
