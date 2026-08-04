import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// The PIN screen for a profile's own `ProfileLock`, shown before Plozz switches
/// into a locked profile.
///
/// Uses the same scaffold and badge as the Plex Home PIN prompt on purpose. When
/// someone sets their profile lock to "same PIN as Plex" the two gates become one
/// experience, and a screen that looked different would give away that two
/// separate systems are involved.
///
/// Unlike the Plex prompt there's no network round-trip — the verdict is a local
/// hash comparison — so there's no submitting state to show.
struct ProfileLockPINView: View {
    let profile: Profile
    let errorMessage: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    /// Whether these settings currently reach the user's other devices. Drives
    /// the caveat under the keypad: with Sync off the lock only exists here, and
    /// the same profile is unlocked on every other device.
    private var syncEnabled: Bool { SyncSetupFeatureFlag().isEnabled }

    var body: some View {
        PINEntryScaffold(
            name: profile.name,
            errorMessage: errorMessage,
            isSubmitting: false,
            footnote: syncEnabled ? nil : ProfileLockCopy.lockIsDeviceOnly,
            onSubmit: onSubmit,
            onCancel: onCancel
        ) {
            PINBadge {
                ProfileAvatarView(profile: profile, size: 180)
            }
        }
    }
}
