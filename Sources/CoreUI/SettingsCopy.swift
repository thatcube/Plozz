import Foundation

/// Copy that appears in more than one Settings surface, so tvOS and iOS can never
/// drift apart on the wording — and, now that it is localized, so the string is
/// translated once rather than once per shell.
///
/// `LocalizedStringResource` rather than `String`: `Text(aString)` renders
/// verbatim, so copy typed as `String` is invisible to both the String Catalog and
/// the compiler's string extraction, and would silently stay English.
public enum SettingsCopy {
    public static let libraries = LocalizedStringResource(
        "settings.nav.libraries",
        defaultValue: "Libraries",
        comment: "Navigation row and page heading for the screen listing the user's media libraries."
    )
    public static let attributions = LocalizedStringResource(
        "settings.nav.attributions",
        defaultValue: "Attributions",
        comment: "Navigation row for the screen crediting third-party software and data sources."
    )

    // MARK: - Scope headers

    /// Heading for the settings every profile shares.
    ///
    /// Deliberately named for the *audience* rather than the hardware ("This
    /// Apple TV") or the transport ("iCloud"). Turning iCloud Sync off does not
    /// move a single setting between sections — it only shrinks how far they
    /// reach — so a hardware-named heading is correct exactly half the time and
    /// makes rows appear to jump scope when the toggle flips. The audience never
    /// changes, so the heading never has to.
    ///
    /// "Everyone" over the obvious alternatives, all of which are taken:
    /// "Household" is Netflix's password-sharing enforcement term, "Family" is
    /// Apple's own Family Sharing (on this very device), "Home" collides with our
    /// Home tab, and "Shared" collides with SMB/NFS media shares.
    public static let everyone = LocalizedStringResource(
        "settings.scope.everyone",
        defaultValue: "Everyone",
        comment: "Heading for the group of settings shared by every profile, as opposed to the section holding the current profile's own settings."
    )

    /// Reach clause for the active profile's own settings, when iCloud Sync is on.
    public static let profileScopeSynced = LocalizedStringResource(
        "settings.scope.profile.synced",
        defaultValue: "Saved to your profile, on all your devices.",
        comment: "Subtitle under a profile's name in Settings, explaining that the settings below belong to this profile and follow the user to their other devices."
    )

    /// Reach clause for the active profile's own settings, when iCloud Sync is off.
    /// - Parameter deviceName: the device the app is running on, e.g. "Apple TV" or "iPhone".
    public static func profileScopeLocal(deviceName: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "settings.scope.profile.local",
            defaultValue: "Saved to your profile on this \(deviceName).",
            comment: "Subtitle under a profile's name in Settings when iCloud Sync is off, so the settings stay on this one device. The placeholder is the device kind, e.g. 'Apple TV' or 'iPhone'."
        )
    }

    /// Reach clause for the shared settings, when iCloud Sync is on.
    public static let everyoneScopeSynced = LocalizedStringResource(
        "settings.scope.everyone.synced",
        defaultValue: "Shared across every profile, on all your devices.",
        comment: "Subtitle for the group of settings shared by every profile, explaining that they also follow the user to their other devices."
    )

    /// Reach clause for the shared settings, when iCloud Sync is off.
    /// - Parameter deviceName: the device the app is running on, e.g. "Apple TV" or "iPhone".
    public static func everyoneScopeLocal(deviceName: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "settings.scope.everyone.local",
            defaultValue: "Shared across every profile on this \(deviceName).",
            comment: "Subtitle for the group of settings shared by every profile when iCloud Sync is off, so they stay on this one device. The placeholder is the device kind, e.g. 'Apple TV' or 'iPhone'."
        )
    }

    /// Reach clause for the active profile's own settings.
    ///
    /// - Parameters:
    ///   - syncEnabled: whether iCloud Sync is on.
    ///   - deviceName: the device kind, e.g. "Apple TV" or "iPhone". Only used
    ///     when sync is off — with sync on, the whole point is that the device
    ///     doesn't matter.
    public static func profileScope(
        syncEnabled: Bool,
        deviceName: String
    ) -> LocalizedStringResource {
        syncEnabled ? profileScopeSynced : profileScopeLocal(deviceName: deviceName)
    }

    /// Reach clause for the shared settings.
    ///
    /// - Parameters:
    ///   - syncEnabled: whether iCloud Sync is on.
    ///   - deviceName: the device kind, e.g. "Apple TV" or "iPhone". Only used
    ///     when sync is off.
    public static func everyoneScope(
        syncEnabled: Bool,
        deviceName: String
    ) -> LocalizedStringResource {
        syncEnabled ? everyoneScopeSynced : everyoneScopeLocal(deviceName: deviceName)
    }
}
