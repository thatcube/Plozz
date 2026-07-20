import Foundation

/// User-selectable app appearance (pure data model).
///
/// Mirrors the `AppTheme` in my Twozz app for structural parity, but the chosen
/// theme is persisted **locally** (standard `UserDefaults`) — there is no App
/// Group or cross-app preference sharing. The concrete colours each theme paints
/// with live in `CoreUI` (`ThemePalette`), so this stays Foundation-only and the
/// Settings screen can edit it without importing SwiftUI.
public enum AppTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Follow the device's current light/dark appearance.
    case system
    /// A light theme.
    case light
    /// A soft, dark gray theme.
    case dark
    /// A near-black theme. The persisted raw value stays unchanged so existing
    /// installs retain their selection after the user-facing rename.
    case pureBlack = "oled"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .pureBlack: return "Black"
        }
    }

    /// SF Symbol shown next to the option in Settings.
    public var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .pureBlack: return "moon.stars.fill"
        }
    }

    /// Fresh installs default to Dark, regardless of the device appearance —
    /// dark and Black read best for a lean-back media app. Users can still pick any
    /// look during onboarding or later in Settings.
    public static let `default`: AppTheme = .dark

    /// The order the theme pickers (onboarding + Settings) present options in:
    /// Dark first (the default), then Black, Light, and System last.
    public static let pickerOrder: [AppTheme] = [.dark, .pureBlack, .light, .system]
}

/// How the full-screen music player paints its background and text. Independent
/// of `AppTheme`: the player can follow the app theme or be pinned to one of its
/// own looks, because its immersive, artwork-tinted background reads differently
/// from the browsing chrome. Persisted locally via `@AppStorage`.
public enum MusicPlayerAppearance: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Follow the app theme: a light theme gives the frosted-light player, any
    /// dark theme gives the vibrant-dark player.
    case matchTheme
    /// Always a frosted, lightly artwork-tinted light look.
    case light
    /// Always the vibrant, artwork-tinted dark look.
    case dark
    /// Always true black, with the artwork colors as subtle accents. The
    /// persisted raw value stays unchanged for existing installs.
    case pureBlack = "oled"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .matchTheme: return "Match Theme"
        case .light: return "Light"
        case .dark: return "Dark"
        case .pureBlack: return "Pure Black"
        }
    }

    /// SF Symbol shown next to the option in Settings.
    public var symbolName: String {
        switch self {
        case .matchTheme: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .pureBlack: return "moon.stars.fill"
        }
    }

    public static let `default`: MusicPlayerAppearance = .matchTheme

    /// The order the music-player style picker presents options in: Dark, Pure Black,
    /// Light, then Match Theme last (mirroring the theme picker, where the
    /// "follows something else" option sits at the end).
    public static let pickerOrder: [MusicPlayerAppearance] = [.dark, .pureBlack, .light, .matchTheme]

    /// AppStorage key shared by the player (reads it) and Settings (writes it).
    public static let storageKey = "musicPlayerAppearance"
}

/// Persistence for the Now Playing lyrics on/off toggle. Held here so every site
/// that reads the preference — the player's `@AppStorage` toggle and the lyrics
/// resolver that decides whether to consult the third-party LRCLIB fallback —
/// shares one key and default instead of duplicating a string literal.
public enum MusicLyricsPreference {
    /// AppStorage/UserDefaults key for whether the lyrics panel is enabled.
    public static let storageKey = "musicLyricsEnabled"
    /// Lyrics are on by default.
    public static let defaultEnabled = true
}

/// User control over the translucent "liquid glass" surfaces (cards, menus,
/// overlays). A tri-state because the app sits on top of the tvOS Accessibility
/// "Reduce Transparency" setting: the user can follow the system, force glass
/// on, or force solid surfaces. A **per-profile** display preference (each
/// profile keeps its own choice) like `AppTheme` / `CardStyle`: persisted via
/// `TransparencyPreferenceStore` (namespace-scoped) and rebuilt on profile
/// switch. Its `.system` option still defers to the device Accessibility setting,
/// so a viewer who needs reduced transparency system-wide always gets it.
public enum TransparencyPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Follow the tvOS Accessibility "Reduce Transparency" setting.
    case system
    /// Always show the translucent liquid-glass surfaces.
    case on
    /// Always use solid surfaces (reduced transparency).
    case off

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "tvOS Default"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    /// SF Symbol shown next to the option in Settings.
    public var symbolName: String {
        switch self {
        case .system: return "gearshape.fill"
        case .on: return "sparkles"
        case .off: return "square.fill"
        }
    }

    /// One-line explanation of what each option does, shown live under the
    /// tri-toggle as focus moves across it (mirrors `SkipIntrosMode.detail`).
    public var detail: String {
        switch self {
        case .system: return "Follow the tvOS “Reduce Transparency” accessibility setting."
        case .on: return "Always use translucent liquid-glass panels and cards."
        case .off: return "Always use solid backgrounds — no translucency."
        }
    }

    public static let `default`: TransparencyPreference = .system

    /// Persistence key base shared by RootView (reads the model to drive the
    /// environment) and Settings (writes it). Per-profile: the default profile
    /// reuses this un-suffixed key; other profiles namespace it via
    /// `SettingsKey.scoped`.
    public static let storageKey = "transparencyPreference"

    /// Whether liquid-glass surfaces should render SOLID (reduced transparency),
    /// resolving this preference against the current tvOS Accessibility setting.
    /// `on` forces glass even when the system asks to reduce it — an explicit,
    /// in-app override the user opted into.
    public func reducesTransparency(systemReduceTransparency: Bool) -> Bool {
        switch self {
        case .system: return systemReduceTransparency
        case .on: return false
        case .off: return true
        }
    }
}
