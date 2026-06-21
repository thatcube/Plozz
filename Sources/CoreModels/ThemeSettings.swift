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
