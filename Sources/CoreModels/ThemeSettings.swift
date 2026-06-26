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
    /// A soft, dark gray theme.
    case dark
    /// A pure-black theme tuned for OLED panels.
    case oled
    /// A light theme.
    case light

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .oled: return "OLED"
        case .light: return "Light"
        }
    }

    /// SF Symbol shown next to the option in Settings.
    public var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon.fill"
        case .oled: return "moon.stars.fill"
        case .light: return "sun.max.fill"
        }
    }

    public static let `default`: AppTheme = .system
}

/// How the full-screen music player paints its background and text. Independent
/// of `AppTheme`: the player can follow the app theme or be pinned to one of its
/// own looks, because its immersive, artwork-tinted background reads differently
/// from the browsing chrome. Persisted locally via `@AppStorage`.
public enum MusicPlayerAppearance: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Follow the app theme: a light theme gives the frosted-light player, any
    /// dark theme gives the vibrant-dark player.
    case matchTheme
    /// Always the vibrant, artwork-tinted dark look.
    case dark
    /// Always a frosted, lightly artwork-tinted light look.
    case light
    /// Always true black, with the artwork colors as subtle accents (OLED).
    case oled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .matchTheme: return "Match Theme"
        case .dark: return "Vibrant Dark"
        case .light: return "Frosted Light"
        case .oled: return "OLED Black"
        }
    }

    /// SF Symbol shown next to the option in Settings.
    public var symbolName: String {
        switch self {
        case .matchTheme: return "circle.lefthalf.filled"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .oled: return "moon.stars.fill"
        }
    }

    public static let `default`: MusicPlayerAppearance = .matchTheme

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
