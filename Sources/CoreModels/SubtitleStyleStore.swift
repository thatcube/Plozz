import Foundation
import Observation

/// The persisted appearance envelope: a global `base` style plus a
/// (currently-empty) per-content-type `overrides` map. Persisting the container
/// shape *now* — rather than a bare `SubtitleStyle` — is deliberate: it makes
/// per-content-type appearance a **zero-migration** drop-in later (start writing
/// `overrides` entries; existing blobs already decode the empty map).
public struct SubtitleStylePreferences: Codable, Equatable, Sendable {
    /// The profile-wide appearance, applied to any category without an override.
    public var base: SubtitleStyle
    /// Per-content-type appearance overrides. Empty today (global-only); a present
    /// entry replaces `base` whole for that category.
    public var overrides: [SubtitleContentCategory: SubtitleStyle]

    public init(base: SubtitleStyle = .default,
                overrides: [SubtitleContentCategory: SubtitleStyle] = [:]) {
        self.base = base
        self.overrides = overrides
    }

    /// The appearance for a category: its override if present, else the base.
    public func resolved(for category: SubtitleContentCategory) -> SubtitleStyle {
        overrides[category] ?? base
    }

    public static let `default` = SubtitleStylePreferences()

    private enum CodingKeys: String, CodingKey { case base, overrides }

    /// Tolerant decode so a blob written before `overrides` existed (or with a
    /// missing `base`) still decodes — each missing key falling back to default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.base = try c.decodeIfPresent(SubtitleStyle.self, forKey: .base) ?? .default
        self.overrides = try c.decodeIfPresent([SubtitleContentCategory: SubtitleStyle].self, forKey: .overrides) ?? [:]
    }
}

/// Persists subtitle **appearance** (`SubtitleStyle`) per profile. The appearance
/// half extracted from the retired `CaptionSettingsStore`, and the source of
/// truth that drives the live renderer (`liveSubtitles.style`).
public protocol SubtitleStyleStoring: Sendable {
    func load() -> SubtitleStylePreferences
    func save(_ preferences: SubtitleStylePreferences)
}

public final class SubtitleStyleStore: SubtitleStyleStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let namespace: String?

    /// The `UserDefaults` base key subtitle appearance persists under.
    public static let storageKey = "com.plozz.subtitleStyle"

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the un-suffixed key; other profiles pass their `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.namespace = namespace
        self.key = SettingsKey.scoped(Self.storageKey, namespace: namespace)
        migrateFromLegacyIfNeeded()
    }

    public func load() -> SubtitleStylePreferences {
        guard let data = defaults.data(forKey: key),
              let prefs = try? JSONDecoder().decode(SubtitleStylePreferences.self, from: data) else {
            return .default
        }
        return prefs
    }

    public func save(_ preferences: SubtitleStylePreferences) {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: key)
        }
    }

    /// One-time seed from the retired `CaptionSettings` blob: if this profile has
    /// no persisted appearance yet but did save the old combined model, adopt its
    /// look (size / colour / background / edge / follow-system) as the base.
    private func migrateFromLegacyIfNeeded() {
        guard defaults.data(forKey: key) == nil,
              let legacy = LegacyCaptionSettings.load(from: defaults, namespace: namespace) else {
            return
        }
        save(SubtitleStylePreferences(base: SubtitleStyle(from: legacy)))
    }
}

// MARK: - Observable model

/// Observable wrapper so the settings screen / in-player editor can two-way bind
/// the subtitle appearance and have changes persisted + broadcast to the live
/// renderer. `style` is the global base; `overrides` is the future per-category
/// seam (empty today).
@MainActor
@Observable
public final class SubtitleStyleModel {
    /// The profile-wide appearance (the base). Two-way bindable; edits persist and
    /// flow to any active player via the live overlay.
    public var style: SubtitleStyle {
        didSet { persist() }
    }
    /// Per-content-type overrides. Empty today; persisted alongside `style` so
    /// adding per-category editing later needs no store change.
    public private(set) var overrides: [SubtitleContentCategory: SubtitleStyle] {
        didSet { persist() }
    }

    private let store: SubtitleStyleStoring

    public init(store: SubtitleStyleStoring = SubtitleStyleStore()) {
        self.store = store
        let prefs = store.load()
        self.style = prefs.base
        self.overrides = prefs.overrides
    }

    /// The appearance to render for a content category: its override if present,
    /// else the global base. Today always the base (overrides empty).
    public func resolved(for category: SubtitleContentCategory) -> SubtitleStyle {
        overrides[category] ?? style
    }

    private func persist() {
        store.save(SubtitleStylePreferences(base: style, overrides: overrides))
    }
}
