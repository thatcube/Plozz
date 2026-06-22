import Foundation

/// Optional, isolated seam onto tvOS's *system* multi-user support.
///
/// ## What's wired (Phase 1)
/// Plozz now adopts the `com.apple.developer.user-management` entitlement
/// (`runs-as-current-user-with-user-independent-keychain`). On tvOS 16+ this
/// partitions `UserDefaults`/Keychain per Apple TV system user; the household's
/// shared sign-in and profile set are kept visible to all of them via the
/// user-independent Keychain (see `FeatureAuth.KeychainStore`,
/// `FeatureAuth.AccountStore`, `CoreModels.ProfileStore`).
///
/// The one surviving, non-deprecated `TVUserManager` signal is
/// `shouldStorePreferencesForCurrentUser`; `TVSystemProfileBridge` exposes it so
/// `AppState` can remember each system user's selected profile and skip the
/// launch picker for a returning user. The rest of `TVUserManager`
/// (`currentUserIdentifier`, `currentUserIdentifierDidChangeNotification`,
/// `presentProfilePreferencePanel`, `TVAppProfileDescriptor`,
/// `userIdentifiersForCurrentProfile`) is deprecated and intentionally unused.
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
/// `TVUserManager` signal. Falls back to "remember" when the API is unavailable,
/// so behavior degrades gracefully.
///
/// Wired by default on tvOS (see `AppState.makeDefaultSystemBridge`). Requires
/// the `com.apple.developer.user-management` capability, which Plozz declares in
/// `App/Resources/Plozz.entitlements`.
public struct TVSystemProfileBridge: SystemProfileBridging {
    public init() {}

    public var mayRememberProfileSelection: Bool {
        TVUserManager().shouldStorePreferencesForCurrentUser
    }
}
#endif
