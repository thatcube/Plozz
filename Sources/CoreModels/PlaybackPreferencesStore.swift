import Foundation

/// Persists tiny, cross-session player preferences that are too small to belong
/// in any feature model — currently just the last-used playback speed, so the
/// viewer who watches everything at 1.25× doesn't have to reset it per episode.
///
/// Per-stream tunables (audio/subtitle delay, dialog-enhance) are intentionally
/// NOT persisted globally: those are content-specific and surprising to carry
/// across files. They reset on every `load`.
public protocol PlaybackPreferencesStoring: Sendable {
    func loadPlaybackSpeed() -> Double
    func savePlaybackSpeed(_ speed: Double)
    func loadLocalRemuxStrategyID() -> String
    func saveLocalRemuxStrategyID(_ strategyID: String)
}

public final class PlaybackPreferencesStore: PlaybackPreferencesStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let speedKey: String
    private let localRemuxStrategyKey: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key; other profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.speedKey = SettingsKey.scoped("com.plozz.playback.speed", namespace: namespace)
        self.localRemuxStrategyKey = SettingsKey.scoped("com.plozz.playback.localRemuxStrategy", namespace: namespace)
    }

    public func loadPlaybackSpeed() -> Double {
        let raw = defaults.object(forKey: speedKey) as? Double ?? 1.0
        return max(0.25, min(4.0, raw))
    }

    public func savePlaybackSpeed(_ speed: Double) {
        let clamped = max(0.25, min(4.0, speed))
        defaults.set(clamped, forKey: speedKey)
    }

    public func loadLocalRemuxStrategyID() -> String {
        let raw = defaults.string(forKey: localRemuxStrategyKey) ?? LocalRemuxStrategyChoice.disabledID
        return LocalRemuxStrategyChoice.choice(for: raw).id
    }

    public func saveLocalRemuxStrategyID(_ strategyID: String) {
        defaults.set(LocalRemuxStrategyChoice.choice(for: strategyID).id, forKey: localRemuxStrategyKey)
    }
}
