import Foundation

/// Optional, isolated seam onto tvOS's *system* multi-user support.
///
/// ## Why this is a thin, deferred adapter
/// Research against Apple's current docs shows almost all of `TVUserManager`
/// (TVServices) is **deprecated** — `currentUserIdentifier`,
/// `currentUserIdentifierDidChangeNotification`, `presentProfilePreferencePanel`,
/// `TVAppProfileDescriptor`, `userIdentifiersForCurrentProfile`. The only
/// non-deprecated signal is `shouldStorePreferencesForCurrentUser`, and it
/// requires the `com.apple.developer.user-management` ("Runs as Current User")
/// entitlement, which also reshapes how `UserDefaults`/Keychain containers are
/// isolated per Apple TV system user.
///
/// Plozz's profiles are therefore **app-owned** (they work on every tvOS 17
/// device with no entitlement). This protocol is the honest, future-proof hook:
/// a default no-op today, and the single place to opt into the system signal
/// later without touching the rest of the app.
public protocol SystemProfileBridging: Sendable {
    /// Whether the app may *persist* the selected profile for the current Apple
    /// TV system user. When `false`, the app should show the picker each session
    /// and not remember the choice. The default adapter returns `true` (single
    /// app-owned household), preserving current behavior.
    var mayRememberProfileSelection: Bool { get }
}

/// Default app-owned bridge: always allowed to remember the selection. Used
/// unless/until the `user-management` entitlement is adopted.
public struct AppOwnedProfileBridge: SystemProfileBridging {
    public init() {}
    public var mayRememberProfileSelection: Bool { true }
}

#if canImport(TVServices)
import TVServices

/// tvOS-backed bridge that consults the one surviving, non-deprecated
/// `TVUserManager` signal. Falls back to "remember" when the API is unavailable
/// (e.g. the entitlement isn't present), so behavior degrades gracefully.
///
/// Not wired by default — adopting it requires adding the
/// `com.apple.developer.user-management` capability. Kept here so the
/// integration is a one-line swap rather than a rewrite.
public struct TVSystemProfileBridge: SystemProfileBridging {
    public init() {}

    public var mayRememberProfileSelection: Bool {
        TVUserManager().shouldStorePreferencesForCurrentUser
    }
}
#endif
