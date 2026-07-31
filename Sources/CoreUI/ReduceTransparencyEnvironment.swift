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
    public static let base: Material = .thickMaterial
    /// For a focused or selected control, which wants to sit a step brighter
    /// than what surrounds it — the same relationship the glass version gets
    /// from its white tint.
    public static let raised: Material = .regularMaterial

    /// A hairline light edge, so a frosted surface still has a boundary over
    /// footage dark enough that the frost alone leaves none.
    ///
    /// ONE width and ONE colour for every frosted surface, and always drawn with
    /// `strokeBorder` rather than `stroke`. Both halves of that matter: `stroke`
    /// centres the line on the shape's path so half of it falls outside, which
    /// makes a 1pt `stroke` and a 1pt `strokeBorder` visibly different weights —
    /// that mismatch, plus a genuine 1pt-versus-2pt difference, is why the
    /// buttons read as heavier than the panels they sat on.
    ///
    /// The value is the player panel's, which was already tuned against live
    /// video, rather than the UIKit hero's 2pt: the hero's pills sit over a
    /// still backdrop where a heavier edge reads as deliberate, and the same
    /// weight around a small control over moving footage reads as an outline.
    /// Nudged from 0.14 to 0.16 because frost is lighter than glass, so an edge
    /// that registered against glass has less to work with here.
    public static let borderWidth: CGFloat = 1

    /// The edge, compensated for the display being in HDR mode.
    ///
    /// tvOS switches the panel into HDR for Dolby Vision and HDR playback, and
    /// the interface is composited into that signal — so SDR white is mapped to
    /// a higher output level than the same value reaches in SDR mode. A hairline
    /// tuned against a still, SDR backdrop therefore reads as a bright line over
    /// a Dolby Vision film, which is exactly where this material is used.
    ///
    /// Compensated rather than split into two hand-tuned constants, so there is
    /// still one edge in the app and one place to change it.
    public static func borderColor(hdrDisplayActive: Bool) -> Color {
        Color.white.opacity(hdrDisplayActive ? 0.10 : 0.16)
    }

    /// For call sites with no way to know — previews and anything outside the
    /// player. Assumes SDR, which is the safer error: too faint an edge is a
    /// missing hairline, too bright is a line drawn across someone's film.
    public static let borderColor = Color.white.opacity(0.16)

    /// The same edge used as a divider INSIDE a frosted surface.
    ///
    /// Shared with the border on purpose. A separator and a boundary are the
    /// same idea at different orientations, and having them at different
    /// weights is what made the menu dividers read as brighter than the panel
    /// edge enclosing them.
    public static let dividerColor = borderColor
    public static func dividerColor(hdrDisplayActive: Bool) -> Color {
        borderColor(hdrDisplayActive: hdrDisplayActive)
    }
    public static let dividerHeight: CGFloat = borderWidth
}

#endif
