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
    /// Solid page color used by modal Settings surfaces. Kept separate from the
    /// app gradient so iOS/iPadOS Settings does not stack a gradient over the
    /// already-themed app beneath it.
    public let settingsBackground: Color
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
    /// Text colour for inline error / failure messaging (wrong credentials,
    /// unreachable server, etc). Theme-aware so it reads as a clear "danger" red
    /// against each background — brighter on dark and Black, deeper on light.
    public let errorText: Color
    /// Optional accent glow bloomed from the top-centre of the background.
    /// `nil` keeps a theme flat (e.g. Black stays free of a colored glow).
    public let topGlow: Color?

    // MARK: Focused-card glass treatment (ported 1:1 from Twozz)

    /// Tint blended into a focused card's Liquid Glass so focus reads as a clear
    /// lightness shift — not just the scale bump. Dark and Black brighten toward
    /// white; Light darkens toward black, so the focused tile always separates
    /// from the page behind it. Black uses a lighter wash than Dark because its
    /// near-black backdrop makes the same white tint read stronger. Only affects
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
    /// Reserved for surfaces that genuinely need a delineating line — modals and
    /// drawers stacked on a same-colour backdrop. Ordinary content cards/sections
    /// now use the borderless ``elevatedSurface`` instead.
    public let cardOpaqueBorder: Color
    /// The single, standardized fill for elevated content surfaces — settings
    /// section groups and detail cards (About / Ratings / info) alike. Tuned per
    /// theme to read on the app backgrounds **without a border**, so surfaces look
    /// consistent everywhere: a clear step above the page in dark, a slightly
    /// lighter (but still near-black) step in OLED, and white on the light page.
    public let elevatedSurface: Color
    /// Whether this is a light-appearance palette. Drives the focused-Light
    /// opaque backing that stops the drop shadow bleeding through the glass.
    public let isLight: Bool

    /// Only the module's own `dark`/`pureBlack`/`light` literals construct palettes;
    /// external callers use the static factories (`palette(for:)`) or the ready
    /// palettes. Kept `internal` (not `public`) so adding tokens here is never a
    /// source-breaking change for consumers of the package.
    init(
        backgroundBase: Color,
        backgroundSecondary: Color,
        settingsBackground: Color,
        cardSurface: Color,
        cardBorder: Color,
        primaryText: Color,
        secondaryText: Color,
        accent: Color,
        errorText: Color,
        topGlow: Color?,
        focusedCardGlassTint: Color,
        liftSurface: Color,
        cardOpaqueSurface: Color,
        cardOpaqueBorder: Color,
        elevatedSurface: Color,
        isLight: Bool
    ) {
        self.backgroundBase = backgroundBase
        self.backgroundSecondary = backgroundSecondary
        self.settingsBackground = settingsBackground
        self.cardSurface = cardSurface
        self.cardBorder = cardBorder
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.accent = accent
        self.errorText = errorText
        self.topGlow = topGlow
        self.focusedCardGlassTint = focusedCardGlassTint
        self.liftSurface = liftSurface
        self.cardOpaqueSurface = cardOpaqueSurface
        self.cardOpaqueBorder = cardOpaqueBorder
        self.elevatedSurface = elevatedSurface
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

    /// A subtle full-width tint for the lower "information" band on the detail
    /// page — nudged a touch away from `backgroundBase` so the section reads as its
    /// own zone without competing with the cards inside it (which sit on their own
    /// `cardSurface`). Kept deliberately quiet: ~5% lighter on Dark, ~2% on the
    /// near-black OLED theme, ~5% darker on Light.
    var informationSurface: Color {
        #if canImport(UIKit)
        let base = UIColor(backgroundBase)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getRed(&r, green: &g, blue: &b, alpha: &a)
        if isLight {
            let darken: CGFloat = 0.045
            return Color(
                red: Double(r * (1 - darken)),
                green: Double(g * (1 - darken)),
                blue: Double(b * (1 - darken))
            )
        }
        // Lighten toward white; a near-black (OLED) base gets a smaller lift so it
        // stays true-black-ish. Kept small so the elevated cards clear it.
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let lift: CGFloat = luminance < 0.05 ? 0.012 : 0.028
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
        settingsBackground: Color(red: 0.09, green: 0.09, blue: 0.10),
        cardSurface: Color(red: 0.10, green: 0.10, blue: 0.12),
        cardBorder: Color.white.opacity(0.16),
        primaryText: .white,
        secondaryText: Color.white.opacity(0.62),
        accent: ThemePalette.brandAccent,
        errorText: Color(red: 1.0, green: 0.42, blue: 0.40),
        topGlow: ThemePalette.brandBlue.opacity(0.075),
        focusedCardGlassTint: Color.white.opacity(0.13),
        liftSurface: .white,
        cardOpaqueSurface: Color(red: 0.10, green: 0.10, blue: 0.12),
        cardOpaqueBorder: Color.white.opacity(0.16),
        elevatedSurface: Color(red: 0.185, green: 0.185, blue: 0.20),
        isLight: false
    )

    /// Near-black theme. It stays visibly darker than Dark while keeping pixels
    /// slightly active to reduce OLED off-to-on smearing during motion.
    static let pureBlack = ThemePalette(
        backgroundBase: Color(red: 0.025, green: 0.025, blue: 0.03),
        backgroundSecondary: Color(red: 0.012, green: 0.012, blue: 0.016),
        settingsBackground: Color(red: 0.012, green: 0.012, blue: 0.016),
        cardSurface: Color(red: 0.045, green: 0.045, blue: 0.055),
        cardBorder: Color.white.opacity(0.16),
        primaryText: .white,
        secondaryText: Color.white.opacity(0.62),
        accent: ThemePalette.brandAccent,
        errorText: Color(red: 1.0, green: 0.42, blue: 0.40),
        topGlow: nil,
        focusedCardGlassTint: Color.white.opacity(0.10),
        liftSurface: .white,
        cardOpaqueSurface: Color(red: 0.045, green: 0.045, blue: 0.055),
        cardOpaqueBorder: Color.white.opacity(0.12),
        elevatedSurface: Color(red: 0.085, green: 0.085, blue: 0.095),
        isLight: false
    )

    /// Light app theme keeps the shared app gradient and glow. Settings uses the
    /// separate neutral grouped-page token instead.
    static let light = ThemePalette(
        backgroundBase: Color(white: 1.0),
        backgroundSecondary: Color(white: 0.97),
        settingsBackground: Color(red: 0.949, green: 0.949, blue: 0.969),
        cardSurface: .white,
        cardBorder: Color.black.opacity(0.08),
        primaryText: Color.black.opacity(0.90),
        secondaryText: Color.black.opacity(0.60),
        accent: ThemePalette.brandAccent,
        errorText: Color(red: 0.78, green: 0.11, blue: 0.09),
        topGlow: ThemePalette.brandBlue.opacity(0.14),
        focusedCardGlassTint: Color.black.opacity(0.05),
        liftSurface: .white,
        cardOpaqueSurface: .white,
        cardOpaqueBorder: Color.black.opacity(0.08),
        elevatedSurface: .white,
        isLight: true
    )

    /// Resolves the concrete palette for a theme. `.system` defers to the
    /// device's current colour scheme, choosing between Dark and Light.
    static func palette(for theme: AppTheme, systemColorScheme: ColorScheme) -> ThemePalette {
        switch theme {
        case .system: return systemColorScheme == .dark ? .dark : .light
        case .dark: return .dark
        case .pureBlack: return .pureBlack
        case .light: return .light
        }
    }
}

// MARK: - AppTheme colour scheme

public extension AppTheme {
    /// The colour scheme to force on the SwiftUI view tree. `nil` (System)
    /// follows the device; Black rides the dark scheme.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark, .pureBlack: return .dark
        }
    }
}

// MARK: - App background

/// The shared app background: a soft vertical gradient between the palette's two
/// low-contrast tones, with an optional accent glow bloomed from the top-centre.
/// Ported 1:1 from my Twozz `AppBackground` (same `LinearGradient` + top-glow
/// `RadialGradient` with `endRadius: 820`), recoloured to Plozz's brand blue.
/// Theme-aware — colours come entirely from the palette, so Black renders a
/// near-black wash and Light renders a soft white wash.
public struct AppBackground: View {
    private let palette: ThemePalette

    public init(palette: ThemePalette) {
        self.palette = palette
    }

    public var body: some View {
        #if os(iOS)
        // iOS/iPadOS: a clean, flat themed fill (no gradient or glow), which
        // reads better in both light and dark mode. tvOS keeps the gradient.
        palette.backgroundBase
            .ignoresSafeArea()
        #else
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
        #endif
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
