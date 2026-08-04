import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// The iPhone/iPad PIN screen for a profile's `ProfileLock`.
///
/// Shares `PINEntryScaffold` with the Apple TV so the two shells can't drift on
/// behaviour (auto-submit at four digits, reset on a wrong PIN, the reserved
/// error slot). The keypad is kept rather than swapped for a text field: it's
/// the same gesture on both platforms, it can't summon a keyboard over the
/// boxes, and it keeps the entry restricted to digits by construction.
struct PlozziOSProfileLockPINView: View {
    let profile: Profile
    let errorMessage: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

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
