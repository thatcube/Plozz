#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// The things you can do to a profile: change how it looks, lock it, restrict
/// it, delete it.
///
/// One implementation, two hosts — the picker's Edit sheet and Settings →
/// Everyone → Profiles → *name*. They were the same four choices rendered twice,
/// which is how they'd have drifted.
///
/// Notably there is **no** intermediate "Profile Lock" page. Selecting the lock
/// row does the thing: unlocked, it goes straight to choosing a PIN; locked, it
/// asks change-or-remove. A summary page whose only content was a button that
/// opened the real screen was two presses of nothing.
public struct ProfileActionsList: View {
    private let profile: Profile
    /// Whether the lock will reach the user's other devices. Drives the caveat.
    private let syncEnabled: Bool
    /// Whether this profile plays as a PIN-protected Plex Home user, so one PIN
    /// can satisfy both.
    private let offersPlexPINReuse: Bool
    /// Whether any *other* profile carries a lock — a Kids Profile only contains
    /// anyone if there's something locked to keep them out of.
    private let householdHasOtherLock: Bool
    private let onEditAppearance: () -> Void
    private let onSetLock: (ProfileLock?) -> Void
    private let onSetKids: (Bool) -> Void
    /// `nil` for a profile that can't be deleted (the household default).
    private let onDelete: (() -> Void)?

    public init(
        profile: Profile,
        syncEnabled: Bool,
        offersPlexPINReuse: Bool = false,
        householdHasOtherLock: Bool,
        onEditAppearance: @escaping () -> Void,
        onSetLock: @escaping (ProfileLock?) -> Void,
        onSetKids: @escaping (Bool) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.profile = profile
        self.syncEnabled = syncEnabled
        self.offersPlexPINReuse = offersPlexPINReuse
        self.householdHasOtherLock = householdHasOtherLock
        self.onEditAppearance = onEditAppearance
        self.onSetLock = onSetLock
        self.onSetKids = onSetKids
        self.onDelete = onDelete
    }

    @Environment(\.themePalette) private var palette
    @State private var settingPIN = false
    @State private var showingLockOptions = false
    @State private var confirmDelete = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(
                title: "Appearance",
                subtitle: "Name, avatar, and colour",
                systemImage: "paintpalette",
                action: onEditAppearance
            )

            row(
                title: ProfileLockCopy.title,
                subtitle: ProfileLockCopy.explanation,
                systemImage: profile.isLocked ? "lock.fill" : "lock.open",
                value: profile.isLocked ? ProfileLockCopy.on : ProfileLockCopy.off
            ) {
                // Straight to the thing. No summary page in between.
                if profile.isLocked {
                    showingLockOptions = true
                } else {
                    settingPIN = true
                }
            }

            Toggle(isOn: Binding(
                get: { profile.isKids },
                set: { onSetKids($0) }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(KidsProfileCopy.title)
                        .font(.callout.weight(.medium))
                    Text(KidsProfileCopy.explanation)
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if profile.isKids, !householdHasOtherLock {
                Label {
                    Text(KidsProfileCopy.pairWithLock)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(palette.secondaryText)
            }

            if let onDelete {
                row(
                    title: "Delete Profile",
                    subtitle: nil,
                    systemImage: "trash",
                    isDestructive: true
                ) {
                    confirmDelete = true
                }
            }
        }
        .fullScreenCover(isPresented: $settingPIN) {
            ProfileLockSetupView(
                profile: profile,
                offersPlexPINReuse: offersPlexPINReuse,
                syncEnabled: syncEnabled,
                onComplete: { lock in
                    onSetLock(lock)
                    settingPIN = false
                },
                onCancel: { settingPIN = false }
            )
        }
        .confirmationDialog(
            Text(ProfileLockCopy.title),
            isPresented: $showingLockOptions,
            titleVisibility: .visible
        ) {
            Button(String(localized: ProfileLockCopy.editPIN)) { settingPIN = true }
            Button(String(localized: ProfileLockCopy.delete), role: .destructive) { onSetLock(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ProfileLockCopy.forgotPINDetail)
        }
        .alert("Delete this profile?", isPresented: $confirmDelete) {
            Button("Delete Profile", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting removes this profile's preferences (theme, playback, subtitles, spoilers, trackers) and which servers it includes. Signed-in server accounts stay shared.")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource?,
        systemImage: String,
        value: LocalizedStringResource? = nil,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if let value {
                    Text(value).foregroundStyle(palette.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .foregroundStyle(isDestructive ? Color.red : palette.primaryText)
    }
}
#endif
