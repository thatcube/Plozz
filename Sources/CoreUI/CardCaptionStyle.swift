#if canImport(SwiftUI)
import SwiftUI

/// The single source of truth for a media card caption's text colour, so **every**
/// card type (poster, landscape, library, music) flips contrast identically on
/// focus.
///
/// When a focused card renders an opaque white "lift" surface — Reduce
/// Transparency is on, or the OS predates Liquid Glass (tvOS < 26) — the
/// title/subtitle must flip to dark ink so they stay legible over the white. On
/// the translucent-glass path (tvOS 26+) the text stays primary/secondary over
/// the glass. Centralising this here keeps the four card types from drifting
/// apart (the Home "Libraries" tile previously didn't flip at all).
public enum PlozzCardCaption {
    /// Whether a focused card is showing the opaque "lift" surface that the
    /// caption must flip to dark ink to remain legible over.
    public static func usesLiftText(isFocused: Bool, reduceTransparency: Bool) -> Bool {
        guard isFocused else { return false }
        if reduceTransparency { return true }
        if #available(tvOS 26.0, *) { return false }
        return true
    }

    /// Title colour for a card caption given its focus + transparency state.
    public static func titleColor(isFocused: Bool, reduceTransparency: Bool) -> Color {
        usesLiftText(isFocused: isFocused, reduceTransparency: reduceTransparency)
            ? .black.opacity(0.9)
            : .primary
    }

    /// Subtitle colour for a card caption given its focus + transparency state.
    public static func subtitleColor(isFocused: Bool, reduceTransparency: Bool) -> Color {
        usesLiftText(isFocused: isFocused, reduceTransparency: reduceTransparency)
            ? .black.opacity(0.6)
            : .secondary
    }
}
#endif
