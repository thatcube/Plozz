#if canImport(SwiftUI)
import SwiftUI

/// The shared Liquid Glass button treatment for hero action buttons, used by
/// both the item **detail** hero (`DetailHeroView`) and the Home **hero
/// carousel** (`HomeHeroView`) so their Play/Trailer/Info buttons match exactly.
///
/// `prominent` picks the tinted primary glass (Play) versus the lighter clear
/// glass (secondary actions like Trailer / More Info); older OS versions fall
/// back to the classic bordered styles.
struct HeroActionButtonStyle: ViewModifier {
    let prominent: Bool
    /// Icon-only buttons (watchlist / watched / refresh / "…" menu) use a circular
    /// glass shape instead of the default capsule, so a single-glyph button reads
    /// as a round chip rather than a stubby pill. Labelled buttons (Play, Trailer)
    /// keep the capsule.
    var circular: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        // On tvOS, focus — not fill — determines the primary button, so we never
        // use the prominent (white/tinted) glass here; every hero button uses the
        // same clear glass and the focus engine highlights the active one. iOS /
        // iPadOS keep a real filled primary via `PlozziOSHeroActionButtonStyle`,
        // because those platforms can't focus a button.
        if #available(tvOS 26.0, *) {
            shaped(content.buttonStyle(.glass))
        } else {
            shaped(content.buttonStyle(.bordered))
        }
    }

    @ViewBuilder
    private func shaped(_ content: some View) -> some View {
        if circular {
            content.buttonBorderShape(.circle)
        } else {
            content
        }
    }
}
#endif
