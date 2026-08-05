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
    /// A confirmed PIN waiting on the "share it with Plex?" question.
    @State private var pinAwaitingPlexChoice: String?

    private var isConfirming: Bool { firstEntry != nil }

    public var body: some View {
        PINEntryScaffold(
            title: isConfirming
                ? ProfileLockCopy.confirm
                : (offersPlexPINReuse
                    ? ProfileLockCopy.createAlongsidePlexTitle
                    : ProfileLockCopy.createTitle),
            subtitle: isConfirming
                ? nil
                : (offersPlexPINReuse
                    ? ProfileLockCopy.createAlongsidePlexSubtitle
                    : ProfileLockCopy.createSubtitle),
            name: profile.name,
            errorMessage: errorMessage,
            footnote: syncEnabled ? nil : ProfileLockCopy.lockIsDeviceOnly,
            onSubmit: submit,
            onCancel: onCancel
        ) {
            ProfileAvatarView(profile: profile, size: PINLayout.badgeSize)
        }
        // Reusing the PIN for Plex has to be ASKED, not assumed. Saying yes means
        // Plozz forwards these digits to plex.tv when this profile plays as that
        // Home user — a third party the person didn't necessarily have in mind
        // when they chose a PIN for Plozz. Only shown when the profile actually
        // plays as a PIN-protected Plex user.
        .confirmationDialog(
            Text(ProfileLockCopy.usePlexPIN),
            isPresented: Binding(
                get: { pinAwaitingPlexChoice != nil },
                set: { if !$0 { pinAwaitingPlexChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: ProfileLockCopy.usePlexPINYes)) { finish(sharesWithPlex: true) }
            Button(String(localized: ProfileLockCopy.usePlexPINNo)) { finish(sharesWithPlex: false) }
        } message: {
            Text(ProfileLockCopy.usePlexPINDetail)
        }
    }

    /// Builds the lock from the confirmed PIN once the Plex question is settled.
    private func finish(sharesWithPlex: Bool) {
        guard let pin = pinAwaitingPlexChoice,
              let lock = ProfileLock.make(pin: pin, matchesPlexPIN: sharesWithPlex) else {
            pinAwaitingPlexChoice = nil
            errorMessage = String(localized: ProfileLockCopy.mismatch)
            firstEntry = nil
            return
        }
        pinAwaitingPlexChoice = nil
        onComplete(lock)
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
        firstEntry = nil
        guard offersPlexPINReuse else {
            guard let lock = ProfileLock.make(pin: pin, matchesPlexPIN: false) else {
                errorMessage = String(localized: ProfileLockCopy.mismatch)
                return
            }
            onComplete(lock)
            return
        }
        pinAwaitingPlexChoice = pin
    }
}
#endif
