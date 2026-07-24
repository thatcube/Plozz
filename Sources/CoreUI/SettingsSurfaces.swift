#if canImport(SwiftUI)
import SwiftUI

public struct SettingsPageBackground: View {
    @Environment(\.themePalette) private var palette

    public init() {}

    public var body: some View {
        palette.settingsBackground
            .ignoresSafeArea()
    }
}

/// A hairline separator that uses the palette's shared ``ThemePalette/separator``
/// token instead of SwiftUI's default `Divider()` (whose OS separator colour is
/// brighter than the app's surface hairlines, so it clashes with card edges —
/// especially in OLED). Use this for dividers *inside* elevated surfaces.
public struct PlozzDivider: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.displayScale) private var displayScale

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 1 / max(displayScale, 1))
    }
}

/// Renders a surface at a given elevation rung using the palette's shared
/// ``SurfaceStyle`` table — a fill, an optional hairline border (OLED), and an
/// optional drop shadow (light / dark overlays). Every elevated surface in the
/// app (settings groups, detail cards, modals) goes through this, so tvOS and
/// iOS resolve identical values and new themes stay in lockstep.
private struct PlozzSurfaceModifier: ViewModifier {
    @Environment(\.themePalette) private var palette
    let level: SurfaceLevel
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let style = palette.surface(level)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
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

/// Applies the surface's drop shadow only when one is defined, so borderless
/// dark/OLED raised surfaces don't pay for an invisible shadow layer. Shared so
/// both the `plozzSurface` modifier and the focusable-card path render shadows
/// identically.
struct OptionalSurfaceShadow: ViewModifier {
    let shadow: SurfaceShadow?

    func body(content: Content) -> some View {
        if let shadow {
            content.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
        } else {
            content
        }
    }
}

private struct SettingsGroupSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.plozzSurface(.raised, cornerRadius: cornerRadius)
    }
}

public extension View {
    /// Paints an elevated surface behind this view at the given rung, using the
    /// palette's shared elevation table.
    func plozzSurface(_ level: SurfaceLevel, cornerRadius: CGFloat) -> some View {
        modifier(PlozzSurfaceModifier(level: level, cornerRadius: cornerRadius))
    }

    func settingsGroupSurface(cornerRadius: CGFloat) -> some View {
        modifier(SettingsGroupSurface(cornerRadius: cornerRadius))
    }
}
#endif
