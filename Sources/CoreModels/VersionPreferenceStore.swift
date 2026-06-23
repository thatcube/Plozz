import Foundation

/// Remembers, per title, which media **version** the user last chose to play, so
/// a power user who always wants the 4K HDR cut of a film — or the smaller 1080p
/// version on a bandwidth-constrained server — doesn't have to re-pick it every
/// visit.
///
/// Keyed by a caller-supplied stable id (the title's item id, or for an episode
/// its series id so a whole show shares one preference). The stored value is the
/// chosen `MediaVersion.id`. A title with no remembered choice returns `nil`, so
/// callers fall back to the smart, capability-aware recommended selection.
///
/// Deliberately tiny and `UserDefaults`-backed (like `PlaybackPreferencesStore`)
/// — version preference is a convenience, not critical state, so it needs no
/// schema or migration. Per-profile scoped via `namespace`.
public protocol VersionPreferenceStoring: Sendable {
    /// The remembered `MediaVersion.id` for `titleID`, or `nil` if none.
    func preferredVersionID(forTitle titleID: String) -> String?
    /// Remembers `versionID` as the preferred version for `titleID`. Passing
    /// `nil` clears the preference (reverting to the recommended default).
    func setPreferredVersionID(_ versionID: String?, forTitle titleID: String)
}

public final class VersionPreferenceStore: VersionPreferenceStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let baseKey: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key; other profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.baseKey = SettingsKey.scoped("com.plozz.playback.preferredVersions", namespace: namespace)
    }

    public func preferredVersionID(forTitle titleID: String) -> String? {
        guard !titleID.isEmpty else { return nil }
        let map = defaults.dictionary(forKey: baseKey) as? [String: String]
        return map?[titleID]
    }

    public func setPreferredVersionID(_ versionID: String?, forTitle titleID: String) {
        guard !titleID.isEmpty else { return }
        var map = (defaults.dictionary(forKey: baseKey) as? [String: String]) ?? [:]
        if let versionID {
            map[titleID] = versionID
        } else {
            map.removeValue(forKey: titleID)
        }
        defaults.set(map, forKey: baseKey)
    }
}
