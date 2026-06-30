import Foundation
import Observation

/// Per-profile persistence of the audio policy's per-content-type overrides, the
/// audio counterpart to `SubtitlePolicyStore`. Only the *overrides* are stored;
/// the base preference is derived live from the profile's `PlaybackSettings`
/// (via `AudioPolicy.inheriting(from:)`) so the two can never drift. An empty
/// store means "inherit everywhere", i.e. today's single global behaviour.
public protocol AudioPolicyStoring: Sendable {
    /// The persisted per-content-type overrides (empty when none set).
    func overrides() -> [ContentCategory: AudioLanguagePreference]
    /// Replace the whole override map (used when adopting/clearing the seed).
    func setOverrides(_ overrides: [ContentCategory: AudioLanguagePreference])
    /// Set or clear (`nil`) the override for one category.
    func setPreference(_ preference: AudioLanguagePreference?, for category: ContentCategory)
}

public extension AudioPolicyStoring {
    /// The fully-resolved policy for a profile: base mirrors `settings`, overrides
    /// come from this store. Resolving it for any category yields exactly today's
    /// behaviour when no overrides are set.
    func resolvedPolicy(settings: PlaybackSettings) -> AudioPolicy {
        AudioPolicy.resolved(base: settings.audioLanguagePreference, overrides: overrides())
    }
}

public final class AudioPolicyStore: AudioPolicyStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the un-suffixed key; other profiles pass their
    ///   `Profile.id`, mirroring the other settings stores.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.audioPolicyOverrides", namespace: namespace)
    }

    public func overrides() -> [ContentCategory: AudioLanguagePreference] {
        lock.lock()
        defer { lock.unlock() }
        return loadAll()
    }

    public func setOverrides(_ overrides: [ContentCategory: AudioLanguagePreference]) {
        lock.lock()
        defer { lock.unlock() }
        saveAll(overrides)
    }

    public func setPreference(_ preference: AudioLanguagePreference?, for category: ContentCategory) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadAll()
        all[category] = preference
        saveAll(all)
    }

    // MARK: - Private

    private func loadAll() -> [ContentCategory: AudioLanguagePreference] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([ContentCategory: AudioLanguagePreference].self, from: data) else {
            return [:]
        }
        return map
    }

    private func saveAll(_ map: [ContentCategory: AudioLanguagePreference]) {
        if map.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Observable model

/// Observable wrapper so SwiftUI settings screens can two-way bind the
/// per-content-type audio overrides and have changes persisted. Mirrors
/// `SubtitlePolicyModel`. The profile base preference still lives in
/// `PlaybackSettings`; this only owns the *overrides*, so the two can never drift.
@MainActor
@Observable
public final class AudioPolicyModel {
    /// Per-content-type overrides. An empty map means "inherit the profile base
    /// everywhere" — exactly today's single global behaviour.
    public var overrides: [ContentCategory: AudioLanguagePreference] {
        didSet { store.setOverrides(overrides) }
    }

    private let store: any AudioPolicyStoring

    public init(store: any AudioPolicyStoring = AudioPolicyStore()) {
        self.store = store
        self.overrides = store.overrides()
    }

    /// The fully-resolved policy for the current profile: base mirrors `settings`,
    /// overrides come from this model. Fed into the player at load time.
    public func resolvedPolicy(settings: PlaybackSettings) -> AudioPolicy {
        AudioPolicy.resolved(base: settings.audioLanguagePreference, overrides: overrides)
    }
}
