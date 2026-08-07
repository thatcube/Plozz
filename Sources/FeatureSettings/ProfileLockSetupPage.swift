#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// Choosing or changing one profile's own lock PIN, as a page on the Settings
/// stack.
///
/// A page rather than a nested destination on purpose. The profile page that
/// leads here is itself pushed by the Settings `NavigationStack`, and a view
/// pushed by a stack must not declare another `navigationDestination` for that
/// same stack — SwiftUI allows one per level, and the second one invalidates
/// without settling: the page re-ran its body ~180 times a second and the screen
/// stopped responding entirely.
struct ProfileLockSetupPage: View {
    let context: SettingsContext
    let profileID: String
    let syncEnabled: Bool

    @Environment(\.dismiss) private var dismiss

    private var profile: Profile? {
        context.profiles.first(where: { $0.id == profileID })
    }

    var body: some View {
        Group {
            if let profile {
                ProfileLockSetupView(
                    profile: profile,
                    offersPlexPINReuse: profile.playsAsPINProtectedPlexUser,
                    syncEnabled: syncEnabled,
                    validatePlexPIN: { await context.validatePlexPIN($0, profileID) },
                    onComplete: { lock in
                        context.onSetProfileLock(profileID, lock)
                        dismiss()
                    },
                    onCancel: { dismiss() }
                )
            }
        }
        // A page about a profile that no longer exists has nothing to say. On a
        // CHANGE only: dismissing during the push itself wedges the stack.
        .onChange(of: profile == nil) { _, gone in
            if gone { dismiss() }
        }
    }
}

/// Creating the household's Parental PIN, as a page on the Settings stack.
/// Pushed for the same reason as ``ProfileLockSetupPage``.
struct ParentalPINSetupPage: View {
    let context: SettingsContext

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ParentalPINSetupView(
            onComplete: { pin in
                context.onSetParentalPIN(pin)
                dismiss()
            },
            onCancel: { dismiss() }
        )
    }
}
#endif
