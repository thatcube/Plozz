#if os(iOS)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// The iPhone/iPad PIN screen for a profile's `ProfileLock`.
///
/// Shares `PINEntryScaffold` with the Apple TV so the two shells can't drift on
/// behaviour (auto-submit at four digits, reset on a wrong PIN, the reserved
/// error slot). The dial pad is kept rather than swapped for a text field: it's
/// the same gesture on both platforms, it can't summon a keyboard over the dots,
/// and it restricts entry to digits by construction.
struct PlozziOSProfileLockPINView: View {
    let profile: Profile
    let errorMessage: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    private var syncEnabled: Bool { SyncSetupFeatureFlag().isEnabled }

    var body: some View {
        PINEntryScaffold(
            title: ProfileLockCopy.unlockTitle,
            name: profile.name,
            errorMessage: errorMessage,
            footnote: syncEnabled ? nil : ProfileLockCopy.lockIsDeviceOnly,
            onSubmit: onSubmit,
            onCancel: onCancel
        ) {
            ProfileAvatarView(profile: profile, size: PINLayout.badgeSize)
        }
    }
}
#endif
