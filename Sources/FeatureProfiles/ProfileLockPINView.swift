#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// The PIN screen for a profile's own `ProfileLock`, shown before switching into
/// a locked profile.
///
/// One view for both shells. It was two identical copies — same scaffold, same
/// copy, same footnote condition — which is a standing invitation for the lock
/// to behave differently on iPhone than on the Apple TV depending on which copy
/// someone happened to edit. There is nothing platform-specific here to justify
/// that: `PINEntryScaffold` already adapts.
///
/// Uses the same scaffold as the Plex Home PIN prompt on purpose. When someone
/// sets their profile lock to "same PIN as Plex" the two gates become one
/// experience, and a screen that looked different would give away that two
/// separate systems are involved.
///
/// The dial pad is kept on iOS rather than swapped for a text field: it's the
/// same gesture on both platforms, it can't summon a keyboard over the dots, and
/// it restricts entry to digits by construction.
///
/// Unlike the Plex prompt there's no network round-trip — the verdict is a local
/// hash comparison — so there's no submitting state to show.
public struct ProfileLockPINView: View {
    private let profile: Profile
    private let errorMessage: String?
    private let isSyncEnabled: Bool
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void

    /// - Parameter isSyncEnabled: whether these settings currently reach the
    ///   user's other devices. Drives the caveat: with Sync off the lock only
    ///   exists here, and the same profile is unlocked everywhere else. Passed in
    ///   rather than read here so this stays a view over its inputs.
    public init(
        profile: Profile,
        errorMessage: String?,
        isSyncEnabled: Bool,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.profile = profile
        self.errorMessage = errorMessage
        self.isSyncEnabled = isSyncEnabled
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    public var body: some View {
        PINEntryScaffold(
            title: ProfileLockCopy.unlockTitle,
            name: profile.name,
            errorMessage: errorMessage,
            footnote: isSyncEnabled ? nil : ProfileLockCopy.lockIsDeviceOnly,
            onSubmit: onSubmit,
            onCancel: onCancel
        ) {
            ProfileAvatarView(profile: profile, size: PINLayout.badgeSize)
        }
    }
}
#endif
