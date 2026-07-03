import Foundation
import CoreModels

/// Persists the last-known Home row layout (the ordered list of row *kinds* that
/// were present on the previous successful load, each with the number of cards it
/// rendered) so the next launch can render a skeleton that matches the user's
/// actual Home — same rows, same order, same card counts — before any network
/// returns. Only structure + counts are stored, never content.
public protocol HomeLayoutStoring: Sendable {
    func load() -> [HomeRowLayout]
    func save(_ layout: [HomeRowLayout])
}

/// `UserDefaults`-backed store. Per-profile scoped via `SettingsKey.scoped` so
/// each profile remembers its own row structure (mirrors how Home-visibility is
/// persisted), and the primary profile keeps an un-suffixed key.
public final class HomeLayoutStore: HomeLayoutStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// Wire format for one persisted row. Kept as a raw `String` kind (not a typed
    /// `HomeRowKind`) so a since-removed kind decodes into a droppable entry rather
    /// than failing the whole array — preserving the old store's defensive
    /// "filter out unknown kinds" behaviour.
    private struct Stored: Codable {
        let kind: String
        let count: Int
    }

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        // v2 key: the payload changed from a bare `[String]` of kinds to a JSON
        // blob carrying per-row counts. A pre-v2 value simply reads back as "no
        // data" here, so the first post-upgrade launch falls back to the default
        // (screen-filling) skeleton — no migration needed.
        self.key = SettingsKey.scoped("com.plozz.homeLayout.v2", namespace: namespace)
    }

    public func load() -> [HomeRowLayout] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([Stored].self, from: data)
        else { return [] }
        // Drop any unknown/removed kinds defensively so an older persisted value
        // can't inject a phantom row after the kinds change.
        return stored.compactMap { entry in
            HomeRowKind(rawValue: entry.kind).map { HomeRowLayout(kind: $0, count: entry.count) }
        }
    }

    public func save(_ layout: [HomeRowLayout]) {
        let stored = layout.map { Stored(kind: $0.kind.rawValue, count: $0.count) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key)
    }
}

/// In-memory store for tests and previews.
public final class InMemoryHomeLayoutStore: HomeLayoutStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var layout: [HomeRowLayout]

    public init(_ initial: [HomeRowLayout] = []) {
        self.layout = initial
    }

    public func load() -> [HomeRowLayout] {
        lock.lock(); defer { lock.unlock() }
        return layout
    }

    public func save(_ layout: [HomeRowLayout]) {
        lock.lock(); defer { lock.unlock() }
        self.layout = layout
    }
}
