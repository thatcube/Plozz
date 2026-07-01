import Foundation
import Observation

/// Persists `SubtitleBehavior` (subtitle mode / preferred language / auto-download)
/// per profile. The behaviour half of the retired `CaptionSettingsStore`.
public protocol SubtitleBehaviorStoring: Sendable {
    func load() -> SubtitleBehavior
    func save(_ behavior: SubtitleBehavior)
}

public final class SubtitleBehaviorStore: SubtitleBehaviorStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let namespace: String?

    /// The `UserDefaults` base key subtitle behaviour persists under.
    public static let storageKey = "com.plozz.subtitleBehavior"

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the un-suffixed key; other profiles pass their `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.namespace = namespace
        self.key = SettingsKey.scoped(Self.storageKey, namespace: namespace)
        migrateFromLegacyIfNeeded()
    }

    public func load() -> SubtitleBehavior {
        guard let data = defaults.data(forKey: key),
              let behavior = try? JSONDecoder().decode(SubtitleBehavior.self, from: data) else {
            return .default
        }
        return behavior
    }

    public func save(_ behavior: SubtitleBehavior) {
        if let data = try? JSONEncoder().encode(behavior) {
            defaults.set(data, forKey: key)
        }
    }

    /// One-time seed from the retired `CaptionSettings` blob: if this profile has
    /// no persisted behaviour yet but did save the old combined model, adopt its
    /// mode / language / auto-download. The legacy blob is left in place (harmless
    /// orphan) so the parallel `SubtitleStyleStore` migration can read it too.
    private func migrateFromLegacyIfNeeded() {
        guard defaults.data(forKey: key) == nil,
              let legacy = LegacyCaptionSettings.load(from: defaults, namespace: namespace) else {
            return
        }
        save(SubtitleBehavior(from: legacy))
    }
}

// MARK: - Observable model

/// Observable wrapper so SwiftUI settings screens can two-way bind subtitle
/// behaviour and have changes persisted. Mirrors the other per-profile models.
@MainActor
@Observable
public final class SubtitleBehaviorModel {
    public var settings: SubtitleBehavior {
        didSet { store.save(settings) }
    }

    private let store: SubtitleBehaviorStoring

    public init(store: SubtitleBehaviorStoring = SubtitleBehaviorStore()) {
        self.store = store
        self.settings = store.load()
    }
}
