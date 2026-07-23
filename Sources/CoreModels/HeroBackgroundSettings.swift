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
        case .trailer: "Play the title's trailer behind the hero."
        case .themeMusic: "Play a title's theme music while you browse its detail page."
        }
    }
}

/// Per-profile hero background preferences, split by surface:
///  - the **Home** hero (carousel) can play a trailer behind the artwork;
///  - the **Detail** page hero can play a trailer OR the title's theme music
///    (mutually exclusive by construction — one `detailMode`).
/// Each surface owns its own mute *default* (`homeTrailerMuted`/`detailTrailerMuted`);
/// the in-hero mute button is a transient session override that never writes these.
///
/// Lenient decode with a migration from the legacy single-mode shape (`mode` +
/// `trailerMuted`): the old mode maps to the detail page (theme music was always
/// detail-only), and the home trailer inherits whether the old mode was `.trailer`.
public struct HeroBackgroundSettings: Codable, Equatable, Sendable {
    /// Whether a trailer autoplays behind the HOME hero. Default `true`.
    public var homeTrailerEnabled: Bool
    /// Mute *default* for the home hero's trailer. Default `true`.
    public var homeTrailerMuted: Bool
    /// What plays behind the DETAIL page hero (static / trailer / theme music).
    public var detailMode: HeroBackgroundMode
    /// Mute *default* for the detail hero's trailer. Default `true`.
    public var detailTrailerMuted: Bool

    public init(
        homeTrailerEnabled: Bool = true,
        homeTrailerMuted: Bool = true,
        detailMode: HeroBackgroundMode = .trailer,
        detailTrailerMuted: Bool = true
    ) {
        self.homeTrailerEnabled = homeTrailerEnabled
        self.homeTrailerMuted = homeTrailerMuted
        self.detailMode = detailMode
        self.detailTrailerMuted = detailTrailerMuted
    }

    public static let `default` = HeroBackgroundSettings()

    /// Whether the DETAIL page should play theme music.
    public var themeMusicEnabled: Bool { detailMode == .themeMusic }
    /// Whether the DETAIL page should autoplay a trailer.
    public var detailTrailerEnabled: Bool { detailMode == .trailer }

    private enum CodingKeys: String, CodingKey {
        // New per-surface keys.
        case homeTrailerEnabled, homeTrailerMuted, detailMode, detailTrailerMuted
        // Legacy single-mode keys (read for migration only).
        case mode, trailerMuted
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(homeTrailerEnabled, forKey: .homeTrailerEnabled)
        try c.encode(homeTrailerMuted, forKey: .homeTrailerMuted)
        try c.encode(detailMode, forKey: .detailMode)
        try c.encode(detailTrailerMuted, forKey: .detailTrailerMuted)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HeroBackgroundSettings.default
        // Legacy single-mode values (present only in a pre-split persisted blob).
        let legacyMode = ((try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil)
            .flatMap { HeroBackgroundMode(rawValue: $0) }
        let legacyMuted = (try? c.decodeIfPresent(Bool.self, forKey: .trailerMuted)) ?? nil

        homeTrailerEnabled = ((try? c.decodeIfPresent(Bool.self, forKey: .homeTrailerEnabled)) ?? nil)
            ?? legacyMode.map { $0 == .trailer } ?? d.homeTrailerEnabled
        homeTrailerMuted = ((try? c.decodeIfPresent(Bool.self, forKey: .homeTrailerMuted)) ?? nil)
            ?? legacyMuted ?? d.homeTrailerMuted
        detailMode = ((try? c.decodeIfPresent(String.self, forKey: .detailMode)) ?? nil)
            .flatMap { HeroBackgroundMode(rawValue: $0) }
            ?? legacyMode ?? d.detailMode
        detailTrailerMuted = ((try? c.decodeIfPresent(Bool.self, forKey: .detailTrailerMuted)) ?? nil)
            ?? legacyMuted ?? d.detailTrailerMuted
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
                return HeroBackgroundSettings(detailMode: .themeMusic)
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
