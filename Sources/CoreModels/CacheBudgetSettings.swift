import Foundation
import Observation

/// User-adjustable byte budgets for the metadata subsystem's on-device caches.
///
/// Two independent caches carry a size budget:
///   * the **derived artwork** cache (right-sized image derivatives of direct-share
///     artwork — `CoreUI.LocalArtworkDerivedCache`, whose build hard-cap is 64 MiB), and
///   * the **resolved-URL metadata** cache (the small JSON of resolved artwork URLs
///     and remembered negatives — `MetadataKit.MetadataDiskCache`, build default 16 MiB).
///
/// The values here are *budgets the user chose*; `AppShell` applies them to the live
/// actors at composition time (and whenever they change) via `setByteCap`/`setMaxBytes`,
/// each of which runs an immediate eviction pass so a lowered budget takes effect at
/// once. All values are clamped to sane bounds on `init`/decode so a corrupt or
/// out-of-range persisted blob can never starve or unbound a cache.
public struct CacheBudgetSettings: Codable, Equatable, Sendable {
    /// Byte budget for the derived-artwork cache. Clamped to
    /// [``artworkBounds``]. Default matches the build hard-cap (64 MiB).
    public var artworkCacheBytes: Int

    /// Byte budget for the resolved-URL metadata cache. Clamped to
    /// [``metadataBounds``]. Default matches the build default (16 MiB).
    public var metadataCacheBytes: Int

    /// Inclusive [min, max] the artwork budget is clamped to: 16 MiB … 256 MiB.
    public static let artworkBounds = 16 * 1024 * 1024 ... 256 * 1024 * 1024
    /// Inclusive [min, max] the metadata-URL budget is clamped to: 4 MiB … 64 MiB.
    public static let metadataBounds = 4 * 1024 * 1024 ... 64 * 1024 * 1024

    public static let defaultArtworkCacheBytes = 64 * 1024 * 1024
    public static let defaultMetadataCacheBytes = 16 * 1024 * 1024

    public init(
        artworkCacheBytes: Int = CacheBudgetSettings.defaultArtworkCacheBytes,
        metadataCacheBytes: Int = CacheBudgetSettings.defaultMetadataCacheBytes
    ) {
        self.artworkCacheBytes = Self.artworkBounds.clamping(artworkCacheBytes)
        self.metadataCacheBytes = Self.metadataBounds.clamping(metadataCacheBytes)
    }

    public static let `default` = CacheBudgetSettings()

    private enum CodingKeys: String, CodingKey {
        case artworkCacheBytes, metadataCacheBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let artwork = try container.decodeIfPresent(Int.self, forKey: .artworkCacheBytes)
            ?? Self.defaultArtworkCacheBytes
        let metadata = try container.decodeIfPresent(Int.self, forKey: .metadataCacheBytes)
            ?? Self.defaultMetadataCacheBytes
        self.artworkCacheBytes = Self.artworkBounds.clamping(artwork)
        self.metadataCacheBytes = Self.metadataBounds.clamping(metadata)
    }
}

private extension ClosedRange where Bound == Int {
    /// Clamps `value` into the range (returns `lowerBound`/`upperBound` when outside).
    func clamping(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

/// Persists `CacheBudgetSettings` across launches. Cache budgets are a device-wide
/// concern (a cache and its bytes are shared, not per-profile), so this store uses a
/// single un-namespaced key regardless of the active profile.
public protocol CacheBudgetSettingsStoring: Sendable {
    func load() -> CacheBudgetSettings
    func save(_ settings: CacheBudgetSettings)
}

public final class CacheBudgetSettingsStore: CacheBudgetSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.plozz.cacheBudgetSettings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> CacheBudgetSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(CacheBudgetSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: CacheBudgetSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Observable wrapper so a Settings screen can two-way bind the cache budgets and
/// have changes persisted. The caller observes `settings` and forwards changes to
/// the live cache actors (see `AppShell`).
@MainActor
@Observable
public final class CacheBudgetSettingsModel {
    public var settings: CacheBudgetSettings {
        didSet { store.save(settings) }
    }

    private let store: CacheBudgetSettingsStoring

    public init(store: CacheBudgetSettingsStoring = CacheBudgetSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }

    public func resetToDefaults() {
        settings = .default
    }
}
