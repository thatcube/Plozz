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
    private let validatePlexPIN: (String) async -> PlexPINValidationResult
    private let onComplete: (ProfileLock) -> Void
    private let onCancel: () -> Void

    public init(
        profile: Profile,
        offersPlexPINReuse: Bool = false,
        syncEnabled: Bool = true,
        validatePlexPIN: @escaping (String) async -> PlexPINValidationResult = {
            _ in .unavailable
        },
        onComplete: @escaping (ProfileLock) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.profile = profile
        self.offersPlexPINReuse = offersPlexPINReuse
        self.syncEnabled = syncEnabled
        self.validatePlexPIN = validatePlexPIN
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    /// The first entry, held while it's confirmed. In memory for the few seconds
    /// between the two entries and never persisted.
    @State private var firstEntry: String?
    @State private var errorMessage: String?
    /// Confirmed PIN data and dialog visibility are deliberately separate.
    /// SwiftUI clears a presentation binding as a dialog dismisses; using that
    /// same optional as the PIN storage erased the PIN during async Plex
    /// validation, then falsely reported that the two local entries did not match.
    @State private var confirmedPIN: String?
    @State private var showingPlexChoice = false
    @State private var isValidatingPlexPIN = false
    @State private var plexValidationUnavailable = false

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
            isSubmitting: isValidatingPlexPIN,
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
            isPresented: $showingPlexChoice,
            titleVisibility: .visible
        ) {
            Button(String(localized: ProfileLockCopy.usePlexPINYes)) {
                verifyAndFinishSharedPIN()
            }
            Button(String(localized: ProfileLockCopy.usePlexPINNo)) { finish(sharesWithPlex: false) }
            Button("Start Over", role: .cancel) {
                confirmedPIN = nil
                firstEntry = nil
            }
        } message: {
            Text(ProfileLockCopy.usePlexPINDetail)
        }
        .alert(
            Text(ProfileLockCopy.plexPINUnavailableTitle),
            isPresented: $plexValidationUnavailable
        ) {
            Button("Try Again") { verifyAndFinishSharedPIN() }
            Button("Keep Separate") { finish(sharesWithPlex: false) }
            Button("Start Over", role: .cancel) {
                confirmedPIN = nil
                firstEntry = nil
            }
        } message: {
            Text(ProfileLockCopy.plexPINUnavailableDetail)
        }
    }

    /// Builds the lock from the confirmed PIN once the Plex question is settled.
    private func finish(sharesWithPlex: Bool) {
        guard let pin = confirmedPIN,
              let lock = ProfileLock.make(pin: pin, matchesPlexPIN: sharesWithPlex) else {
            confirmedPIN = nil
            errorMessage = String(localized: ProfileLockCopy.mismatch)
            firstEntry = nil
            return
        }
        confirmedPIN = nil
        showingPlexChoice = false
        onComplete(lock)
    }

    private func verifyAndFinishSharedPIN() {
        guard let pin = confirmedPIN else { return }
        showingPlexChoice = false
        isValidatingPlexPIN = true
        Task {
            let result = await validatePlexPIN(pin)
            isValidatingPlexPIN = false
            switch result {
            case .valid:
                finish(sharesWithPlex: true)
            case .invalid:
                confirmedPIN = nil
                firstEntry = nil
                errorMessage = String(
                    localized: ProfileLockCopy.plexPINMismatch
                )
            case .unavailable:
                plexValidationUnavailable = true
            }
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
        firstEntry = nil
        guard offersPlexPINReuse else {
            guard let lock = ProfileLock.make(pin: pin, matchesPlexPIN: false) else {
                errorMessage = String(localized: ProfileLockCopy.mismatch)
                return
            }
            onComplete(lock)
            return
        }
        confirmedPIN = pin
        showingPlexChoice = true
    }
}
#endif
