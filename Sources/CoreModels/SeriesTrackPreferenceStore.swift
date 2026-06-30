import Foundation

/// Per-profile persistence of remembered per-series audio/subtitle language
/// choices. Read at load (to steer the initial tracks) and written on a manual
/// track switch. Reads/writes are serialized so the player's manual-switch
/// writes and load-time reads can't interleave a lost update.
public protocol SeriesTrackPreferenceStoring: Sendable {
    func preference(forKey key: String) -> SeriesTrackPreference?
    func setAudioLanguage(_ language: String?, forKey key: String)
    func setSubtitle(_ selection: RememberedSubtitleSelection?, forKey key: String)
}

public final class SeriesTrackPreferenceStore: SeriesTrackPreferenceStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the un-suffixed key; other profiles pass their
    ///   `Profile.id`, mirroring the other settings stores.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.seriesTrackPreferences", namespace: namespace)
    }

    public func preference(forKey key: String) -> SeriesTrackPreference? {
        lock.lock()
        defer { lock.unlock() }
        return loadAll()[key]
    }

    public func setAudioLanguage(_ language: String?, forKey key: String) {
        mutate(key) { $0.audioLanguage = language }
    }

    public func setSubtitle(_ selection: RememberedSubtitleSelection?, forKey key: String) {
        mutate(key) { $0.subtitle = selection }
    }

    // MARK: - Private

    /// Read-modify-write one series entry under the lock, dropping the entry when
    /// it becomes empty so the persisted map doesn't grow with no-op records.
    private func mutate(_ key: String, _ body: (inout SeriesTrackPreference) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadAll()
        var entry = all[key] ?? SeriesTrackPreference()
        body(&entry)
        if entry.isEmpty {
            all[key] = nil
        } else {
            all[key] = entry
        }
        saveAll(all)
    }

    private func loadAll() -> [String: SeriesTrackPreference] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: SeriesTrackPreference].self, from: data) else {
            return [:]
        }
        return map
    }

    private func saveAll(_ map: [String: SeriesTrackPreference]) {
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: key)
        }
    }
}
