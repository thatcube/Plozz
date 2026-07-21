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
            // Wrap in an array so scalar values (Bool/Int/String) are valid
            // top-level property-list roots too.
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: [value], format: .binary, options: 0
            ) {
                entries[base] = data
            }
        }
        return entries
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
}
