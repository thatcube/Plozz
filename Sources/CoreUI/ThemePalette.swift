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
    /// Whether to paint the subtle brand pixel-block texture over the
    /// background. Enabled for the dark greys; off for the light theme.
    public let showsTexture: Bool

    public init(
        backgroundBase: Color,
        backgroundSecondary: Color,
        cardSurface: Color,
        cardBorder: Color,
        primaryText: Color,
        secondaryText: Color,
        accent: Color,
        topGlow: Color?,
        showsTexture: Bool
    ) {
        self.backgroundBase = backgroundBase
        self.backgroundSecondary = backgroundSecondary
        self.cardSurface = cardSurface
        self.cardBorder = cardBorder
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.accent = accent
        self.topGlow = topGlow
        self.showsTexture = showsTexture
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

    /// Soft dark theme — toned down and lower-contrast than a hard gradient so
    /// the background gently shifts rather than banding. The neutral grey base
    /// (`#2e2e30` from `tools/generate_brand_assets.py`) is nudged a touch
    /// toward the brand blue so the backdrop reads as a subtle blue-tinted wash,
    /// fading darker toward the edges.
    static let dark = ThemePalette(
        backgroundBase: Color(red: 0.15, green: 0.17, blue: 0.21),
        backgroundSecondary: Color(red: 0.08, green: 0.09, blue: 0.12),
        cardSurface: Color(red: 0.10, green: 0.10, blue: 0.12),
        cardBorder: Color.white.opacity(0.16),
        primaryText: .white,
        secondaryText: Color.white.opacity(0.62),
        accent: ThemePalette.brandAccent,
        topGlow: ThemePalette.brandBlue.opacity(0.16),
        showsTexture: true
    )

    /// Pure-black OLED theme. Background stops sit near black with only a
    /// whisper of blue-tinted separation and no glow, so the panel can still
    /// switch pixels fully off.
    static let oled = ThemePalette(
        backgroundBase: Color(red: 0.03, green: 0.04, blue: 0.06),
        backgroundSecondary: .black,
        cardSurface: Color(red: 0.10, green: 0.10, blue: 0.12),
        cardBorder: Color.white.opacity(0.16),
        primaryText: .white,
        secondaryText: Color.white.opacity(0.62),
        accent: ThemePalette.brandAccent,
        topGlow: nil,
        showsTexture: true
    )

    /// Light theme — soft off-white background gently washed toward the brand
    /// blue so the gradient backdrop stays subtle but on-brand in light mode.
    static let light = ThemePalette(
        backgroundBase: Color(red: 0.97, green: 0.98, blue: 1.0),
        backgroundSecondary: Color(red: 0.89, green: 0.92, blue: 0.97),
        cardSurface: .white,
        cardBorder: Color.black.opacity(0.12),
        primaryText: Color.black.opacity(0.90),
        secondaryText: Color.black.opacity(0.60),
        accent: ThemePalette.brandAccent,
        topGlow: ThemePalette.brandBlue.opacity(0.14),
        showsTexture: false
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
/// bloomed from the top-centre and a very subtle brand pixel-block texture on
/// the dark themes. Theme-aware — colours come entirely from the palette, so
/// OLED renders pure black and Light renders a soft white wash.
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
        .overlay {
            if palette.showsTexture {
                PixelTextureOverlay()
            }
        }
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

/// A deterministic, very-subtle pixel-block texture echoing the brand's
/// generated background (`tools/generate_brand_assets.py`): a grid of cells with
/// tiny per-cell brightness jitter, painted at low opacity in `.softLight` so
/// the dark app background reads as a soft, brand-cohesive shift rather than a
/// flat fill. Seeded so it is stable across redraws.
private struct PixelTextureOverlay: View {
    /// Side of each texture cell. Kept coarse so the whole screen is only a few
    /// hundred cells (cheap) and the jitter stays gentle, not noisy.
    private let cell: CGFloat = 36
    private let seed: UInt64 = 0x504C5A // "PLZ"

    var body: some View {
        Canvas { context, size in
            var rng = SplitMix64(seed: seed)
            let cols = Int((size.width / cell).rounded(.up))
            let rows = Int((size.height / cell).rounded(.up))
            guard cols > 0, rows > 0 else { return }
            for row in 0..<rows {
                for col in 0..<cols {
                    // Per-cell brightness jitter: half nudge lighter, half darker,
                    // each by a small fraction — the soft analogue of the
                    // generator's +/- PIXEL_JITTER.
                    let lighten = (rng.next() & 1) == 0
                    let magnitude = Double(rng.next() % 256) / 255.0 * 0.05
                    let rect = CGRect(x: CGFloat(col) * cell,
                                      y: CGFloat(row) * cell,
                                      width: cell, height: cell)
                    let color = (lighten ? Color.white : Color.black).opacity(magnitude)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .blendMode(.softLight)
        .allowsHitTesting(false)
    }
}

/// Tiny deterministic PRNG (SplitMix64) so the texture is reproducible without
/// pulling in any dependency.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
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
