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

    /// Wraps the view in a non-interactive Liquid Glass *panel* surface (HUDs,
    /// overlays). Uses native Liquid Glass on tvOS 26+ and a translucent material
    /// fallback on older versions, with a faint theme-aware scrim behind it for
    /// legibility over bright video. Respects Reduce Transparency.
    func plozzGlassPanel(cornerRadius: CGFloat, scrimOpacity: Double = 0.1) -> some View {
        modifier(PlozzGlassPanelModifier(cornerRadius: cornerRadius, scrimOpacity: scrimOpacity))
    }
}

/// Liquid Glass surface for read-only overlay panels (e.g. the playback
/// diagnostics HUD). Distinct from `PlozzGlassCardModifier`, which is tuned for
/// focusable browsing tiles.
public struct PlozzGlassPanelModifier: ViewModifier {
    private let cornerRadius: CGFloat
    private let scrimOpacity: Double

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    public init(cornerRadius: CGFloat, scrimOpacity: Double = 0.1) {
        self.cornerRadius = cornerRadius
        self.scrimOpacity = scrimOpacity
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Theme-aware scrim: black behind dark/OLED, white behind light, so the
        // panel keeps text legible over any frame while still tracking the theme.
        let scrim = (colorScheme == .dark ? Color.black : Color.white).opacity(scrimOpacity)

        content
            .background { shape.fill(scrim) }
            .modifier(GlassSurface(shape: shape, reduceTransparency: reduceTransparency, palette: palette))
            .overlay { shape.strokeBorder(palette.cardBorder.opacity(0.6), lineWidth: 1) }
            .clipShape(shape)
    }
}

/// Picks the best available translucent backing for a panel: native Liquid
/// Glass on tvOS 26+, `.ultraThinMaterial` below that, and a solid theme fill
/// when Reduce Transparency is on.
private struct GlassSurface: ViewModifier {
    let shape: RoundedRectangle
    let reduceTransparency: Bool
    let palette: ThemePalette

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background { shape.fill(palette.cardSurface) }
        } else if #available(tvOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

#endif
