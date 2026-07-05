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
    /// A pure-black theme tuned for OLED panels.
    case oled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .oled: return "OLED"
        }
    }

    /// SF Symbol shown next to the option in Settings.
    public var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .oled: return "moon.stars.fill"
        }
    }

    /// One-line explanation of each look, shown under the option in the
    /// onboarding theme picker (and available to Settings).
    public var detail: String {
        switch self {
        case .system: return "Follows your Apple TV — light by day, dark after dark."
        case .light: return "Bright and breezy, made for sun-filled rooms."
        case .dark: return "Cozy and low-glare — our pick for movie night."
        case .oled: return "Deep, inky blacks that make colors pop."
        }
    }

    /// Fresh installs default to Dark, regardless of the device appearance —
    /// dark/OLED read best for a lean-back media app. Users can still pick any
    /// look during onboarding or later in Settings.
    public static let `default`: AppTheme = .dark
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
    /// Always true black, with the artwork colors as subtle accents (OLED).
    case oled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .matchTheme: return "Match Theme"
        case .light: return "Light"
        case .dark: return "Dark"
        case .oled: return "OLED"
        }
    }

    /// SF Symbol shown next to the option in Settings.
    public var symbolName: String {
        switch self {
        case .matchTheme: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
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

/// User control over the translucent "liquid glass" surfaces (cards, menus,
/// overlays). A tri-state because the app sits on top of the tvOS Accessibility
/// "Reduce Transparency" setting: the user can follow the system, force glass
/// on, or force solid surfaces. Deliberately an APP-WIDE (global) setting — a
/// visual-comfort/accessibility preference that belongs to the household, not a
/// single profile. See AGENTS.local.md ("Per-profile vs app-wide settings").
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

    /// AppStorage key shared by RootView (reads it to drive the environment) and
    /// Settings (writes it).
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
