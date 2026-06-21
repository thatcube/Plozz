import Foundation

/// Builds per-profile-scoped `UserDefaults` keys for the settings stores.
///
/// The default/primary profile passes `namespace: nil` and therefore keeps the
/// original, un-suffixed key — so an upgrading install transparently inherits
/// its existing settings with no migration step. Any additional profile passes
/// its `Profile.id`, yielding an isolated `"<base>.<namespace>"` key that starts
/// from the type's `.default`.
public enum SettingsKey {
    public static func scoped(_ base: String, namespace: String?) -> String {
        guard let namespace, !namespace.isEmpty else { return base }
        return base + "." + namespace
    }
}
