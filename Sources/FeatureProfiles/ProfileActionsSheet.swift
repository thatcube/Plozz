#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// The sheet the picker's Edit button opens: what do you want to change about
/// this profile?
///
/// Edit used to go straight to the avatar picker, which quietly decided that
/// "edit" means "appearance". It doesn't — locking a profile and marking it as a
/// child's are the other two things you'd come here for, and both were buried
/// several screens into Settings.
///
/// The choices themselves are `ProfileActionsList`, shared with Settings, so the
/// two surfaces can't drift.
public struct ProfileActionsSheet: View {
    private let profile: Profile
    private let syncEnabled: Bool
    private let offersPlexPINReuse: Bool
    private let hasParentalPIN: Bool
    /// Whether the escalation-capable actions are withheld. Required rather than
    /// defaulted: a security control that defaults to OPEN is one forgotten
    /// argument away from a hole.
    private let restrictedActionsSealed: Bool
    private let onEditAppearance: () -> Void
    private let onSetLock: (ProfileLock?) -> Void
    private let onSetKids: (Bool) -> Void
    private let onSetParentalPIN: (ParentalPIN?) -> Void
    private let validatePlexPIN: (String) async -> PlexPINValidationResult
    private let onDelete: (() -> Void)?
    private let isUnlocked: Bool
    private let onUnlock: () -> Void
    private let onClose: () -> Void

    public init(
        profile: Profile,
        syncEnabled: Bool,
        offersPlexPINReuse: Bool = false,
        hasParentalPIN: Bool,
        restrictedActionsSealed: Bool = false,
        onEditAppearance: @escaping () -> Void,
        onSetLock: @escaping (ProfileLock?) -> Void,
        onSetKids: @escaping (Bool) -> Void,
        onSetParentalPIN: @escaping (ParentalPIN?) -> Void = { _ in },
        validatePlexPIN: @escaping (String) async -> PlexPINValidationResult = {
            _ in .unavailable
        },
        onDelete: (() -> Void)? = nil,
        isUnlocked: Bool = true,
        onUnlock: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.profile = profile
        self.syncEnabled = syncEnabled
        self.offersPlexPINReuse = offersPlexPINReuse
        self.hasParentalPIN = hasParentalPIN
        self.restrictedActionsSealed = restrictedActionsSealed
        self.onEditAppearance = onEditAppearance
        self.onSetLock = onSetLock
        self.onSetKids = onSetKids
        self.onSetParentalPIN = onSetParentalPIN
        self.validatePlexPIN = validatePlexPIN
        self.onDelete = onDelete
        self.isUnlocked = isUnlocked
        self.onUnlock = onUnlock
        self.onClose = onClose
    }

    @Environment(\.themePalette) private var palette

    /// Which PIN setup, if any, is showing over the actions.
    ///
    /// Rendered IN PLACE rather than presented. This sheet is already a
    /// full-screen modal, so a second modal on top would be a presentation from
    /// inside a presentation — the arrangement that fails silently. Swapping the
    /// content is the same trick the onboarding container uses.
    private enum SetupStep: Identifiable {
        case lock
        case parental
        var id: Self { self }
    }

    @State private var setupStep: SetupStep?

    public var body: some View {
        switch setupStep {
        case .lock:
            ProfileLockSetupView(
                profile: profile,
                offersPlexPINReuse: offersPlexPINReuse,
                syncEnabled: syncEnabled,
                validatePlexPIN: validatePlexPIN,
                onComplete: { lock in
                    onSetLock(lock)
                    setupStep = nil
                },
                onCancel: { setupStep = nil }
            )
        case .parental:
            ParentalPINSetupView(
                onComplete: { pin in
                    onSetParentalPIN(pin)
                    setupStep = nil
                },
                onCancel: { setupStep = nil }
            )
        case .none:
            actionsContent
        }
    }

    @ViewBuilder
    private var actionsContent: some View {
        #if os(tvOS)
        // Content-sized: roomy fixed width, intrinsic height from the header and
        // action rows. No ScrollView, fixed height, or filler Spacer.
        VStack(alignment: .leading, spacing: 28) {
            header
            ProfileActionsList(
                profile: profile,
                syncEnabled: syncEnabled,
                offersPlexPINReuse: offersPlexPINReuse,
                hasParentalPIN: hasParentalPIN,
                restrictedActionsSealed: restrictedActionsSealed,
                onEditAppearance: onEditAppearance,
                onEditLock: { setupStep = .lock },
                onCreateParentalPIN: { setupStep = .parental },
                onSetLock: onSetLock,
                onSetKids: onSetKids,
                onSetParentalPIN: onSetParentalPIN,
                validatePlexPIN: validatePlexPIN,
                onDelete: onDelete,
                isUnlocked: isUnlocked,
                onUnlock: onUnlock
            )
        }
        .frame(width: 1080, alignment: .topLeading)
        .padding(48)
        .background { AppBackground(palette: palette).ignoresSafeArea() }
        .onExitCommand(perform: onClose)
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        #else
        ZStack {
            AppBackground(palette: palette).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    ProfileActionsList(
                        profile: profile,
                        syncEnabled: syncEnabled,
                        offersPlexPINReuse: offersPlexPINReuse,
                        hasParentalPIN: hasParentalPIN,
                restrictedActionsSealed: restrictedActionsSealed,
                        onEditAppearance: onEditAppearance,
                onEditLock: { setupStep = .lock },
                onCreateParentalPIN: { setupStep = .parental },
                        onSetLock: onSetLock,
                        onSetKids: onSetKids,
                onSetParentalPIN: onSetParentalPIN,
                        validatePlexPIN: validatePlexPIN,
                        onDelete: onDelete,
                        isUnlocked: isUnlocked,
                        onUnlock: onUnlock
                    )
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 60)
                .padding(.vertical, 60)
            }
            .scrollClipDisabled()
        }
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        #endif
    }

    private var header: some View {
        HStack(spacing: 24) {
            ProfileAvatarView(profile: profile, size: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: profile.name)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                if profile.isKids || profile.isLocked {
                    HStack(spacing: 14) {
                        if profile.isLocked {
                            Label(ProfileLockCopy.title, systemImage: "lock.fill")
                        }
                        if profile.isKids {
                            Label(KidsProfileCopy.title, systemImage: "figure.and.child.holdinghands")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
#endif
