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

    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.themePalette) private var palette

    public init(cornerRadius: CGFloat, isFocused: Bool) {
        self.cornerRadius = cornerRadius
        self.isFocused = isFocused
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if reduceTransparency {
            // Reduce Transparency on: never lean on translucency. Paint an opaque
            // surface — a strong white "lift" on focus, the theme's card colour at
            // rest — exactly like Twozz's glass-disabled card path.
            content
                .background {
                    shape.fill(isFocused ? palette.liftSurface : palette.cardOpaqueSurface)
                }
                .overlay {
                    shape.strokeBorder(
                        isFocused ? Color.clear : palette.cardOpaqueBorder,
                        lineWidth: 1
                    )
                }
                .clipShape(shape)
        } else if #available(tvOS 26.0, *) {
            // Native Liquid Glass, matching Twozz 1:1: focus picks up a faint
            // theme-aware tint (dark/OLED brighten, light darkens) blended into
            // the live glass, never a flat opacity fill.
            content
                .glassEffect(
                    isFocused ? .regular.tint(palette.focusedCardGlassTint) : .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
                .background {
                    // A focused card casts a drop shadow. In Light mode the
                    // translucent glass lets that shadow bleed *through*, reading
                    // as a muddy haze inside the card. Give the focused Light card
                    // an opaque backing so the shadow stays behind it. Dark/OLED
                    // don't show this, so they keep pure translucent glass.
                    if isFocused && palette.isLight {
                        shape.fill(palette.cardOpaqueSurface)
                    }
                }
                .clipShape(shape)
        } else {
            // Pre-Liquid-Glass fallback: opaque lift on focus, light translucent
            // wash at rest.
            content
                .background {
                    shape.fill(isFocused ? palette.liftSurface : Color.primary.opacity(0.07))
                }
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                }
                .clipShape(shape)
        }
    }
}

/// Hairline frosted-glass rim drawn around a clipped media thumbnail, ported
/// from Twozz's `mediaEdgeColor` overlay. Gives every card's artwork the same
/// inner glass edge and covers the sub-pixel bleed a clipped image/video plane
/// can show past rounded corners.
public struct PlozzMediaEdgeModifier: ViewModifier {
    private let cornerRadius: CGFloat
    @Environment(\.themePalette) private var palette

    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .inset(by: -0.5)
                .stroke(palette.mediaEdgeColor, lineWidth: 1.5)
        }
    }
}

/// tvOS button style for focusable browsing **cards** (Home's library
/// shortcuts, Music tiles, genre/category cards). Replaces the platform's
/// default `.card` style — whose focus state paints a stark **white** plate —
/// with Plozz's Twozz-ported liquid-glass focus surface: a subtle, theme-tinted
/// lift that deepens on focus, draws a hairline border, and respects Reduce
/// Transparency. Drive it through `.plozzCardButton(cornerRadius:)`, which also
/// disables the system focus effect so no white halo bleeds through.
public struct PlozzCardButtonStyle: ButtonStyle {
    private let cornerRadius: CGFloat
    private let focusedScale: CGFloat

    public init(cornerRadius: CGFloat, focusedScale: CGFloat = PlozzTheme.Metrics.mediumFocusedCardScale) {
        self.cornerRadius = cornerRadius
        self.focusedScale = focusedScale
    }

    public func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, cornerRadius: cornerRadius, focusedScale: focusedScale)
    }

    private struct CardBody: View {
        let configuration: ButtonStyle.Configuration
        let cornerRadius: CGFloat
        let focusedScale: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .plozzGlassCard(cornerRadius: cornerRadius, isFocused: isFocused)
                .shadow(color: .black.opacity(isFocused ? 0.36 : 0), radius: 20, y: 10)
                .scaleEffect(isFocused ? (configuration.isPressed ? focusedScale * 0.97 : focusedScale) : 1)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

public extension View {
    /// Wraps the view in the shared Plozz liquid-glass browsing-card surface.
    func plozzGlassCard(cornerRadius: CGFloat, isFocused: Bool) -> some View {
        modifier(PlozzGlassCardModifier(cornerRadius: cornerRadius, isFocused: isFocused))
    }

    /// Draws Twozz's hairline "inner glass" rim around a clipped media thumbnail:
    /// a 1.5pt frosted-glass stroke (the theme's `mediaEdgeColor`) inset half a
    /// point outside the artwork's rounded rect. Apply it **after** the artwork's
    /// `.clipShape`, passing the same corner radius, so every card shares the same
    /// clean edge and the stroke covers any sub-pixel bleed past the corners.
    func plozzMediaEdge(cornerRadius: CGFloat) -> some View {
        modifier(PlozzMediaEdgeModifier(cornerRadius: cornerRadius))
    }

    /// Styles a `Button` as a Plozz browsing card: the Twozz-ported liquid-glass
    /// focus surface in place of tvOS's white `.card` focus plate, with the
    /// system focus effect disabled so no white halo remains.
    func plozzCardButton(
        cornerRadius: CGFloat = PlozzTheme.Metrics.cornerRadius,
        focusedScale: CGFloat = PlozzTheme.Metrics.mediumFocusedCardScale
    ) -> some View {
        buttonStyle(PlozzCardButtonStyle(cornerRadius: cornerRadius, focusedScale: focusedScale))
            .focusEffectDisabled()
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

    @Environment(\.plozzReduceTransparency) private var reduceTransparency
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
