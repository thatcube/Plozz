import Foundation
import Observation

/// A user-facing enablement/prominence choice for a metadata source.
///
/// This deliberately mirrors MetadataKit's `ProviderRole` **by raw value**
/// (`primary` / `secondary` / `disabled`) so `CoreModels` — the leaf module that
/// owns persistence and cannot import `MetadataKit` — can record a user's override
/// without a layering violation. `MetadataEnrichmentConfig.merged(withUserOverrides:)`
/// maps these back onto the real `ProviderRole` at composition time.
public enum MetadataProviderState: String, Codable, Sendable, CaseIterable {
    /// Consulted ahead of `secondary` sources for the same field.
    case primary
    /// Consulted only after every `primary` source for the same field.
    case secondary
    /// Removed from the running set entirely.
    case disabled
}

/// A persisted **user override** layered on top of the build's Info.plist provider
/// baseline (the Step 5 `MetadataEnrichmentConfig`).
///
/// Scope note: the ``MetadataProviderSettingsStore`` below *supports* per-profile
/// namespacing, but the app wires a single instance **household-global** (app-wide,
/// un-namespaced) — see `AppState.metadataProviderSettingsModel` — because a share and
/// its scan are household-global, so provider ordering/roles are too. Keep this in mind
/// before assuming per-profile behavior.
///
/// It is intentionally *sparse*: an empty value means "use the build defaults
/// unchanged", and any source not named here inherits its baseline role and
/// position. This is what lets the merge preserve the Info.plist baseline where the
/// user hasn't overridden, and lets "reset to build defaults" be a single
/// assignment back to ``default``.
///
/// Roles and order are stored keyed by `MetadataSource.rawValue` (a plain string)
/// rather than by `MetadataSource`, so the persisted JSON is a stable, readable
/// object — and so records written by a newer build that knows a source this build
/// doesn't decode without loss.
public struct MetadataProviderSettings: Codable, Equatable, Sendable {
    /// Per-source role overrides, keyed by `MetadataSource.rawValue`. A source
    /// absent from the map inherits the build baseline's role for it.
    public var roleOverrides: [String: MetadataProviderState]

    /// The user's explicit source ordering, as `MetadataSource.rawValue`s. Empty
    /// means "inherit the baseline order". Sources the user omitted keep their
    /// baseline position, appended after the user-ordered ones (so a new provider a
    /// later build adds is never silently dropped from an older saved order).
    public var order: [String]

    public init(
        roleOverrides: [String: MetadataProviderState] = [:],
        order: [String] = []
    ) {
        self.roleOverrides = roleOverrides
        self.order = order
    }

    /// Whether this override is empty — i.e. the merge is a no-op and the running
    /// config equals the pure Info.plist baseline.
    public var isEmpty: Bool { roleOverrides.isEmpty && order.isEmpty }

    /// The user's role override for `source`, or `nil` when it inherits the baseline.
    public func role(for source: MetadataSource) -> MetadataProviderState? {
        roleOverrides[source.rawValue]
    }

    /// Sets (or clears, when `role` is `nil`) the user's role override for `source`.
    public mutating func setRole(_ role: MetadataProviderState?, for source: MetadataSource) {
        if let role {
            roleOverrides[source.rawValue] = role
        } else {
            roleOverrides.removeValue(forKey: source.rawValue)
        }
    }

    /// Replaces the explicit ordering with `sources` (typed convenience).
    public mutating func setOrder(_ sources: [MetadataSource]) {
        order = sources.map(\.rawValue)
    }

    /// The build-default (empty) override — the "reset to build defaults" value.
    public static let `default` = MetadataProviderSettings()

    private enum CodingKeys: String, CodingKey {
        case roleOverrides, order
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // decodeIfPresent so a blob written before a field existed decodes to its
        // default instead of failing the whole decode.
        roleOverrides = try container.decodeIfPresent(
            [String: MetadataProviderState].self, forKey: .roleOverrides
        ) ?? [:]
        order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
    }
}

/// Persists `MetadataProviderSettings` across launches, per profile — mirrors
/// ``DiagnosticsSettingsStore`` exactly so the Settings screens use one pattern.
public protocol MetadataProviderSettingsStoring: Sendable {
    func load() -> MetadataProviderSettings
    func save(_ settings: MetadataProviderSettings)
}

public final class MetadataProviderSettingsStore: MetadataProviderSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key; other profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.metadataProviderSettings", namespace: namespace)
    }

    public func load() -> MetadataProviderSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(MetadataProviderSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: MetadataProviderSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Observable wrapper so a Settings screen can two-way bind the provider override
/// and have changes persisted immediately (the runtime pipeline picks the new
/// override up on its next composition — see `AppShell`).
@MainActor
@Observable
public final class MetadataProviderSettingsModel {
    public var settings: MetadataProviderSettings {
        didSet { store.save(settings) }
    }

    private let store: MetadataProviderSettingsStoring

    public init(store: MetadataProviderSettingsStoring = MetadataProviderSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }

    /// Resets the override back to the build defaults (empties it).
    public func resetToBuildDefaults() {
        settings = .default
    }
}
