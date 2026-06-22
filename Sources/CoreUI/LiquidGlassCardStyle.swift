#if canImport(SwiftUI)
import SwiftUI

/// Liquid-glass card surface for browsing tiles, ported from the Twozz "Browse"
/// styling so Plozz's library grid matches it. Uses native Liquid Glass on
/// tvOS 26+ and a lightweight translucent fallback on older versions.
///
/// On focus the surface picks up a **subtle translucent tint** (matching Twozz's
/// focus treatment) — unless the system **Reduce Transparency** accessibility
/// setting is on, in which case it switches to a **solid/opaque** focus fill so
/// the lift stays legible without relying on translucency.
public struct PlozzGlassCardModifier: ViewModifier {
    private let cornerRadius: CGFloat
    private let isFocused: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.themePalette) private var palette

    public init(cornerRadius: CGFloat, isFocused: Bool) {
        self.cornerRadius = cornerRadius
        self.isFocused = isFocused
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if reduceTransparency {
            // Reduce Transparency on: never lean on translucency. Paint a solid
            // surface that turns a touch lighter/opaque on focus.
            content
                .background {
                    shape.fill(isFocused ? Color.plozzOpaqueCardFocused : Color.plozzOpaqueCard)
                }
                .overlay {
                    shape.strokeBorder(
                        isFocused ? Color.primary.opacity(0.35) : Color.primary.opacity(0.12),
                        lineWidth: 1
                    )
                }
                .clipShape(shape)
        } else {
            // Subtle, theme-tinted translucent surface (matches Twozz). The card
            // picks up a faint wash of the active theme's own card colour — never
            // a stark frosted-white panel — and deepens with a whisper of the
            // brand accent on focus. Colours come from the resolved palette, so
            // the tint tracks whichever theme (dark / OLED / light) is selected.
            content
                .background {
                    shape.fill(palette.cardSurface.opacity(isFocused ? 0.85 : 0.5))
                }
                .overlay {
                    shape.fill(palette.accent.opacity(isFocused ? 0.12 : 0))
                }
                .overlay {
                    shape.strokeBorder(
                        palette.cardBorder.opacity(isFocused ? 1.0 : 0.55),
                        lineWidth: 1
                    )
                }
                .clipShape(shape)
        }
    }
}

private extension Color {
    /// Solid card fill used when Reduce Transparency is on (resting state).
    static let plozzOpaqueCard = Color(white: 0.16)
    /// Solid card fill used when Reduce Transparency is on and the card is
    /// focused — a clearly lighter, fully opaque surface.
    static let plozzOpaqueCardFocused = Color(white: 0.26)
}

public extension View {
    /// Wraps the view in the shared Plozz liquid-glass browsing-card surface.
    func plozzGlassCard(cornerRadius: CGFloat, isFocused: Bool) -> some View {
        modifier(PlozzGlassCardModifier(cornerRadius: cornerRadius, isFocused: isFocused))
    }
}

#endif
