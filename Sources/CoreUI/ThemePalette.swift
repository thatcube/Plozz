#if canImport(SwiftUI)
import SwiftUI
import CoreModels
#if canImport(UIKit)
import UIKit
#endif

/// The concrete colours a resolved `AppTheme` paints with.
///
/// Ported from my Twozz `ThemePalette` for structural parity, trimmed to the
/// tokens Plozz needs: a two-stop background (driven into a soft vertical
/// gradient by `AppBackground`), card surface + border, primary/secondary text,
/// an accent/tint, and an optional top glow. The accent is **Plozz's own**
/// `AccentColor` (via `Color.accentColor`) — never Twozz's brand purple.
public struct ThemePalette: Equatable, Sendable {
    /// Top stop of the vertical background gradient.
    public let backgroundBase: Color
    /// Bottom stop of the vertical background gradient. The two stay close in
    /// value so the shift reads as a soft, low-contrast wash.
    public let backgroundSecondary: Color
    /// Fill used for card / surface chrome.
    public let cardSurface: Color
    /// Hairline border drawn around a card surface.
    public let cardBorder: Color
    /// Primary text colour for the theme.
    public let primaryText: Color
    /// Secondary / de-emphasised text colour.
    public let secondaryText: Color
    /// Accent / tint colour (Plozz's `AccentColor`).
    public let accent: Color
    /// Optional accent glow bloomed from the top-centre of the background.
    /// `nil` keeps a theme flat (e.g. OLED stays pure black).
    public let topGlow: Color?

    // MARK: Focused-card glass treatment (ported 1:1 from Twozz)

    /// Tint blended into a focused card's Liquid Glass so focus reads as a clear
    /// lightness shift — not just the scale bump. Dark/OLED brighten toward
    /// white; Light darkens toward black, so the focused tile always separates
    /// from the page behind it. OLED uses a lighter wash than Dark because its
    /// pure-black backdrop makes the same white tint read stronger. Only affects
    /// the translucent-glass path; the Reduce Transparency path uses `liftSurface`.
    public let focusedCardGlassTint: Color
    /// Opaque fill behind a *focused* card when glass is disabled (Reduce
    /// Transparency) — a strong high-contrast "lift".
    public let liftSurface: Color
    /// Opaque fill behind an *unfocused* card when glass is disabled. Theme-aware
    /// so Light mode stays white instead of falling back to near-black.
    public let cardOpaqueSurface: Color
    /// Hairline border drawn around an unfocused opaque card so it reads against
    /// a same-coloured background (e.g. white card on a white light-mode page).
    public let cardOpaqueBorder: Color
    /// Whether this is a light-appearance palette. Drives the focused-Light
    /// opaque backing that stops the drop shadow bleeding through the glass.
    public let isLight: Bool

    public init(
        backgroundBase: Color,
        backgroundSecondary: Color,
        cardSurface: Color,
        cardBorder: Color,
        primaryText: Color,
        secondaryText: Color,
        accent: Color,
        topGlow: Color?,
        focusedCardGlassTint: Color,
        liftSurface: Color,
        cardOpaqueSurface: Color,
        cardOpaqueBorder: Color,
        isLight: Bool
    ) {
        self.backgroundBase = backgroundBase
        self.backgroundSecondary = backgroundSecondary
        self.cardSurface = cardSurface
        self.cardBorder = cardBorder
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.accent = accent
        self.topGlow = topGlow
        self.focusedCardGlassTint = focusedCardGlassTint
        self.liftSurface = liftSurface
        self.cardOpaqueSurface = cardOpaqueSurface
        self.cardOpaqueBorder = cardOpaqueBorder
        self.isLight = isLight
    }
}

// MARK: - Concrete palettes

public extension ThemePalette {
    /// Plozz's configured accent colour (the `AccentColor` asset). Resolves to
    /// the app's tint at runtime; reserved here so a future asset change flows
    /// through every theme.
    static var brandAccent: Color { .accentColor }

    /// Plozz's brand blue — the Jellyfin blue (`#00A4DC`) the pixel logo is
    /// painted in. Used to give the app-wide background a gentle blue wash and
    /// top glow in every theme, mirroring how Twozz tints its backdrop with its
    /// own brand colour (Plozz's is BLUE, never Twozz's purple).
    static let brandBlue = Color(red: 0.0, green: 0.643, blue: 0.863) // #00A4DC

    /// Frosted-glass tone for the hairline rim around media thumbnails — the
    /// theme's lower background stop nudged 9% toward white, ported from Twozz's
    /// `mediaEdgeColor`. It blends with the surrounding card while quietly
    /// covering the ~1–2px a clipped image/video plane can bleed past the rounded
    /// corners, giving every thumbnail the same clean inner glass edge.
    var mediaEdgeColor: Color {
        #if canImport(UIKit)
        let base = UIColor(backgroundSecondary)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getRed(&r, green: &g, blue: &b, alpha: &a)
        let lift: CGFloat = 0.09
        return Color(
            red: Double(r + (1 - r) * lift),
            green: Double(g + (1 - g) * lift),
            blue: Double(b + (1 - b) * lift)
        )
        #else
        return backgroundSecondary
        #endif
    }

    /// Soft dark theme. Uses the exact two-stop background gradient from my
    /// Twozz `ThemePalette.dark`, with the top glow recoloured to Plozz's brand
    /// blue (Twozz uses purple). The stops stay close in value so the backdrop
    /// gently shifts rather than banding.
    static let dark = ThemePalette(
        backgroundBase: Color(red: 0.13, green: 0.13, blue: 0.14),
        backgroundSecondary: Color(red: 0.09, green: 0.09, blue: 0.10),
        cardSurface: Color(red: 0.10, green: 0.10, blue: 0.12),
        cardBorder: Color.white.opacity(0.16),
        primaryText: .white,
        secondaryText: Color.white.opacity(0.62),
        accent: ThemePalette.brandAccent,
        topGlow: ThemePalette.brandBlue.opacity(0.075),
        focusedCardGlassTint: Color.white.opacity(0.13),
        liftSurface: .white,
        cardOpaqueSurface: Color(red: 0.10, green: 0.10, blue: 0.12),
        cardOpaqueBorder: Color.white.opacity(0.16),
        isLight: false
    )

    /// Pure-black OLED theme. Matches Twozz's `ThemePalette.oled`: both stops
    /// sit at pure black with no glow, so the panel can switch pixels fully off.
    static let oled = ThemePalette(
        backgroundBase: .black,
        backgroundSecondary: .black,
        cardSurface: Color(red: 0.10, green: 0.10, blue: 0.12),
        cardBorder: Color.white.opacity(0.16),
        primaryText: .white,
        secondaryText: Color.white.opacity(0.62),
        accent: ThemePalette.brandAccent,
        topGlow: nil,
        focusedCardGlassTint: Color.white.opacity(0.10),
        liftSurface: .white,
        cardOpaqueSurface: .black,
        cardOpaqueBorder: Color.white.opacity(0.16),
        isLight: false
    )

    /// Light theme. Uses the exact two-stop background gradient from my Twozz
    /// `ThemePalette.light` (a soft off-white wash), with the top glow
    /// recoloured to Plozz's brand blue (Twozz uses purple).
    static let light = ThemePalette(
        backgroundBase: Color(white: 1.0),
        backgroundSecondary: Color(white: 0.97),
        cardSurface: .white,
        cardBorder: Color.black.opacity(0.12),
        primaryText: Color.black.opacity(0.90),
        secondaryText: Color.black.opacity(0.60),
        accent: ThemePalette.brandAccent,
        topGlow: ThemePalette.brandBlue.opacity(0.14),
        focusedCardGlassTint: Color.black.opacity(0.05),
        liftSurface: .white,
        cardOpaqueSurface: .white,
        cardOpaqueBorder: Color.black.opacity(0.12),
        isLight: true
    )

    /// Resolves the concrete palette for a theme. `.system` defers to the
    /// device's current colour scheme, choosing between Dark and Light.
    static func palette(for theme: AppTheme, systemColorScheme: ColorScheme) -> ThemePalette {
        switch theme {
        case .system: return systemColorScheme == .dark ? .dark : .light
        case .dark: return .dark
        case .oled: return .oled
        case .light: return .light
        }
    }
}

// MARK: - AppTheme colour scheme

public extension AppTheme {
    /// The colour scheme to force on the SwiftUI view tree. `nil` (System)
    /// follows the device; OLED rides the dark scheme.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark, .oled: return .dark
        }
    }
}

// MARK: - App background

/// The shared app background: a soft vertical gradient between the palette's two
/// low-contrast tones, with an optional accent glow bloomed from the top-centre.
/// Ported 1:1 from my Twozz `AppBackground` (same `LinearGradient` + top-glow
/// `RadialGradient` with `endRadius: 820`), recoloured to Plozz's brand blue.
/// Theme-aware — colours come entirely from the palette, so OLED renders pure
/// black and Light renders a soft white wash.
public struct AppBackground: View {
    private let palette: ThemePalette

    public init(palette: ThemePalette) {
        self.palette = palette
    }

    public var body: some View {
        LinearGradient(
            colors: [palette.backgroundBase, palette.backgroundSecondary],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .top) {
            if let glow = palette.topGlow {
                RadialGradient(
                    gradient: Gradient(colors: [glow, .clear]),
                    center: .top,
                    startRadius: 0,
                    endRadius: 820
                )
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Environment plumbing

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue: ThemePalette = .dark
}

public extension EnvironmentValues {
    /// The resolved palette for the active theme, injected at the app root.
    var themePalette: ThemePalette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}

#endif
