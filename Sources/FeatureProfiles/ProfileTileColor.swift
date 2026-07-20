#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Maps a `Profile.colorIndex` to a concrete tile accent color.
///
/// Lives in the UI layer so `CoreModels` stays Foundation-only. The palette is
/// deliberately vivid and high-contrast for the 10-foot tvOS experience, held as
/// RGB triples so we can both build the `Color` and compute a legible foreground
/// (dark glyph on light tiles, white glyph on dark tiles) — which is what lets
/// **white** work as a symbol background without the white glyph vanishing.
public enum ProfileTileColor {
    /// One palette entry as raw components (0…1).
    public struct RGB: Sendable, Hashable {
        public let r, g, b: Double
        public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        var color: Color { Color(red: r, green: g, blue: b) }
        /// Perceived luminance (Rec. 601), used to pick a legible foreground.
        var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
    }

    /// 40 tile colours ordered by hue (warm → cool → purples/pinks) then a group
    /// of neutrals that now includes **white** and **black**. 40 = a clean 8-wide
    /// 5-row grid. Keep `Profile.tileColorCount` in sync with this count.
    public static let paletteRGB: [RGB] = [
        // Reds / rose
        RGB(0.92, 0.26, 0.30), RGB(0.80, 0.20, 0.24), RGB(0.95, 0.35, 0.45), RGB(0.96, 0.45, 0.50),
        // Oranges
        RGB(0.98, 0.48, 0.28), RGB(0.97, 0.60, 0.24), RGB(0.72, 0.38, 0.24) /* rust */,
        // Amber / yellow / gold
        RGB(0.96, 0.72, 0.20), RGB(0.85, 0.65, 0.13), RGB(0.92, 0.82, 0.32),
        // Lime / mint
        RGB(0.66, 0.80, 0.28), RGB(0.75, 0.85, 0.40), RGB(0.55, 0.85, 0.60),
        // Greens
        RGB(0.40, 0.78, 0.40), RGB(0.28, 0.72, 0.42), RGB(0.18, 0.72, 0.55),
        // Teal / cyan
        RGB(0.16, 0.74, 0.72), RGB(0.22, 0.80, 0.85), RGB(0.24, 0.66, 0.88),
        // Sky / blue
        RGB(0.40, 0.68, 0.95), RGB(0.26, 0.56, 0.95), RGB(0.20, 0.44, 0.90),
        // Indigo / violet
        RGB(0.34, 0.38, 0.86), RGB(0.48, 0.42, 0.92),
        // Purple / orchid
        RGB(0.62, 0.40, 0.92), RGB(0.74, 0.42, 0.88),
        // Magenta / pink
        RGB(0.88, 0.36, 0.78), RGB(0.95, 0.42, 0.70), RGB(0.98, 0.52, 0.66),
        // Neutrals (incl. white & black)
        RGB(1.00, 1.00, 1.00) /* white */,
        RGB(0.85, 0.86, 0.88) /* light grey */,
        RGB(0.68, 0.70, 0.74) /* silver */,
        RGB(0.55, 0.60, 0.68) /* slate */,
        RGB(0.40, 0.42, 0.48) /* steel */,
        RGB(0.11, 0.11, 0.13) /* black */,
        // Earth tones
        RGB(0.88, 0.80, 0.62) /* sand */,
        RGB(0.80, 0.70, 0.55) /* tan */,
        RGB(0.62, 0.56, 0.50) /* taupe */,
        RGB(0.58, 0.44, 0.34) /* brown */,
        RGB(0.36, 0.26, 0.20) /* espresso */
    ]

    /// The palette as SwiftUI `Color`s.
    public static let palette: [Color] = paletteRGB.map(\.color)

    private static let accessibilityNames: [LocalizedStringResource] = [
        "Coral red", "Crimson", "Rose", "Salmon",
        "Orange", "Tangerine", "Rust",
        "Amber", "Gold", "Yellow",
        "Lime", "Light lime", "Mint",
        "Green", "Emerald", "Sea green",
        "Teal", "Cyan", "Sky blue",
        "Light blue", "Blue", "Royal blue",
        "Indigo", "Violet",
        "Purple", "Orchid",
        "Magenta", "Pink", "Blush",
        "White", "Light gray", "Silver", "Slate", "Steel gray", "Black",
        "Sand", "Tan", "Taupe", "Brown", "Espresso"
    ]

    private static func wrapped(_ index: Int) -> Int {
        guard !paletteRGB.isEmpty else { return 0 }
        return ((index % paletteRGB.count) + paletteRGB.count) % paletteRGB.count
    }

    public static func color(for profile: Profile) -> Color {
        color(forIndex: profile.clampedColorIndex)
    }

    public static func color(forIndex index: Int) -> Color {
        guard !paletteRGB.isEmpty else { return .accentColor }
        return paletteRGB[wrapped(index)].color
    }

    public static func accessibilityName(forIndex index: Int) -> LocalizedStringResource {
        guard !accessibilityNames.isEmpty else { return "Avatar color" }
        return accessibilityNames[((index % accessibilityNames.count) + accessibilityNames.count)
            % accessibilityNames.count]
    }

    /// A legible foreground (black or white) for content drawn *on top of* the
    /// tile colour at `index` — dark on light tiles (white, yellow, tan…), white
    /// on dark tiles (black, navy, purple…). This is what makes a **white** tile
    /// usable for a symbol avatar (the glyph flips to dark) and keeps the colour
    /// picker's checkmark legible on every swatch.
    public static func legibleForeground(forIndex index: Int) -> Color {
        guard !paletteRGB.isEmpty else { return .white }
        return paletteRGB[wrapped(index)].luminance > 0.65 ? .black : .white
    }

    public static func legibleForeground(for profile: Profile) -> Color {
        legibleForeground(forIndex: profile.clampedColorIndex)
    }
}
#endif
