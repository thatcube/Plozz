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
    private let glassAtRest: Bool

    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.themePalette) private var palette

    public init(cornerRadius: CGFloat, isFocused: Bool, glassAtRest: Bool = true) {
        self.cornerRadius = cornerRadius
        self.isFocused = isFocused
        self.glassAtRest = glassAtRest
    }

    /// tvOS 27 hangs the **main thread** (not a crash — animations keep running,
    /// but focus freezes and never recovers) when `.glassEffect` is applied
    /// *directly to card content that contains an async image + text* and that
    /// card gains focus: SwiftUI's layout goes into an infinite update loop.
    ///
    /// The fix is structural, not a fallback: draw the Liquid Glass as a
    /// **background underlay** on a `Color.clear` layer with the real content on
    /// top, instead of wrapping `.glassEffect` around the content. The borderless
    /// focus halo has always drawn glass this way (`Color.clear.glassEffect`) and
    /// never hangs on the same OS — proof the underlay structure is safe. So every
    /// glass card now matches it, on both tvOS 26 and 27.
    @available(iOS 26.0, tvOS 26.0, *)
    @ViewBuilder
    private func glassUnderlay() -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Color.clear
            .glassEffect(
                isFocused ? .regular.tint(palette.focusedCardGlassTint) : .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
            .background {
                // Light mode + focus: opaque backing so the focus drop shadow can't
                // bleed *through* the glass and read as a muddy haze inside the card.
                if isFocused && palette.isLight { shape.fill(palette.cardOpaqueSurface) }
            }
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
        } else if #available(iOS 26.0, tvOS 26.0, *) {
            // Glass drawn as a BACKGROUND underlay (see `glassUnderlay`), NOT
            // wrapped around the content — the latter hangs on tvOS 27 focus.
            //
            // Focus → real refractive Liquid Glass (one card at a time, tinted).
            // At rest → the cheaper frosted `.ultraThinMaterial`: it gives a glassy
            // surface without a live `.glassEffect`'s per-frame backdrop sampling,
            // so a dense resting grid stays lag-free while still reading as glass.
            // `glassAtRest: false` opts a card out of even the frosted rest surface
            // (bare artwork at rest) for the very densest grids.
            content
                .background {
                    if isFocused {
                        glassUnderlay()
                    } else if glassAtRest {
                        shape.fill(.ultraThinMaterial)
                    }
                }
                // A hairline edge so a resting card reads on any theme: the frosted
                // `.ultraThinMaterial` is translucent, so on a dark and Pure Black page it
                // darkens to near-invisible and the card loses its edge. The
                // theme-aware `cardOpaqueBorder` (light on dark and Pure Black, dark on light)
                // defines that edge; drawn only at rest, since the focused glass
                // brings its own tint + shadow. Skipped for `glassAtRest: false`.
                .overlay {
                    if !isFocused && glassAtRest {
                        // Soften the edge on dark and Pure Black — the light hairline reads
                        // stronger against a near-black page than the same value does
                        // on a light one, so trim it there while leaving Light as-is.
                        shape.strokeBorder(
                            palette.cardOpaqueBorder.opacity(palette.isLight ? 1 : 0.55),
                            lineWidth: 1
                        )
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
    /// Pass `glassAtRest: false` for cards shown en masse (dense poster grids) so
    /// resting cards skip the per-frame backdrop blur a live `.glassEffect` costs —
    /// the focused card still gets full glass. Defaults to `true` so every existing
    /// caller keeps its resting glass.
    func plozzGlassCard(cornerRadius: CGFloat, isFocused: Bool, glassAtRest: Bool = true) -> some View {
        modifier(PlozzGlassCardModifier(cornerRadius: cornerRadius, isFocused: isFocused, glassAtRest: glassAtRest))
    }

    /// Makes a read-only card reachable on tvOS and gives it the same Liquid
    /// Glass lift used by detail metadata. Reduce Transparency automatically
    /// switches the surface to the opaque fallback in `PlozzGlassCardModifier`.
    func plozzFocusableCard(
        cornerRadius: CGFloat,
        variant: PlozzFocusableCardVariant = .filled
    ) -> some View {
        modifier(PlozzFocusableCardModifier(cornerRadius: cornerRadius, variant: variant))
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
        cornerRadius: CGFloat = PlozzTheme.Metrics.Radius.card,
        focusedScale: CGFloat = PlozzTheme.Metrics.mediumFocusedCardScale
    ) -> some View {
        buttonStyle(PlozzCardButtonStyle(cornerRadius: cornerRadius, focusedScale: focusedScale))
            .focusEffectDisabled()
    }

    /// Flattens a card's layer tree to reduce GPU offscreen render passes.
    /// When Reduce Transparency is ON (opaque cards, no live glass), uses
    /// `.drawingGroup()` to rasterize the entire card into one Metal texture —
    /// collapsing clips, overlays, and borders into a single pass.
    ///
    /// When Liquid Glass is active it does **nothing**. Live glass has to sample
    /// the *real* backdrop, so it can't be isolated into an offscreen group:
    /// wrapping a focusable glass card in `.compositingGroup()` (or
    /// `.drawingGroup()`) makes the render server hard-crash the instant the card
    /// gains its focus glass. This is the state cards rendered in before the
    /// rasterize was added — when "glass on every card" worked.
    @ViewBuilder
    func plozzCardRasterize(reduceTransparency: Bool) -> some View {
        if reduceTransparency {
            self.drawingGroup()
        } else {
            self
        }
    }

    /// Wraps the view in a non-interactive Liquid Glass *panel* surface (HUDs,
    /// overlays). Uses native Liquid Glass on tvOS 26+ and a translucent material
    /// fallback on older versions, with a faint theme-aware scrim behind it for
    /// legibility over bright video. Respects Reduce Transparency.
    func plozzGlassPanel(cornerRadius: CGFloat, scrimOpacity: Double = 0.1, refractEdgesOnly: Bool = false) -> some View {
        modifier(PlozzGlassPanelModifier(cornerRadius: cornerRadius, scrimOpacity: scrimOpacity, refractEdgesOnly: refractEdgesOnly))
    }
}

public enum PlozzFocusableCardVariant: Sendable {
    case filled
    case borderless(focusPadding: CGFloat = 18)
}

public struct PlozzFocusableCardModifier: ViewModifier {
    private let cornerRadius: CGFloat
    private let variant: PlozzFocusableCardVariant
    @FocusState private var focused: Bool
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    public init(
        cornerRadius: CGFloat,
        variant: PlozzFocusableCardVariant = .filled
    ) {
        self.cornerRadius = cornerRadius
        self.variant = variant
    }

    public func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .background { surface }
            .focusable(true)
            .focused($focused)
            .focusEffectDisabled()
            .zIndex(focused ? 1 : 0)
            .animation(.easeOut(duration: 0.18), value: focused)
        #else
        content.background { surface }
        #endif
    }

    @ViewBuilder
    private var surface: some View {
        let focusPadding = switch variant {
        case .filled: CGFloat.zero
        case .borderless(let padding): padding
        }
        let surfaceCorner = cornerRadius
        let shape = RoundedRectangle(cornerRadius: surfaceCorner, style: .continuous)

        if focused {
            if reduceTransparency {
                // Reduce Transparency: the glass path falls back to a solid WHITE
                // lift, which whites-out a text card (light content text becomes
                // illegible). For these content cards, keep the card's own raised
                // surface on focus and indicate focus with a bright ring + shadow
                // instead — so contrast never inverts and text stays readable.
                shape
                    .fill(palette.raised.fill)
                    .overlay {
                        shape.strokeBorder(palette.primaryText.opacity(0.9), lineWidth: 4)
                    }
                    .padding(-focusPadding)
                    .shadow(color: .black.opacity(0.30), radius: 14, y: 7)
            } else {
                Color.clear
                    .plozzGlassCard(cornerRadius: surfaceCorner, isFocused: true)
                    .padding(-focusPadding)
                    .shadow(color: .black.opacity(0.30), radius: 18, y: 9)
            }
        } else if case .filled = variant {
            // Standardized raised surface from the shared elevation table — matches
            // settings groups everywhere. Dark lifts lighter (borderless), OLED
            // stays black with a hairline, Light is white with a soft shadow.
            let style = palette.raised
            shape
                .fill(style.fill)
                .overlay {
                    if let border = style.border {
                        shape.strokeBorder(border, lineWidth: style.borderWidth)
                    }
                }
                .modifier(OptionalSurfaceShadow(shadow: style.shadow))
        }
    }
}

/// Liquid Glass surface for read-only overlay panels (e.g. the playback
/// diagnostics HUD). Distinct from `PlozzGlassCardModifier`, which is tuned for
/// focusable browsing tiles.
public struct PlozzGlassPanelModifier: ViewModifier {
    private let cornerRadius: CGFloat
    private let scrimOpacity: Double
    private let refractEdgesOnly: Bool

    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    public init(cornerRadius: CGFloat, scrimOpacity: Double = 0.1, refractEdgesOnly: Bool = false) {
        self.cornerRadius = cornerRadius
        self.scrimOpacity = scrimOpacity
        self.refractEdgesOnly = refractEdgesOnly
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Theme-aware scrim: black behind dark and Pure Black, white behind light, so the
        // panel keeps text legible over any frame while still tracking the theme.
        let scrim = (colorScheme == .dark ? Color.black : Color.white).opacity(scrimOpacity)

        // Refract-edges-only: skip the full-panel blur (which samples live video
        // every frame and stutters playback) and instead pass the video through a
        // faint scrim while faking glass with a bright refractive rim. Matches
        // Infuse's info HUD: crisp video behind, lit edges, zero compositor cost.
        if refractEdgesOnly {
            content
                .background { shape.fill(scrim) }
                .modifier(RefractiveRimGlass(cornerRadius: cornerRadius, palette: palette))
                .clipShape(shape)
        } else {
            content
                .background { shape.fill(scrim) }
                .modifier(GlassSurface(shape: shape, reduceTransparency: reduceTransparency, palette: palette))
                .overlay { shape.strokeBorder(palette.cardBorder.opacity(0.6), lineWidth: 1) }
                .clipShape(shape)
        }
    }
}

/// True edge refraction with minimal cost: confine real Liquid Glass to a thin
/// rim band (genuine backdrop refraction at the edges) while the center stays
/// crisp — the full-panel blur is what stutters, so masking glass to the border
/// keeps the look at a fraction of the sample cost. Falls back to a lit gradient
/// rim below tvOS 26 / under Reduce Transparency, where no backdrop sampling
/// happens at all.
private struct RefractiveRimGlass: ViewModifier {
    let cornerRadius: CGFloat
    let palette: ThemePalette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Zero backdrop sampling: native glass over moving video forces a per-frame
        // capture pass (stutters even masked to a rim), so fake the refracted edge
        // with a lit gradient stroke — crisp video, no compositor cost.
        content.overlay { shape.strokeBorder(fauxRim, lineWidth: 1.5) }
    }

    /// Top-lit → dark-bottom gradient stroke that reads as a refracted edge with
    /// zero backdrop sampling (legacy / reduce-transparency path).
    private var fauxRim: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(0.55), palette.cardBorder.opacity(0.35), .white.opacity(0.15)],
            startPoint: .top,
            endPoint: .bottom
        )
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
        } else if #available(iOS 26.0, tvOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

#endif
