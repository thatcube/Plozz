#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Maps a `Profile.colorIndex` to a concrete tile accent color.
///
/// Lives in the UI layer so `CoreModels` stays Foundation-only. The palette is
/// deliberately vivid and high-contrast for the 10-foot tvOS experience.
public enum ProfileTileColor {
    /// Vivid, high-contrast tile colours for the 10-foot tvOS UI, ordered by
    /// hue so like colours sit together, then a group of neutral tones (greys,
    /// tan, brown, charcoal) at the end. 32 total → a clean 8-wide, 4-row grid.
    /// Keep `Profile.tileColorCount` in sync with this count.
    public static let palette: [Color] = [
        // Reds / rose
        Color(red: 0.92, green: 0.26, blue: 0.30),
        Color(red: 0.95, green: 0.35, blue: 0.45),
        Color(red: 0.96, green: 0.45, blue: 0.50),
        // Oranges
        Color(red: 0.98, green: 0.48, blue: 0.28),
        Color(red: 0.97, green: 0.60, blue: 0.24),
        // Amber / yellow
        Color(red: 0.96, green: 0.72, blue: 0.20),
        Color(red: 0.92, green: 0.82, blue: 0.32),
        // Lime / mint
        Color(red: 0.66, green: 0.80, blue: 0.28),
        Color(red: 0.55, green: 0.85, blue: 0.60),
        // Greens
        Color(red: 0.48, green: 0.78, blue: 0.35),
        Color(red: 0.30, green: 0.74, blue: 0.44),
        Color(red: 0.20, green: 0.72, blue: 0.55),
        // Teal / cyan
        Color(red: 0.18, green: 0.74, blue: 0.74),
        Color(red: 0.24, green: 0.68, blue: 0.86),
        // Sky / blue
        Color(red: 0.40, green: 0.68, blue: 0.95),
        Color(red: 0.26, green: 0.56, blue: 0.95),
        Color(red: 0.20, green: 0.45, blue: 0.90),
        // Indigo
        Color(red: 0.36, green: 0.40, blue: 0.86),
        Color(red: 0.48, green: 0.42, blue: 0.92),
        // Purple
        Color(red: 0.62, green: 0.40, blue: 0.92),
        Color(red: 0.74, green: 0.42, blue: 0.88),
        // Magenta / pink
        Color(red: 0.88, green: 0.36, blue: 0.78),
        Color(red: 0.95, green: 0.40, blue: 0.68),
        Color(red: 0.96, green: 0.52, blue: 0.66),
        // Neutrals
        Color(red: 0.85, green: 0.86, blue: 0.88), // light grey
        Color(red: 0.70, green: 0.72, blue: 0.75), // silver
        Color(red: 0.55, green: 0.60, blue: 0.68), // slate
        Color(red: 0.50, green: 0.50, blue: 0.55), // grey
        Color(red: 0.34, green: 0.35, blue: 0.40), // charcoal
        Color(red: 0.62, green: 0.56, blue: 0.50), // taupe
        Color(red: 0.80, green: 0.70, blue: 0.55), // tan
        Color(red: 0.58, green: 0.44, blue: 0.34)  // brown
    ]

    public static func color(for profile: Profile) -> Color {
        palette[min(profile.clampedColorIndex, palette.count - 1)]
    }

    public static func color(forIndex index: Int) -> Color {
        guard !palette.isEmpty else { return .accentColor }
        let i = ((index % palette.count) + palette.count) % palette.count
        return palette[i]
    }
}
#endif
