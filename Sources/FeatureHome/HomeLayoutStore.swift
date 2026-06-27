import Foundation
import CoreModels

/// Persists the last-known Home row layout (the ordered list of row *kinds* that
/// were present on the previous successful load) so the next launch can render a
/// skeleton that matches the user's actual Home — same rows, same order — before
/// any network returns. Only the structure is stored, never content.
public protocol HomeLayoutStoring: Sendable {
    func load() -> [HomeRowKind]
    func save(_ layout: [HomeRowKind])
}

/// `UserDefaults`-backed store. Per-profile scoped via `SettingsKey.scoped` so
/// each profile remembers its own row structure (mirrors how Home-visibility is
/// persisted), and the primary profile keeps an un-suffixed key.
public final class HomeLayoutStore: HomeLayoutStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.homeLayout", namespace: namespace)
    }

    public func load() -> [HomeRowKind] {
        guard let raw = defaults.array(forKey: key) as? [String] else { return [] }
        // Drop any unknown/removed kinds defensively so an older persisted value
        // can't crash or inject a phantom row after the kinds change.
        return raw.compactMap(HomeRowKind.init(rawValue:))
    }

    public func save(_ layout: [HomeRowKind]) {
        defaults.set(layout.map(\.rawValue), forKey: key)
    }
}

/// In-memory store for tests and previews.
public final class InMemoryHomeLayoutStore: HomeLayoutStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var layout: [HomeRowKind]

    public init(_ initial: [HomeRowKind] = []) {
        self.layout = initial
    }

    public func load() -> [HomeRowKind] {
        lock.lock(); defer { lock.unlock() }
        return layout
    }

    public func save(_ layout: [HomeRowKind]) {
        lock.lock(); defer { lock.unlock() }
        self.layout = layout
    }
}
