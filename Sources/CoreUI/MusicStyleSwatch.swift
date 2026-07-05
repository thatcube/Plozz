#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, appearance-independent colours for a music-player preview swatch.
/// Like `ThemePreviewColors`, these are a *picture* of each player look and never
/// adapt to the currently applied theme.
private struct MusicStylePreviewColors {
    let bgTop: Color
    let bgBottom: Color
    /// Progress-track colour (the unfilled scrubber).
    let track: Color

    /// A fixed, vivid "album art" gradient — the artwork is the same in every
    /// variant; only the surrounding chrome (background, track) changes.
    static let artwork: [Color] = [
        Color(red: 0.98, green: 0.42, blue: 0.55),
        Color(red: 0.42, green: 0.38, blue: 0.95)
    ]
    static let accent = ThemePreviewColors.accentBlue

    static let light = MusicStylePreviewColors(
        bgTop: Color(white: 0.97),
        bgBottom: Color(white: 0.90),
        track: Color.black.opacity(0.14)
    )
    static let dark = MusicStylePreviewColors(
        bgTop: Color(red: 0.17, green: 0.16, blue: 0.20),
        bgBottom: Color(red: 0.10, green: 0.09, blue: 0.13),
        track: Color.white.opacity(0.22)
    )
    static let oled = MusicStylePreviewColors(
        bgTop: .black,
        bgBottom: .black,
        track: Color.white.opacity(0.24)
    )
}

/// A tiny mock "now playing" screen: a centred album-art tile with a progress
/// bar beneath it. Deliberately simple (per the small preview size). Fills
/// whatever frame the caller gives it and stays proportionate at half width
/// (each side of the Match-Theme split).
private struct MusicMini: View {
    let colors: MusicStylePreviewColors

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad: CGFloat = 16
            let innerW = w - pad * 2
            let innerH = h - pad * 2
            let art = min(innerW * 0.62, innerH * 0.66)
            let barH = max(4, h * 0.05)

            VStack(spacing: h * 0.08) {
                Spacer(minLength: 0)
                // Album art.
                RoundedRectangle(cornerRadius: art * 0.12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: MusicStylePreviewColors.artwork,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: art, height: art)
                    .overlay(
                        RoundedRectangle(cornerRadius: art * 0.12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                Spacer(minLength: 0)
                // Progress bar.
                ZStack(alignment: .leading) {
                    Capsule().fill(colors.track).frame(height: barH)
                    Capsule().fill(MusicStylePreviewColors.accent).frame(width: innerW * 0.4, height: barH)
                }
                .frame(width: innerW)
            }
            .padding(pad)
            .frame(width: w, height: h)
            .background(
                LinearGradient(colors: [colors.bgTop, colors.bgBottom], startPoint: .top, endPoint: .bottom)
            )
        }
    }
}

/// The per-appearance preview graphic for the music player style picker.
/// Light/Dark/OLED show their own fixed chrome; Match Theme is one screen split
/// light | dark down the middle (mirroring the System theme swatch) to signal
/// "follows your theme." Fills the caller's frame, so it scales for the full and
/// compact card sizes.
public struct MusicStyleSwatch: View {
    private let appearance: MusicPlayerAppearance
    private let cornerRadius: CGFloat

    public init(appearance: MusicPlayerAppearance, cornerRadius: CGFloat = 16) {
        self.appearance = appearance
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        Group {
            switch appearance {
            case .matchTheme:
                GeometryReader { geo in
                    ZStack {
                        MusicMini(colors: .light)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geo.size.width / 2 + 0.5)
                            }
                        MusicMini(colors: .dark)
                            .mask(alignment: .trailing) {
                                Rectangle().frame(width: geo.size.width / 2)
                            }
                    }
                }
            case .light:
                MusicMini(colors: .light)
            case .dark:
                MusicMini(colors: .dark)
            case .oled:
                MusicMini(colors: .oled)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(white: 0.5).opacity(0.35), lineWidth: 1)
        )
    }
}
#endif
