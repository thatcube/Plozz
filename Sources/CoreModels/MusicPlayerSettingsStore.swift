import Foundation
import Observation

/// Persists the full-screen music player's preferences — its appearance
/// (`MusicPlayerAppearance`) and whether it shows the extra album/audio/lyrics
/// info — across launches in standard `UserDefaults`.
///
/// Mirrors `ThemeSettingsStore`: stored locally only, scoped per profile via
/// `SettingsKey.scoped`, so each household profile keeps its own player look and
/// "show extra info" choice instead of sharing one global setting. The primary
/// profile (`namespace == nil`) keeps the original un-suffixed keys
/// (`musicPlayerAppearance` / `musicShowTrackDetails`) so existing installs
/// inherit their current values with no migration.
public protocol MusicPlayerSettingsStoring: Sendable {
    func loadAppearance() -> MusicPlayerAppearance
    func saveAppearance(_ appearance: MusicPlayerAppearance)
    func loadShowTrackDetails() -> Bool
    func saveShowTrackDetails(_ show: Bool)
}

public final class MusicPlayerSettingsStore: MusicPlayerSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let appearanceKey: String
    private let showTrackDetailsKey: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed keys; other profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.appearanceKey = SettingsKey.scoped(MusicPlayerAppearance.storageKey, namespace: namespace)
        self.showTrackDetailsKey = SettingsKey.scoped("musicShowTrackDetails", namespace: namespace)
    }

    public func loadAppearance() -> MusicPlayerAppearance {
        guard let raw = defaults.string(forKey: appearanceKey),
              let appearance = MusicPlayerAppearance(rawValue: raw) else {
            return .default
        }
        return appearance
    }

    public func saveAppearance(_ appearance: MusicPlayerAppearance) {
        defaults.set(appearance.rawValue, forKey: appearanceKey)
    }

    public func loadShowTrackDetails() -> Bool {
        defaults.bool(forKey: showTrackDetailsKey)
    }

    public func saveShowTrackDetails(_ show: Bool) {
        defaults.set(show, forKey: showTrackDetailsKey)
    }
}

/// Observable wrapper so the Settings screen can two-way bind and the player can
/// read the chosen look + "show extra info" preference, persisted + broadcast to
/// the view tree. Mirrors `ThemeSettingsModel`.
@MainActor
@Observable
public final class MusicPlayerSettingsModel {
    public var appearance: MusicPlayerAppearance {
        didSet { store.saveAppearance(appearance) }
    }

    public var showTrackDetails: Bool {
        didSet { store.saveShowTrackDetails(showTrackDetails) }
    }

    private let store: MusicPlayerSettingsStoring

    public init(store: MusicPlayerSettingsStoring = MusicPlayerSettingsStore()) {
        self.store = store
        self.appearance = store.loadAppearance()
        self.showTrackDetails = store.loadShowTrackDetails()
    }
}
