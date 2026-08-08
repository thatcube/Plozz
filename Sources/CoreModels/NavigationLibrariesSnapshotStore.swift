import Foundation

/// Persists the libraries the navigation rail last rendered, per profile, so the
/// chrome paints its real entries on the FIRST frame after launch instead of
/// appearing empty and then popping libraries in once discovery lands.
///
/// The same idea as ``HomeLayoutStore`` / ``HomeContentStore`` for Home: the
/// persisted set is a *paint hint*, never the source of truth. Live discovery
/// always replaces it, and a library that has gone away simply disappears on the
/// next refresh. Nothing is fetched or played from this cache, so a stale entry
/// can at worst show a rail row for a beat longer than it should.
public protocol NavigationLibrariesSnapshotStoring: Sendable {
    func load() -> [AggregatedLibrary]
    func save(_ libraries: [AggregatedLibrary])
}

public final class NavigationLibrariesSnapshotStore: NavigationLibrariesSnapshotStoring, @unchecked Sendable {
    /// Bounds the persisted payload. A household with more libraries than this
    /// still gets instant paint for the first `limit` and the rest on discovery,
    /// which is far better than writing an unbounded blob to `UserDefaults`.
    private static let limit = 60

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.navigationLibrariesSnapshot", namespace: namespace)
    }

    public func load() -> [AggregatedLibrary] {
        guard let data = defaults.data(forKey: key),
              let libraries = try? JSONDecoder().decode([AggregatedLibrary].self, from: data) else {
            return []
        }
        return libraries
    }

    public func save(_ libraries: [AggregatedLibrary]) {
        let bounded = Array(libraries.prefix(Self.limit))
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: key)
    }
}
