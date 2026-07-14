import Foundation
import Observation

/// Per-profile configuration for the Home **hero** carousel (pure data model).
///
/// Everything about the hero is data, not hardcoded: whether it shows, which
/// sources feed it and in what order, how many items rotate, whether the
/// (phased-in) background trailer plays, and which libraries the Random source
/// draws from. This is what lets the default move with real feedback and lets a
/// user customise the hero later without a rewrite.
///
/// Decoding is deliberately lenient (`decodeIfPresent` with per-field
/// fallbacks) so that adding a new field in a later version reads back an older
/// persisted blob as "that field at its default" instead of failing the whole
/// decode and resetting every setting.
public struct HeroSettings: Codable, Equatable, Sendable {
    /// Whether the hero section is shown at all. When `false`, Home renders its
    /// classic rows unchanged.
    public var isEnabled: Bool

    /// The enabled sources, in carousel order. Empty means "nothing to show" —
    /// the hero hides itself even when `isEnabled`.
    public var sources: [HeroSourceKind]

    /// Maximum number of items the carousel rotates through (clamped to
    /// ``maxItemsRange``).
    public var maxItems: Int

    /// Whether the background trailer autoplay (phased-in) is allowed. The view
    /// exposes the slot regardless; this gates whether a trailer is resolved and
    /// played once that feature ships.
    public var trailersEnabled: Bool

    /// Whether previously completed movies, series, and episodes are excluded
    /// from every hero source.
    public var hideWatched: Bool

    /// The `AggregatedLibrary.key`s the Random source may draw from. **Empty
    /// means "all currently-visible libraries"** (the sensible default), so a
    /// fresh profile needs no configuration.
    public var randomLibraryKeys: Set<String>

    /// Whether the carousel auto-advances on a timer.
    public var autoAdvance: Bool

    /// Seconds between auto-advances (clamped to ``autoAdvanceRange``).
    public var autoAdvanceSeconds: Int

    /// Sensible defaults: hero on, all sources enabled (Featured is inert until
    /// Seerr exists, so it's safe to list first), a modest rotation, trailers
    /// off (opt-in), all libraries for Random, gentle auto-advance.
    public static let `default` = HeroSettings(
        isEnabled: true,
        sources: HeroSourceKind.allCases,
        maxItems: 8,
        trailersEnabled: false,
        hideWatched: true,
        randomLibraryKeys: [],
        autoAdvance: true,
        autoAdvanceSeconds: 12
    )

    /// Allowed range for ``maxItems``.
    public static let maxItemsRange: ClosedRange<Int> = 1...20
    /// Allowed range for ``autoAdvanceSeconds``.
    public static let autoAdvanceRange: ClosedRange<Int> = 4...60

    public init(
        isEnabled: Bool,
        sources: [HeroSourceKind],
        maxItems: Int,
        trailersEnabled: Bool,
        hideWatched: Bool = true,
        randomLibraryKeys: Set<String>,
        autoAdvance: Bool,
        autoAdvanceSeconds: Int
    ) {
        self.isEnabled = isEnabled
        // De-duplicate while preserving order so the picker can't persist a
        // source twice.
        var seen = Set<HeroSourceKind>()
        self.sources = sources.filter { seen.insert($0).inserted }
        self.maxItems = maxItems.clamped(to: HeroSettings.maxItemsRange)
        self.trailersEnabled = trailersEnabled
        self.hideWatched = hideWatched
        self.randomLibraryKeys = randomLibraryKeys
        self.autoAdvance = autoAdvance
        self.autoAdvanceSeconds = autoAdvanceSeconds.clamped(to: HeroSettings.autoAdvanceRange)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, sources, maxItems, trailersEnabled, hideWatched
        case randomLibraryKeys, autoAdvance, autoAdvanceSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HeroSettings.default
        // Flattens `decodeIfPresent`'s `T?` (and any thrown error) down to a
        // concrete value, falling back to the default when the key is absent,
        // null, or fails to decode — so a newly-added field reads as its default
        // from an older blob instead of failing the whole decode.
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
        }
        self.init(
            isEnabled: value(Bool.self, .isEnabled, d.isEnabled),
            sources: value([HeroSourceKind].self, .sources, d.sources),
            maxItems: value(Int.self, .maxItems, d.maxItems),
            trailersEnabled: value(Bool.self, .trailersEnabled, d.trailersEnabled),
            hideWatched: value(Bool.self, .hideWatched, d.hideWatched),
            randomLibraryKeys: value(Set<String>.self, .randomLibraryKeys, d.randomLibraryKeys),
            autoAdvance: value(Bool.self, .autoAdvance, d.autoAdvance),
            autoAdvanceSeconds: value(Int.self, .autoAdvanceSeconds, d.autoAdvanceSeconds)
        )
    }

    /// Whether the given source is currently enabled.
    public func isEnabled(_ source: HeroSourceKind) -> Bool {
        sources.contains(source)
    }

    /// Whether the hero should actually render: switched on **and** has at least
    /// one enabled source.
    public var isActive: Bool {
        isEnabled && !sources.isEmpty
    }

    /// Whether honoring Hide Watched requires live external watch history beyond
    /// the already-resolved Continue Watching / Watchlist sources. Only the async
    /// discovery sources — Featured (Seerr) and Random-from-library — surface
    /// titles whose current per-profile watch state isn't already known, so this
    /// is the single predicate that gates the extra provider watch-state fetch and
    /// the hero's `externalRefreshRevision` bump.
    public var requiresExternalWatchHistory: Bool {
        isActive && hideWatched
            && (isEnabled(.featured) || isEnabled(.randomFromLibrary))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Persistence

/// Persists ``HeroSettings`` per profile, mirroring `UIDensitySettingsStore` /
/// `HomeLayoutStore`: the primary profile keeps an un-suffixed key so upgrading
/// installs inherit cleanly, and additional profiles pass their `Profile.id`.
public protocol HeroSettingsStoring: Sendable {
    func load() -> HeroSettings
    func save(_ settings: HeroSettings)
}

public final class HeroSettingsStore: HeroSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.heroSettings", namespace: namespace)
    }

    public func load() -> HeroSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(HeroSettings.self, from: data)
        else { return .default }
        return decoded
    }

    public func save(_ settings: HeroSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// In-memory store for tests and previews.
public final class InMemoryHeroSettingsStore: HeroSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: HeroSettings

    public init(_ initial: HeroSettings = .default) {
        self.settings = initial
    }

    public func load() -> HeroSettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    public func save(_ settings: HeroSettings) {
        lock.lock(); defer { lock.unlock() }
        self.settings = settings
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have the
/// change persisted + broadcast. Mirrors `UIDensitySettingsModel`.
@MainActor
@Observable
public final class HeroSettingsModel {
    public var settings: HeroSettings {
        didSet { store.save(settings) }
    }

    private let store: HeroSettingsStoring

    public init(store: HeroSettingsStoring = HeroSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }
}
