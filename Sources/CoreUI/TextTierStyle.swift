#if canImport(SwiftUI)
import SwiftUI

/// The app's shared text-emphasis hierarchy. Every de-emphasised piece of text
/// (and monochrome supporting glyph) should resolve through one of these tiers
/// rather than SwiftUI's built-in `.secondary`/`.tertiary` hierarchical styles,
/// so tvOS and iOS/iPadOS render the *exact same* values and a theme change flows
/// through everything at once.
///
/// Tiers (see ``ThemePalette`` for the concrete per-appearance opacities):
/// - ``primary`` — titles and key values.
/// - ``secondary`` — subtitles, supporting copy, standard row icons (WCAG AA body).
/// - ``tertiary`` — captions, hints, faint metadata (WCAG AA large; never body).
public enum PlozzTextTier: Sendable {
    case primary
    case secondary
    case tertiary
}

private struct PlozzForegroundModifier: ViewModifier {
    @Environment(\.themePalette) private var palette
    let tier: PlozzTextTier

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }

    private var color: Color {
        switch tier {
        case .primary: return palette.primaryText
        case .secondary: return palette.secondaryText
        case .tertiary: return palette.tertiaryText
        }
    }
}

public extension View {
    /// Applies a shared text-emphasis tier from the palette. Self-contained (it
    /// reads the palette from the environment), so it's a drop-in replacement for
    /// `.foregroundStyle(.secondary)` / `.foregroundStyle(.tertiary)` anywhere,
    /// with no need for the call site to hold the palette itself.
    func plozzForeground(_ tier: PlozzTextTier) -> some View {
        modifier(PlozzForegroundModifier(tier: tier))
    }
}
#endif
