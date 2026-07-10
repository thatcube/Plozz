import Foundation
import Observation

/// Persists the selected `TransparencyPreference` across launches in standard
/// `UserDefaults`.
///
/// Mirrors `CardStyleSettingsStore` exactly. The preference is stored **per
/// profile** (key `transparencyPreference`, scoped by namespace); the primary
/// profile keeps the legacy un-suffixed key so existing installs upgrade cleanly
/// and inherit the choice they already made while it was an app-wide setting.
public protocol TransparencyPreferenceStoring: Sendable {
    func load() -> TransparencyPreference
    func save(_ preference: TransparencyPreference)
}

public final class TransparencyPreferenceStore: TransparencyPreferenceStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key (`TransparencyPreference.storageKey`);
    ///   other profiles pass their `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped(TransparencyPreference.storageKey, namespace: namespace)
    }

    public func load() -> TransparencyPreference {
        guard let raw = defaults.string(forKey: key),
              let preference = TransparencyPreference(rawValue: raw) else {
            return .default
        }
        return preference
    }

    public func save(_ preference: TransparencyPreference) {
        defaults.set(preference.rawValue, forKey: key)
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have the
/// chosen transparency preference persisted + broadcast to the view tree.
/// Mirrors `CardStyleSettingsModel`.
@MainActor
@Observable
public final class TransparencyPreferenceModel {
    public var preference: TransparencyPreference {
        didSet { store.save(preference) }
    }

    private let store: TransparencyPreferenceStoring

    public init(store: TransparencyPreferenceStoring = TransparencyPreferenceStore()) {
        self.store = store
        self.preference = store.load()
    }
}
