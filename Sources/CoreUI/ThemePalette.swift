#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The concrete colours a resolved `AppTheme` paints with.
///
/// Ported from my Twozz `ThemePalette` for structural parity, trimmed to the
/// tokens Plozz needs: a two-stop background (driven into a soft radial
/// gradient by `AppBackground`), card surface + border, primary/secondary text,
/// an accent/tint, and an optional top glow. The accent is **Plozz's own**
/// `AccentColor` (via `Color.accentColor`) — never Twozz's brand purple.
public struct ThemePalette: Equatable, Sendable {
    /// Brighter inner colour of the background radial gradient.
    public let backgroundBase: Color
    /// Darker outer colour of the background radial gradient. The two stay close
    /// in value so the shift reads as a soft, low-contrast wash.
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

    public init(
        backgroundBase: Color,
        backgroundSecondary: Color,
        cardSurface: Color,
        cardBorder: Color,
        primaryText: Color,
        secondaryText: Color,
        accent: Color,
        topGlow: Color?
    ) {
        self.backgroundBase = backgroundBase
        self.backgroundSecondary = backgroundSecondary
        self.cardSurface = cardSurface
        self.cardBorder = cardBorder
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.accent = accent
        self.topGlow = topGlow
    }
}

// MARK: - Concrete palettes

public extension ThemePalette {
    /// Plozz's configured accent colour (the `AccentColor` asset). Resolves to
    /// the app's tint at runtime; reserved here so a future asset change flows
    /// through every theme.
    static var brandAccent: Color { .accentColor }

    /// Soft dark gray theme — toned down and lower-contrast than a hard
    /// gradient so the background gently shifts rather than banding.
    static let dark = ThemePalette(
        backgroundBase: Color(red: 0.11, green: 0.11, blue: 0.12),
        backgroundSecondary: Color(red: 0.07, green: 0.07, blue: 0.085),
        cardSurface: Color(red: 0.10, green: 0.10, blue: 0.12),
        cardBorder: Color.white.opacity(0.16),
        primaryText: .white,
        secondaryText: Color.white.opacity(0.62),
        accent: ThemePalette.brandAccent,
        topGlow: ThemePalette.brandAccent.opacity(0.06)
    )

    /// Pure-black OLED theme. Background stops sit near black with only a
    /// whisper of separation, and no glow, so the panel can switch pixels off.
    static let oled = ThemePalette(
        backgroundBase: Color(red: 0.03, green: 0.03, blue: 0.04),
        backgroundSecondary: .black,
        cardSurface: Color(red: 0.10, green: 0.10, blue: 0.12),
        cardBorder: Color.white.opacity(0.16),
        primaryText: .white,
        secondaryText: Color.white.opacity(0.62),
        accent: ThemePalette.brandAccent,
        topGlow: nil
    )

    /// Light theme — soft off-white background wash.
    static let light = ThemePalette(
        backgroundBase: Color(white: 1.0),
        backgroundSecondary: Color(white: 0.95),
        cardSurface: .white,
        cardBorder: Color.black.opacity(0.12),
        primaryText: Color.black.opacity(0.90),
        secondaryText: Color.black.opacity(0.60),
        accent: ThemePalette.brandAccent,
        topGlow: ThemePalette.brandAccent.opacity(0.10)
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

/// The shared app background: a soft radial gradient that gently shifts between
/// the palette's two darker, low-contrast tones, with an optional accent glow
/// bloomed from the top-centre. Theme-aware — colours come entirely from the
/// palette, so OLED renders pure black and Light renders a soft white wash.
public struct AppBackground: View {
    private let palette: ThemePalette

    public init(palette: ThemePalette) {
        self.palette = palette
    }

    public var body: some View {
        RadialGradient(
            gradient: Gradient(colors: [palette.backgroundBase, palette.backgroundSecondary]),
            center: .top,
            startRadius: 0,
            endRadius: 1600
        )
        .background(palette.backgroundSecondary)
        .overlay(alignment: .top) {
            if let glow = palette.topGlow {
                RadialGradient(
                    gradient: Gradient(colors: [glow, .clear]),
                    center: .top,
                    startRadius: 0,
                    endRadius: 900
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
