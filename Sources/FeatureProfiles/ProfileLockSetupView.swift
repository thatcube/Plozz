#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// The full-screen "choose a PIN" flow: enter four digits, then enter them again
/// to confirm.
///
/// Lives here, in FeatureProfiles, because two very different places need the
/// exact same thing — Settings → Everyone → Profiles → *name* → Profile Lock, and
/// the picker's "just created a profile, want to lock it?" step. Sharing the flow
/// (rather than each rebuilding a keypad) is what keeps them from drifting, and
/// it means the confirm-mismatch behaviour is defined once.
///
/// The raw PIN never leaves this view: it is turned into a salted `ProfileLock`
/// verifier here and only that is handed back.
public struct ProfileLockSetupView: View {
    private let profile: Profile
    /// Offered when the profile plays as a Plex Home user that already asks for a
    /// PIN, so one entry can satisfy both.
    private let offersPlexPINReuse: Bool
    /// Whether the lock will reach the user's other devices. Drives the caveat.
    private let syncEnabled: Bool
    private let onComplete: (ProfileLock) -> Void
    private let onCancel: () -> Void

    public init(
        profile: Profile,
        offersPlexPINReuse: Bool = false,
        syncEnabled: Bool = true,
        onComplete: @escaping (ProfileLock) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.profile = profile
        self.offersPlexPINReuse = offersPlexPINReuse
        self.syncEnabled = syncEnabled
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    /// The first entry, held while it's confirmed. In memory for the few seconds
    /// between the two entries and never persisted.
    @State private var firstEntry: String?
    @State private var errorMessage: String?

    private var isConfirming: Bool { firstEntry != nil }

    public var body: some View {
        PINEntryScaffold(
            title: isConfirming ? ProfileLockCopy.confirm : ProfileLockCopy.enterToCreate,
            subtitle: isConfirming ? nil : ProfileLockCopy.explanation,
            name: profile.name,
            errorMessage: errorMessage,
            footnote: syncEnabled ? nil : ProfileLockCopy.lockIsDeviceOnly,
            onSubmit: submit,
            onCancel: onCancel
        ) {
            ProfileAvatarView(profile: profile, size: 200)
        }
    }

    private func submit(_ pin: String) {
        guard let first = firstEntry else {
            firstEntry = pin
            errorMessage = nil
            return
        }
        guard first == pin else {
            // Start over rather than letting them retry just the confirmation:
            // when the two disagree we don't know which one they meant.
            errorMessage = String(localized: ProfileLockCopy.mismatch)
            firstEntry = nil
            return
        }
        guard let lock = ProfileLock.make(pin: first, matchesPlexPIN: offersPlexPINReuse) else {
            errorMessage = String(localized: ProfileLockCopy.mismatch)
            firstEntry = nil
            return
        }
        onComplete(lock)
    }
}
#endif
