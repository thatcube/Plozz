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

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}
#endif
