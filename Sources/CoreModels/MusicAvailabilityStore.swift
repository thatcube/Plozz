import Foundation

/// Persists, per account, the IDs of the music libraries last seen on the server,
/// so the Music tab — and its content scope — can be restored on the *first frame*
/// of a relaunch without waiting for a fresh network probe. The map is the *raw*
/// set of libraries (not the visible subset); the current per-profile visibility
/// is applied on top at seed time, so a library hidden while the app was closed is
/// honored immediately. The payload is tiny (a handful of opaque ids).
public protocol MusicAvailabilityStoring: Sendable {
    func load() -> [String: [String]]
    func save(_ librariesByAccount: [String: [String]])
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

    public func load() -> [String: [String]] {
        guard let raw = defaults.dictionary(forKey: key) as? [String: [String]] else { return [:] }
        return raw
    }

    public func save(_ librariesByAccount: [String: [String]]) {
        if librariesByAccount.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(librariesByAccount, forKey: key)
        }
    }
}

/// An in-memory `MusicAvailabilityStoring` for tests and previews — no
/// persistence, no `UserDefaults` dependency.
public final class EphemeralMusicAvailabilityStore: MusicAvailabilityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: [String]]

    public init(seed: [String: [String]] = [:]) {
        self.map = seed
    }

    public func load() -> [String: [String]] {
        lock.lock(); defer { lock.unlock() }
        return map
    }

    public func save(_ librariesByAccount: [String: [String]]) {
        lock.lock(); defer { lock.unlock() }
        map = librariesByAccount
    }
}
