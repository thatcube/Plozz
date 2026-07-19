import Foundation
import Observation

/// A persisted **user override** for metadata-source ordering + enablement, layered
/// on top of the build's Info.plist provider baseline (the Step 5
/// `MetadataEnrichmentConfig`).
///
/// The user-facing model is a **single ordered list with a "Disabled" divider**:
/// everything above the divider is enabled and shown in priority order (top = highest
/// priority); everything below is disabled. Position expresses **both** priority and
/// enabled/disabled — there is no separate role (Primary/Secondary/Off) any more.
///
/// This is stored as two ordered `MetadataSource.rawValue` lists so the persisted JSON
/// is stable and human-readable, and so a record written by a newer build that knows a
/// source this build doesn't still decodes without loss:
///   * ``enabledOrder`` — enabled sources, highest priority first (above the divider);
///   * ``disabledOrder`` — disabled sources, in order (below the divider).
///
/// Scope note: the ``MetadataProviderSettingsStore`` below *supports* per-profile
/// namespacing, but the app wires a single instance **household-global** (app-wide,
/// un-namespaced) — see `AppState.metadataProviderSettingsModel` — because a share and
/// its scan are household-global, so provider ordering/enablement is too.
///
/// It is intentionally *sparse*: an empty value means "use the build defaults
/// unchanged", and any source named in neither list inherits its baseline position and
/// enabled state. This is what lets the merge preserve the Info.plist baseline where the
/// user hasn't spoken, and lets "reset to build defaults" be a single assignment back to
/// ``default``.
public struct MetadataProviderSettings: Codable, Equatable, Sendable {
    /// Enabled sources, highest-priority first (above the divider), as
    /// `MetadataSource.rawValue`s. A source absent from both lists inherits the
    /// baseline's position + enabled state.
    public var enabledOrder: [String]

    /// Disabled sources, in order (below the divider), as `MetadataSource.rawValue`s.
    public var disabledOrder: [String]

    public init(
        enabledOrder: [String] = [],
        disabledOrder: [String] = []
    ) {
        self.enabledOrder = enabledOrder
        self.disabledOrder = disabledOrder
    }

    /// Whether this override is empty — i.e. the merge is a no-op and the running
    /// config equals the pure Info.plist baseline.
    public var isEmpty: Bool { enabledOrder.isEmpty && disabledOrder.isEmpty }

    /// Whether the user has explicitly disabled `source`.
    public func isDisabled(_ source: MetadataSource) -> Bool {
        disabledOrder.contains(source.rawValue)
    }

    /// Whether the user has explicitly placed `source` in the enabled list.
    public func isExplicitlyEnabled(_ source: MetadataSource) -> Bool {
        enabledOrder.contains(source.rawValue)
    }

    /// Replaces the enabled list with `sources` (typed convenience).
    public mutating func setEnabledOrder(_ sources: [MetadataSource]) {
        enabledOrder = sources.map(\.rawValue)
    }

    /// Replaces the disabled list with `sources` (typed convenience).
    public mutating func setDisabledOrder(_ sources: [MetadataSource]) {
        disabledOrder = sources.map(\.rawValue)
    }

    /// Replaces both lists at once (the single-list divider model: `enabled` above,
    /// `disabled` below).
    public mutating func setLists(enabled: [MetadataSource], disabled: [MetadataSource]) {
        enabledOrder = enabled.map(\.rawValue)
        disabledOrder = disabled.map(\.rawValue)
    }

    /// The build-default (empty) override — the "reset to build defaults" value.
    public static let `default` = MetadataProviderSettings()

    private enum CodingKeys: String, CodingKey {
        // Current schema.
        case enabledOrder, disabledOrder
        // Legacy Step-6 schema (role model) — decoded for one-way migration only.
        case roleOverrides, order
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabledOrder, forKey: .enabledOrder)
        try container.encode(disabledOrder, forKey: .disabledOrder)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Current schema. decodeIfPresent so a blob written before a field existed
        // decodes to its default instead of failing the whole decode.
        enabledOrder = try container.decodeIfPresent([String].self, forKey: .enabledOrder) ?? []
        disabledOrder = try container.decodeIfPresent([String].self, forKey: .disabledOrder) ?? []

        // One-way migration of the legacy Step-6 role blob ({roleOverrides, order}) —
        // only when this build finds no current-schema data (so a re-encode never keeps
        // re-migrating). previously .disabled -> disabled; .primary/.secondary ->
        // enabled at their persisted order position; an unknown role -> disabled (never
        // silently enabled).
        if enabledOrder.isEmpty, disabledOrder.isEmpty {
            let legacyRoles = try container.decodeIfPresent([String: String].self, forKey: .roleOverrides) ?? [:]
            if !legacyRoles.isEmpty {
                let legacyOrder = try container.decodeIfPresent([String].self, forKey: .order) ?? []
                (enabledOrder, disabledOrder) = Self.migrate(roleOverrides: legacyRoles, order: legacyOrder)
            }
        }
    }

    /// Deterministically maps a legacy role override map + explicit order onto the
    /// enabled/disabled lists. Disabled roles (and any unrecognized role — the safe
    /// direction) go below the divider; every other placed source stays enabled at its
    /// order position. Sources with a disabling role but no order entry are appended
    /// after the placed ones (by raw value, for stability).
    static func migrate(
        roleOverrides: [String: String],
        order: [String]
    ) -> (enabled: [String], disabled: [String]) {
        func isDisabledRole(_ raw: String) -> Bool {
            // "disabled" disables; unknown/foreign roles disable too (never silently
            // enable a source the user restricted).
            raw != "primary" && raw != "secondary"
        }

        var enabled: [String] = []
        var disabled: [String] = []
        var seen: Set<String> = []

        // Honor the user's explicit order first.
        for token in order where seen.insert(token).inserted {
            if let role = roleOverrides[token], isDisabledRole(role) {
                disabled.append(token)
            } else {
                enabled.append(token)
            }
        }
        // Any disabling role-only source (not in `order`) still needs recording so its
        // restriction survives the migration; deterministic by raw value. A
        // primary/secondary role with no order entry inherits the baseline (enabled at
        // its baseline position), so it needs no explicit list entry.
        for token in roleOverrides.keys.sorted() where seen.insert(token).inserted {
            if let role = roleOverrides[token], isDisabledRole(role) {
                disabled.append(token)
            }
        }
        return (enabled, disabled)
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
