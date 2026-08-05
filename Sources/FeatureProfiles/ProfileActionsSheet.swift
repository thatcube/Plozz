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
    private let householdHasOtherLock: Bool
    private let onEditAppearance: () -> Void
    private let onSetLock: (ProfileLock?) -> Void
    private let onSetKids: (Bool) -> Void
    private let validatePlexPIN: (String) async -> PlexPINValidationResult
    private let onDelete: (() -> Void)?
    private let isUnlocked: Bool
    private let onUnlock: () -> Void
    private let onClose: () -> Void

    public init(
        profile: Profile,
        syncEnabled: Bool,
        offersPlexPINReuse: Bool = false,
        householdHasOtherLock: Bool,
        onEditAppearance: @escaping () -> Void,
        onSetLock: @escaping (ProfileLock?) -> Void,
        onSetKids: @escaping (Bool) -> Void,
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
        self.householdHasOtherLock = householdHasOtherLock
        self.onEditAppearance = onEditAppearance
        self.onSetLock = onSetLock
        self.onSetKids = onSetKids
        self.validatePlexPIN = validatePlexPIN
        self.onDelete = onDelete
        self.isUnlocked = isUnlocked
        self.onUnlock = onUnlock
        self.onClose = onClose
    }

    @Environment(\.themePalette) private var palette

    public var body: some View {
        #if os(tvOS)
        // Content-sized: roomy fixed width, intrinsic height from the header and
        // action rows. No ScrollView, fixed height, or filler Spacer.
        VStack(alignment: .leading, spacing: 28) {
            header
            ProfileActionsList(
                profile: profile,
                syncEnabled: syncEnabled,
                offersPlexPINReuse: offersPlexPINReuse,
                householdHasOtherLock: householdHasOtherLock,
                onEditAppearance: onEditAppearance,
                onSetLock: onSetLock,
                onSetKids: onSetKids,
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
                        householdHasOtherLock: householdHasOtherLock,
                        onEditAppearance: onEditAppearance,
                        onSetLock: onSetLock,
                        onSetKids: onSetKids,
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
