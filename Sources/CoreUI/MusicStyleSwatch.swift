#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, appearance-independent colours for a music-player preview swatch.
/// Like `ThemePreviewColors`, these are a *picture* of each player look and never
/// adapt to the currently applied theme. Models the real player's layering: a
/// solid `base`, artwork-colored blobs at `blobOpacity`, and a `scrim` veil.
private struct MusicStylePreviewColors {
    /// Solid floor under the artwork blobs (white for the frosted look, else black).
    let base: Color
    /// How strongly the artwork colors show through, per style (mirrors the real
    /// `LiquidArtworkBackground.gradientOpacity`).
    let blobOpacity: Double
    /// Legibility veil painted over the blobs (a white frost for Light, black
    /// veils for Dark/OLED — OLED heaviest so colors read as faint accents).
    let scrim: Color
    /// Progress-track colour (the unfilled scrubber behind the played portion).
    let track: Color
    /// Played-portion colour of the scrubber. The real player uses white on a
    /// lighter-white track, so this is white.
    let seek: Color

    /// The album-art tile gradient AND the source of the background blobs — a
    /// fixed, vivid palette so every variant shows the same "artwork," with only
    /// the surrounding chrome (base, veil) changing per style.
    static let artwork: [Color] = [
        Color(red: 0.98, green: 0.42, blue: 0.55),  // pink
        Color(red: 0.42, green: 0.38, blue: 0.95)   // purple
    ]
    /// Extra blob colors so the tinted field reads multi-hue like real artwork.
    static let blobs: [Color] = [
        Color(red: 0.98, green: 0.42, blue: 0.55),  // pink   (top-leading)
        Color(red: 0.42, green: 0.38, blue: 0.95),  // purple (bottom-trailing)
        Color(red: 0.20, green: 0.80, blue: 0.85)   // teal   (bottom-leading)
    ]

    static let light = MusicStylePreviewColors(
        base: .white,
        blobOpacity: 0.95,
        scrim: Color.white.opacity(0.34),
        track: Color.white.opacity(0.9),
        seek: Color.white
    )
    static let dark = MusicStylePreviewColors(
        base: .black,
        blobOpacity: 1.0,
        scrim: Color.black.opacity(0.34),
        track: Color.white.opacity(0.3),
        seek: Color.white
    )
    static let oled = MusicStylePreviewColors(
        base: .black,
        blobOpacity: 0.55,
        scrim: Color.black.opacity(0.6),
        track: Color.white.opacity(0.3),
        seek: Color.white
    )
}

/// Static stand-in for the player's animated liquid background: the artwork
/// palette painted as a few soft, blended radial "blobs." No animation (cheap),
/// but captures the tinted, multi-hue field.
private struct ArtworkBlobs: View {
    let width: CGFloat

    var body: some View {
        let c = MusicStylePreviewColors.blobs
        ZStack {
            RadialGradient(colors: [c[0].opacity(0.95), .clear], center: .topLeading, startRadius: 0, endRadius: width * 0.75)
            RadialGradient(colors: [c[1].opacity(0.95), .clear], center: .bottomTrailing, startRadius: 0, endRadius: width * 0.75)
            RadialGradient(colors: [c[2].opacity(0.85), .clear], center: .bottomLeading, startRadius: 0, endRadius: width * 0.6)
        }
        .blur(radius: width * 0.07)
    }
}

/// A tiny mock "now playing" screen: an artwork-tinted background (base + blobs
/// + scrim, mirroring the real player), a centred album-art tile, and a progress
/// bar. Deliberately static (per the small preview size). Fills whatever frame
/// the caller gives it and stays proportionate at half width (each side of the
/// Match-Theme split).
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
                    .shadow(color: .black.opacity(0.35), radius: art * 0.08, y: art * 0.04)
                Spacer(minLength: 0)
                // Progress bar: white played portion on a lighter-white track.
                // A soft shadow lifts it off light backgrounds where white-on-
                // near-white would otherwise wash out.
                ZStack(alignment: .leading) {
                    Capsule().fill(colors.track).frame(height: barH)
                    Capsule().fill(colors.seek).frame(width: innerW * 0.4, height: barH)
                }
                .frame(width: innerW)
                .shadow(color: .black.opacity(0.25), radius: barH * 0.9, y: barH * 0.35)
            }
            .padding(pad)
            .frame(width: w, height: h)
            .background {
                // Base → artwork blobs (per-style strength) → legibility veil.
                ZStack {
                    colors.base
                    ArtworkBlobs(width: w).opacity(colors.blobOpacity)
                    colors.scrim
                }
            }
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
