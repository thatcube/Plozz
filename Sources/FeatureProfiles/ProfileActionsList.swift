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
/// Rows are `SettingsRowLabel` + `SettingsFocusButtonStyle`, the same pair every
/// other row in Settings uses, so these read as one control family with the rest
/// of the app rather than as a bespoke list that happens to look similar.
///
/// Every row **opens something** and carries a chevron to say so. Kids Profile is
/// deliberately not an inline switch: it has a real consequence and an honest
/// caveat (it restricts settings, not content), and a switch you can nudge past
/// while scrolling is the wrong affordance for that.
///
/// Notably there is no intermediate "Profile Lock" page. Selecting the lock row
/// does the thing: unlocked, it goes straight to choosing a PIN; locked, it asks
/// change-or-remove.
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
    /// Whether this profile's PIN has already been proved during this app run.
    private let isUnlocked: Bool
    /// Called when the PIN is entered correctly here, so the host can remember it
    /// for the rest of the run.
    private let onUnlock: () -> Void

    public init(
        profile: Profile,
        syncEnabled: Bool,
        offersPlexPINReuse: Bool = false,
        householdHasOtherLock: Bool,
        onEditAppearance: @escaping () -> Void,
        onSetLock: @escaping (ProfileLock?) -> Void,
        onSetKids: @escaping (Bool) -> Void,
        onDelete: (() -> Void)? = nil,
        isUnlocked: Bool = true,
        onUnlock: @escaping () -> Void = {}
    ) {
        self.profile = profile
        self.syncEnabled = syncEnabled
        self.offersPlexPINReuse = offersPlexPINReuse
        self.householdHasOtherLock = householdHasOtherLock
        self.onEditAppearance = onEditAppearance
        self.onSetLock = onSetLock
        self.onSetKids = onSetKids
        self.onDelete = onDelete
        self.isUnlocked = isUnlocked
        self.onUnlock = onUnlock
    }

    @Environment(\.themePalette) private var palette
    @State private var unlocking = false
    @State private var unlockError: String?
    @State private var settingPIN = false
    @State private var showingLockOptions = false
    @State private var showingKidsOptions = false
    @State private var confirmDelete = false

    /// A locked profile is sealed until its own PIN is entered — every route in,
    /// not just the picker. Editing includes *removing the lock*, so anyone who
    /// can't open the profile must not be able to unlock it from the outside; a
    /// gate on one entry point would just move the hole. Kids Profiles are no
    /// exception: they can carry a PIN too.
    private var isSealed: Bool { profile.isLocked && !isUnlocked }

    public var body: some View {
        Group {
            if isSealed {
                sealedContent
            } else {
                actions
            }
        }
        .fullScreenCover(isPresented: $unlocking) {
            PINEntryScaffold(
                title: ProfileLockCopy.unlockToEdit,
                name: profile.name,
                errorMessage: unlockError,
                onSubmit: submitUnlock,
                onCancel: { unlocking = false; unlockError = nil }
            ) {
                ProfileAvatarView(profile: profile, size: PINLayout.badgeSize)
            }
        }
    }

    /// What a locked profile shows instead of its settings: one way in.
    @ViewBuilder
    private var sealedContent: some View {
        VStack(spacing: 14) {
            actionRow(
                icon: "lock.fill",
                title: ProfileLockCopy.unlockToEdit,
                subtitle: ProfileLockCopy.unlockToEditDetail
            ) {
                unlockError = nil
                unlocking = true
            }
        }
    }

    private func submitUnlock(_ pin: String) {
        guard let lock = profile.lock, lock.matches(pin: pin) else {
            unlockError = String(localized: "Incorrect PIN. Try again.")
            return
        }
        unlockError = nil
        unlocking = false
        onUnlock()
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 14) {
            actionRow(
                icon: "paintpalette",
                title: "Appearance",
                subtitle: "Name, avatar, and color",
                action: onEditAppearance
            )

            actionRow(
                icon: profile.isLocked ? "lock.fill" : "lock.open",
                title: ProfileLockCopy.title,
                // A profile bound to a PIN-protected Plex user already asks for a
                // code, so a bare "Off" here reads as a bug. Say which lock is
                // which instead: Plex guards playing AS that user, a Profile Lock
                // guards the whole profile.
                subtitle: (!profile.isLocked && offersPlexPINReuse) ? ProfileLockCopy.plexAlreadyAsks : nil,
                value: profile.isLocked ? ProfileLockCopy.on : ProfileLockCopy.off
            ) {
                // Straight to the thing. No summary page in between.
                if profile.isLocked {
                    showingLockOptions = true
                } else {
                    settingPIN = true
                }
            }

            actionRow(
                icon: "figure.and.child.holdinghands",
                title: KidsProfileCopy.title,
                value: profile.isKids ? ProfileLockCopy.on : ProfileLockCopy.off
            ) {
                showingKidsOptions = true
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
            }

            if onDelete != nil {
                actionRow(
                    icon: "trash",
                    title: "Delete Profile",
                    subtitle: nil,
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
        .confirmationDialog(
            Text(KidsProfileCopy.title),
            isPresented: $showingKidsOptions,
            titleVisibility: .visible
        ) {
            if profile.isKids {
                Button(String(localized: KidsProfileCopy.turnOff), role: .destructive) { onSetKids(false) }
            } else {
                Button(String(localized: KidsProfileCopy.turnOn)) { onSetKids(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(KidsProfileCopy.explanation)
        }
        .alert("Delete this profile?", isPresented: $confirmDelete) {
            Button("Delete Profile", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting removes this profile's preferences (theme, playback, subtitles, spoilers, trackers) and which servers it includes. Signed-in server accounts stay shared.")
        }
    }

    // MARK: Rows

    /// A row in the app's standard settings shape: icon, title, optional second
    /// line, then a value and a chevron. The chevron is the point — every one of
    /// these opens a screen or a choice, and none changes state in place.
    ///
    /// Deliberately sets **no** foreground of its own. `SettingsFocusButtonStyle`
    /// inverts the whole card on focus and publishes the matching foreground down
    /// the environment, which `.settingsRowSecondary()` and `.settingsRowIcon()`
    /// read; hard-coding a colour here would pin the row to one theme and leave
    /// the text unreadable against the inverted focus card. The destructive row
    /// is the one exception, matching Sign Out elsewhere in Settings.
    @ViewBuilder
    private func actionRow(
        icon: String,
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource? = nil,
        value: LocalizedStringResource? = nil,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            SettingsRowLabel(icon: icon, title: title) {
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .settingsRowSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                HStack(spacing: 16) {
                    if let value {
                        Text(value)
                            .font(.subheadline)
                            .settingsRowSecondary()
                            .lineLimit(1)
                    }
                    if !isDestructive {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .settingsRowSecondary()
                    }
                }
            }
            .modifier(DestructiveRowTint(isDestructive: isDestructive))
        }
        .buttonStyle(SettingsFocusButtonStyle())
    }
}

/// Paints a row red only when it destroys something, leaving every other row to
/// inherit the theme- and focus-aware colours from the environment.
private struct DestructiveRowTint: ViewModifier {
    let isDestructive: Bool

    func body(content: Content) -> some View {
        if isDestructive {
            content.foregroundStyle(.red)
        } else {
            content
        }
    }
}
#endif
