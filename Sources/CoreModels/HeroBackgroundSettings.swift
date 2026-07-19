import Foundation

/// The single per-profile choice for what plays behind the hero (Home carousel
/// and detail page). Modeled as one mode so **theme music and autoplay trailers
/// are mutually exclusive by construction** — it is structurally impossible to
/// enable both, which is the arbitration the UI needs.
public enum HeroBackgroundMode: String, Codable, CaseIterable, Sendable {
    /// Static hero artwork only (today's classic behavior).
    case off
    /// Autoplay the item's trailer behind the hero (fast/local sources; see
    /// ``HeroBackgroundSettings/trailerMuted`` for audio).
    case trailer
    /// Play the item's theme music softly on the detail page (no trailer).
    case themeMusic

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .trailer: "Trailer"
        case .themeMusic: "Theme music"
        }
    }

    public var detail: String {
        switch self {
        case .off: "Show static hero artwork only."
        case .trailer: "Play the trailer behind the hero, then move to the next title."
        case .themeMusic: "Play a title's theme music while you browse its detail page."
        }
    }
}

/// Per-profile hero background preferences: which background mode is active and,
/// for the trailer mode, whether its audio is muted.
///
/// Lenient decode (per-field fallbacks) so adding a field later reads an older
/// persisted blob as "that field at its default" instead of failing the decode.
public struct HeroBackgroundSettings: Codable, Equatable, Sendable {
    /// What plays behind the hero. Trailer autoplay is the default (muted), per
    /// the product intent that the feature is on out of the box; it degrades
    /// gracefully to static artwork when no fast trailer is available.
    public var mode: HeroBackgroundMode
    /// Whether an autoplaying trailer is muted. Default `true` — trailer sound is
    /// opt-in, so the hero never blares audio unexpectedly.
    public var trailerMuted: Bool

    public init(
        mode: HeroBackgroundMode = .trailer,
        trailerMuted: Bool = true
    ) {
        self.mode = mode
        self.trailerMuted = trailerMuted
    }

    public static let `default` = HeroBackgroundSettings()

    /// Whether autoplay trailers should run for this profile.
    public var trailerAutoplayEnabled: Bool { mode == .trailer }

    /// Whether theme music should play for this profile.
    public var themeMusicEnabled: Bool { mode == .themeMusic }

    private enum CodingKeys: String, CodingKey {
        case mode, trailerMuted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HeroBackgroundSettings.default
        if let token = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil {
            mode = HeroBackgroundMode(rawValue: token) ?? d.mode
        } else {
            mode = d.mode
        }
        trailerMuted = ((try? c.decodeIfPresent(Bool.self, forKey: .trailerMuted)) ?? nil) ?? d.trailerMuted
    }
}

// MARK: - Persistence

/// Persists ``HeroBackgroundSettings`` per profile, mirroring the theme-music and
/// hero-settings stores: the primary profile keeps an un-suffixed key so upgrading
/// installs inherit cleanly; additional profiles pass their namespace.
public protocol HeroBackgroundSettingsStoring: Sendable {
    func load() -> HeroBackgroundSettings
    func save(_ settings: HeroBackgroundSettings)
}

public final class HeroBackgroundSettingsStore: HeroBackgroundSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let legacyThemeMusicKey: String

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.heroBackgroundSettings", namespace: namespace)
        self.legacyThemeMusicKey = SettingsKey.scoped(
            "com.plozz.themeMusicSettings",
            namespace: namespace
        )
    }

    public func load() -> HeroBackgroundSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(HeroBackgroundSettings.self, from: data)
        else {
            // One-time upgrade migration: preserve a profile that already opted
            // into theme music instead of silently switching it to the new
            // default (muted trailer).
            if let legacyData = defaults.data(forKey: legacyThemeMusicKey),
               let legacy = try? JSONDecoder().decode(
                   ThemeMusicSettings.self,
                   from: legacyData
               ),
               legacy.isEnabled {
                return HeroBackgroundSettings(mode: .themeMusic)
            }
            return .default
        }
        return decoded
    }

    public func save(_ settings: HeroBackgroundSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// In-memory store for tests and previews.
public final class InMemoryHeroBackgroundSettingsStore: HeroBackgroundSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: HeroBackgroundSettings

    public init(_ initial: HeroBackgroundSettings = .default) {
        self.settings = initial
    }

    public func load() -> HeroBackgroundSettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    public func save(_ settings: HeroBackgroundSettings) {
        lock.lock(); defer { lock.unlock() }
        self.settings = settings
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have the
/// change persisted + broadcast. Mirrors `ThemeMusicSettingsModel`.
@MainActor
@Observable
public final class HeroBackgroundSettingsModel {
    public var settings: HeroBackgroundSettings {
        didSet { store.save(settings) }
    }

    private let store: HeroBackgroundSettingsStoring

    public init(store: HeroBackgroundSettingsStoring = HeroBackgroundSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }
}
