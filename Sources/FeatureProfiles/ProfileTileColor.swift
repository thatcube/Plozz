#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Maps a `Profile.colorIndex` to a concrete tile accent color.
///
/// Lives in the UI layer so `CoreModels` stays Foundation-only. The palette is
/// deliberately vivid and high-contrast for the 10-foot tvOS experience.
public enum ProfileTileColor {
    public static let palette: [Color] = [
        Color(red: 0.20, green: 0.55, blue: 0.95), // blue
        Color(red: 0.95, green: 0.35, blue: 0.45), // red
        Color(red: 0.40, green: 0.78, blue: 0.45), // green
        Color(red: 0.95, green: 0.65, blue: 0.20), // amber
        Color(red: 0.62, green: 0.40, blue: 0.92), // purple
        Color(red: 0.20, green: 0.75, blue: 0.78), // teal
        Color(red: 0.95, green: 0.45, blue: 0.75), // pink
        Color(red: 0.55, green: 0.60, blue: 0.68), // slate
        Color(red: 0.98, green: 0.50, blue: 0.30), // orange
        Color(red: 0.30, green: 0.45, blue: 0.85), // indigo
        Color(red: 0.55, green: 0.80, blue: 0.30), // lime
        Color(red: 0.90, green: 0.30, blue: 0.55), // magenta
        Color(red: 0.40, green: 0.68, blue: 0.95), // sky
        Color(red: 0.75, green: 0.55, blue: 0.40)  // clay
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
