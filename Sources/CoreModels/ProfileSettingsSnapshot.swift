import Foundation

/// A serialized copy of one profile's transferable per-profile settings, moved
/// device→device by Sync & Setup so a newly set-up device mirrors the source's
/// preferences (theme, playback, subtitles, etc.) rather than starting at
/// defaults. NON-SECRET: these are user preference values only.
///
/// Values are captured straight from the profile-namespaced `UserDefaults` keys
/// the settings stores already use, so this stays in lockstep with them without
/// re-encoding each settings type. Only the base keys in
/// `ProfileSettingsTransfer.transferableBaseKeys` travel — device- and
/// platform-specific settings (UI density, navigation style), device-local debug
/// (diagnostics), the sync feature flag itself, and device-capability flags are
/// deliberately kept local.
public struct ProfileSettingsSnapshot: Codable, Hashable, Sendable {
    public var profileID: String
    /// base settings key → property-list-encoded value blob.
    public var entries: [String: Data]

    public init(profileID: String, entries: [String: Data]) {
        self.profileID = profileID
        self.entries = entries
    }
}

public enum ProfileSettingsTransfer {
    /// The per-profile preference base keys that are safe and meaningful to carry
    /// across devices. Curated allow-list (explicit on purpose): a new setting is
    /// device-local until it's deliberately added here.
    ///
    /// Deliberately EXCLUDED:
    ///  - `com.plozz.uiDensity` (touch vs. TV density — platform-specific)
    ///  - `navigationStyle` (tab bar vs. sidebar — platform-specific)
    ///  - `com.plozz.diagnosticsSettings` (device-local debugging)
    ///  - `com.plozz.syncSetup.enabled` (the sync flag itself — must not propagate)
    ///  - `com.plozz.musicAvailability` (a per-device capability, not a preference)
    public static let transferableBaseKeys: [String] = [
        "com.plozz.appTheme",
        "transparencyPreference",
        "com.plozz.cardStyle",
        "com.plozz.watchStatusIndicator",
        "com.plozz.nightShift",
        "com.plozz.playbackSettings",
        "com.plozz.playback.preferredVersions",
        "com.plozz.playback.speed",
        "com.plozz.subtitleBehavior",
        "com.plozz.subtitlePolicyOverrides",
        "com.plozz.subtitleStyle",
        "com.plozz.captionSettings",
        "com.plozz.audioPolicyOverrides",
        "com.plozz.spoilerSettings",
        "com.plozz.heroBackgroundSettings",
        "com.plozz.heroSettings",
        "com.plozz.homeLibraryVisibility",
        "com.plozz.homeLayout.v2",
        "home-content",
        "com.plozz.musicLandingLayout",
        "com.plozz.themeMusicSettings",
        "com.plozz.seriesTrackPreferences",
        "musicShowTrackDetails",
        "musicLyricsEnabled",
        "musicPlayerAppearance",
    ]

    /// Capture the transferable settings for one profile namespace (`nil` = the
    /// default profile's un-suffixed keys). Missing keys are skipped, so only
    /// values the user actually set travel.
    public static func capture(
        namespace: String?,
        defaults: UserDefaults = .standard
    ) -> [String: Data] {
        var entries: [String: Data] = [:]
        for base in transferableBaseKeys {
            let key = SettingsKey.scoped(base, namespace: namespace)
            guard let value = defaults.object(forKey: key) else { continue }
            // Canonicalize so the SAME logical value always yields the SAME bytes.
            // Without this, a value stored as a JSON `Data` blob whose Codable type
            // has `Dictionary` properties re-encodes with NON-DETERMINISTIC key
            // order every time a settings model's `didSet` re-saves it (e.g. when
            // applying a remote change rebuilds the active profile's models). That
            // made `capture` return different bytes for unchanged settings, so the
            // sync mirror saw a phantom "change", re-stamped the record, and the
            // devices ping-ponged republishes forever — starving real fetches and
            // producing the "works maybe once, then wildly inconsistent" behavior.
            // Wrap in an array so scalar values (Bool/Int/String) are valid
            // top-level property-list roots too.
            let canonical = canonicalize(value)
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: [canonical], format: .binary, options: 0
            ) {
                entries[base] = data
            }
        }
        return entries
    }

    /// Normalize a persisted settings value into a byte-stable form. A `Data` blob
    /// that is really JSON (the common case — most settings stores persist
    /// `JSONEncoder().encode(...)` output) is re-serialized with SORTED keys so
    /// dictionary ordering can't vary run-to-run. Everything else is returned
    /// unchanged: property-list scalars/strings/arrays already serialize
    /// deterministically, and a non-JSON `Data` blob is left as its (stable) bytes.
    static func canonicalize(_ value: Any) -> Any {
        guard let data = value as? Data else { return value }
        guard let object = try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]),
              let canonical = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        else { return value }
        return canonical
    }

    /// Reinstall captured settings into a profile namespace on this device.
    public static func apply(
        _ entries: [String: Data],
        namespace: String?,
        defaults: UserDefaults = .standard
    ) {
        for base in transferableBaseKeys {
            guard let data = entries[base] else { continue }
            guard let unwrapped = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [Any], let value = unwrapped.first else { continue }
            defaults.set(value, forKey: SettingsKey.scoped(base, namespace: namespace))
        }
    }

    /// Write ONE captured setting (a single base key's blob, as produced by `capture`)
    /// into a profile namespace. Used by the V3 per-setting record sync so an exact
    /// remote change writes exactly that key.
    public static func applyOne(
        baseKey: String, blob: Data, namespace: String?, defaults: UserDefaults = .standard
    ) {
        guard transferableBaseKeys.contains(baseKey) else { return }
        guard let unwrapped = try? PropertyListSerialization.propertyList(
            from: blob, options: [], format: nil) as? [Any], let value = unwrapped.first else { return }
        defaults.set(value, forKey: SettingsKey.scoped(baseKey, namespace: namespace))
    }

    /// Remove ONE setting key from a profile namespace (a synced deletion → this
    /// device reverts that key to its default).
    public static func removeOne(
        baseKey: String, namespace: String?, defaults: UserDefaults = .standard
    ) {
        guard transferableBaseKeys.contains(baseKey) else { return }
        defaults.removeObject(forKey: SettingsKey.scoped(baseKey, namespace: namespace))
    }
}
