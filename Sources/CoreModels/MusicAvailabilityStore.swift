import Foundation

/// Persists the set of account IDs last confirmed to expose a music library, so
/// the Music tab can be shown on the *first frame* of a relaunch without waiting
/// for a fresh network probe. The payload is tiny (a handful of opaque ids).
public protocol MusicAvailabilityStoring: Sendable {
    func load() -> Set<String>
    func save(_ accountIDs: Set<String>)
}

public final class MusicAvailabilityStore: MusicAvailabilityStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the un-suffixed key; other profiles pass their
    ///   `Profile.id` so each profile remembers its own music availability.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.musicAvailability", namespace: namespace)
    }

    public func load() -> Set<String> {
        guard let ids = defaults.array(forKey: key) as? [String] else { return [] }
        return Set(ids)
    }

    public func save(_ accountIDs: Set<String>) {
        if accountIDs.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(Array(accountIDs), forKey: key)
        }
    }
}

/// An in-memory `MusicAvailabilityStoring` for tests and previews — no
/// persistence, no `UserDefaults` dependency.
public final class EphemeralMusicAvailabilityStore: MusicAvailabilityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String>

    public init(seed: Set<String> = []) {
        self.ids = seed
    }

    public func load() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return ids
    }

    public func save(_ accountIDs: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        ids = accountIDs
    }
}
