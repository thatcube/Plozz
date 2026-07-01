import Foundation
import Observation

/// Per-profile persistence of the subtitle policy's per-content-type overrides
/// (design §5.0). Only the *overrides* are stored; the base rule is derived live
/// from the profile's `CaptionSettings` (via `SubtitlePolicy.inheriting(from:)`)
/// so the two can never drift. An empty store means "inherit everywhere", i.e.
/// today's single global behaviour.
public protocol SubtitlePolicyStoring: Sendable {
    /// The persisted per-content-type overrides (empty when none set).
    func overrides() -> [SubtitleContentCategory: SubtitlePolicy.Rule]
    /// Replace the whole override map (used when adopting/clearing the seed).
    func setOverrides(_ overrides: [SubtitleContentCategory: SubtitlePolicy.Rule])
    /// Set or clear (`nil`) the override for one category.
    func setRule(_ rule: SubtitlePolicy.Rule?, for category: SubtitleContentCategory)
}

public extension SubtitlePolicyStoring {
    /// The fully-resolved policy for a profile: base mirrors `behavior`, overrides
    /// come from this store. Resolving it for any category yields exactly today's
    /// behaviour when no overrides are set.
    func resolvedPolicy(behavior: SubtitleBehavior) -> SubtitlePolicy {
        SubtitlePolicy.resolved(behavior: behavior, overrides: overrides())
    }
}

public final class SubtitlePolicyStore: SubtitlePolicyStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the un-suffixed key; other profiles pass their
    ///   `Profile.id`, mirroring the other settings stores.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.subtitlePolicyOverrides", namespace: namespace)
    }

    public func overrides() -> [SubtitleContentCategory: SubtitlePolicy.Rule] {
        lock.lock()
        defer { lock.unlock() }
        return loadAll()
    }

    public func setOverrides(_ overrides: [SubtitleContentCategory: SubtitlePolicy.Rule]) {
        lock.lock()
        defer { lock.unlock() }
        saveAll(overrides)
    }

    public func setRule(_ rule: SubtitlePolicy.Rule?, for category: SubtitleContentCategory) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadAll()
        all[category] = rule
        saveAll(all)
    }

    // MARK: - Private

    private func loadAll() -> [SubtitleContentCategory: SubtitlePolicy.Rule] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([SubtitleContentCategory: SubtitlePolicy.Rule].self, from: data) else {
            return [:]
        }
        return map
    }

    private func saveAll(_ map: [SubtitleContentCategory: SubtitlePolicy.Rule]) {
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
/// per-content-type subtitle overrides and have changes persisted. Mirrors
/// `CaptionSettingsModel`/`PlaybackSettingsModel`. The profile base mode/language
/// still lives in `CaptionSettings`; this only owns the *overrides* (design §5.0),
/// so the two can never drift.
@MainActor
@Observable
public final class SubtitlePolicyModel {
    /// Per-content-type overrides. An empty map means "inherit the profile base
    /// everywhere" — exactly today's single global behaviour.
    public var overrides: [SubtitleContentCategory: SubtitlePolicy.Rule] {
        didSet { store.setOverrides(overrides) }
    }

    private let store: any SubtitlePolicyStoring

    public init(store: any SubtitlePolicyStoring = SubtitlePolicyStore()) {
        self.store = store
        self.overrides = store.overrides()
    }

    /// The fully-resolved policy for the current profile: base mirrors `behavior`,
    /// overrides come from this model. Fed into the player at load time.
    public func resolvedPolicy(behavior: SubtitleBehavior) -> SubtitlePolicy {
        SubtitlePolicy.resolved(behavior: behavior, overrides: overrides)
    }
}
