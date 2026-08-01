#if canImport(SwiftUI)
import SwiftUI

/// Effective "reduce transparency" for Plozz's liquid-glass surfaces.
///
/// SwiftUI's `\.accessibilityReduceTransparency` is read-only, so the app can't
/// override it to honour an in-app preference. This writable key carries the
/// **effective** value — the OS Accessibility setting OR the in-app
/// Settings ▸ Appearance "Reduce transparency" toggle — injected once at the app
/// root (`RootView`). Every glass card/panel/control reads this instead of the
/// system key so the toggle (and the OS setting) both switch them to solid
/// surfaces. Defaults to `false` outside the root (e.g. SwiftUI previews); the
/// real UI tree always receives the root's injected value.
private struct PlozzReduceTransparencyKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

/// As `PlozzReduceTransparencyKey`, plus performance.
private struct PlozzReducePanelGlassKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

/// Whether the display is currently being driven in HDR.
private struct PlozzHDRDisplayActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    var plozzReduceTransparency: Bool {
        get { self[PlozzReduceTransparencyKey.self] }
        set { self[PlozzReduceTransparencyKey.self] = newValue }
    }

    /// Reduce transparency for LARGE surfaces only — panels, cards, anything
    /// with a broad backdrop sample drawn over live video.
    ///
    /// Everything above, OR the device and the content being unable to afford
    /// glass. The split exists because the cost of this material is
    /// proportional to the area behind it: a panel spanning the screen
    /// resamples the whole frame, while a capsule button samples a sliver, and
    /// giving up both to protect the frame rate costs the interface far more
    /// than it saves.
    ///
    /// Accessibility is deliberately NOT split this way — a viewer who cannot
    /// read text over glass cannot read it on a button either, so
    /// `plozzReduceTransparency` still applies everywhere and this is only ever
    /// wider than it, never narrower.
    var plozzReducePanelGlass: Bool {
        get { self[PlozzReducePanelGlassKey.self] }
        set { self[PlozzReducePanelGlassKey.self] = newValue }
    }

    /// Whether the display is currently in HDR mode, so interface elements can
    /// compensate for SDR white being mapped brighter than it is in SDR mode.
    var plozzHDRDisplayActive: Bool {
        get { self[PlozzHDRDisplayActiveKey.self] }
        set { self[PlozzHDRDisplayActiveKey.self] = newValue }
    }
}

public extension View {
    /// The translucent surface used in place of Liquid Glass over demanding
    /// video.
    ///
    /// A plain translucent colour, NOT a `Material`. Two reasons, and both were
    /// learned the hard way here:
    ///
    /// A Material is a live backdrop blur, so on the frame it is inserted it has
    /// no sample yet — it draws its own flat base colour and repaints once the
    /// sample arrives. That is a panel that appears one colour and then becomes
    /// another, on every open, and no amount of transition tuning hides it
    /// because it is not the transition. Layering something opaque underneath
    /// removes the pop only by removing the translucency as well.
    ///
    /// And in a path whose entire purpose is to stop paying for a per-frame
    /// backdrop sample, a Material is still paying for one. A translucent fill
    /// costs nothing, cannot pop, and is genuinely see-through — which is what
    /// this is supposed to look like.
    func plozzFrostedBackground<S: InsettableShape>(
        _ shape: S,
        raised: Bool = false
    ) -> some View {
        background {
            shape.fill(raised ? PlozzFrostedSurface.raised : PlozzFrostedSurface.base)
        }
    }

    /// The shared hairline edge for a frosted surface, compensated for HDR.
    ///
    /// A modifier rather than six hand-written overlays, which is how the widths
    /// drifted apart in the first place — and the only way the HDR compensation
    /// can reach all of them, since a `ShapeStyle` cannot read the environment.
    func plozzFrostedBorder<S: InsettableShape>(_ shape: S, visible: Bool = true) -> some View {
        modifier(PlozzFrostedBorderModifier(shape: shape, visible: visible))
    }
}

private struct PlozzFrostedBorderModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let visible: Bool

    @Environment(\.plozzHDRDisplayActive) private var hdrDisplayActive

    func body(content: Content) -> some View {
        content.overlay(
            shape.strokeBorder(
                visible
                    ? PlozzFrostedSurface.borderColor(hdrDisplayActive: hdrDisplayActive)
                    : .clear,
                lineWidth: PlozzFrostedSurface.borderWidth
            )
        )
    }
}

/// The surface that stands in for Liquid Glass when the frame rate matters more
/// than the material does.
///
/// ONE definition, referenced by every surface that can give up glass, because
/// the alternative was measured by eye and rejected: a panel that fell back to a
/// frosted material while the buttons on it kept refracting made the two read as
/// different materials sharing a screen, which looks more broken than either
/// choice does on its own.
///
/// Deliberately still translucent. The point is to stop paying for a live
/// per-frame backdrop sample, NOT to stop being a surface — a flat black wash
/// costs nothing and looks like a rectangle laid over the video.
public enum PlozzFrostedSurface {
    /// For anything at rest: panels, cards, unfocused controls.
    ///
    /// A dark GREY rather than black, and deliberately so. Pure black at any
    /// opacity only ever subtracts light, so the panel reads as a hole punched
    /// in the picture; lifting the fill off black gives it a surface of its own
    /// that happens to be see-through, which is what glass looks like.
    public static let base = Color(white: 0.10).opacity(0.85)
    /// For a focused or selected control, which sits a step brighter than what
    /// surrounds it — the same relationship glass gets from its white tint.
    public static let raised = Color(white: 0.24).opacity(0.8)

    public static let borderWidth: CGFloat = 1

    /// The edge, compensated for the display being in HDR mode.
    ///
    /// tvOS switches the panel into HDR for Dolby Vision, and the interface is
    /// composited into that signal — so SDR white maps to a higher output level
    /// than the same value reaches in SDR mode, and a hairline tuned against a
    /// still backdrop reads as a bright line across someone's film.
    public static func borderColor(hdrDisplayActive: Bool) -> Color {
        Color.white.opacity(hdrDisplayActive ? 0.10 : 0.16)
    }

    /// For call sites with no way to know — previews and anything outside the
    /// player. Assumes SDR, the safer error.
    public static let borderColor = Color.white.opacity(0.16)

    public static let dividerColor = borderColor
    public static func dividerColor(hdrDisplayActive: Bool) -> Color {
        borderColor(hdrDisplayActive: hdrDisplayActive)
    }
    public static let dividerHeight: CGFloat = borderWidth
}

#endif
