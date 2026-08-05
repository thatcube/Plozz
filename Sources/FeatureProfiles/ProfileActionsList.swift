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
    private let hasParentalPIN: Bool
    /// Whether this profile's escalation-capable actions are sealed behind the
    /// household Parental PIN.
    ///
    /// The caller decides, because only it knows whether the PIN has already been
    /// entered on this screen. When sealed, only Appearance is offered: the Kids
    /// flag, the profile's own lock and Delete are all ways a child could undo
    /// their own restrictions from inside.
    private let restrictedActionsSealed: Bool
    private let onEditAppearance: () -> Void
    /// Asks the host to show the Profile Lock PIN setup.
    ///
    /// Presentation belongs to the host, exactly like `onEditAppearance`, because
    /// the right mechanism differs by where this list is shown: the profile
    /// picker can present a cover, but Settings has to PUSH — modals asked for
    /// from inside the Settings tab are silently dropped when `RootView`'s
    /// stacked covers contest the slot. Owning the presentation here would mean
    /// picking one and being wrong half the time.
    private let onEditLock: () -> Void
    /// Asks the host to show the household Parental PIN setup. Same reasoning.
    private let onCreateParentalPIN: () -> Void
    private let onSetLock: (ProfileLock?) -> Void
    private let onSetKids: (Bool) -> Void
    /// Sets the household's Parental PIN, offered from the Kids row when none
    /// exists yet.
    private let onSetParentalPIN: (ParentalPIN?) -> Void
    private let validatePlexPIN: (String) async -> PlexPINValidationResult
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
        hasParentalPIN: Bool,
        restrictedActionsSealed: Bool = false,
        onEditAppearance: @escaping () -> Void,
        onEditLock: @escaping () -> Void = {},
        onCreateParentalPIN: @escaping () -> Void = {},
        onSetLock: @escaping (ProfileLock?) -> Void,
        onSetKids: @escaping (Bool) -> Void,
        onSetParentalPIN: @escaping (ParentalPIN?) -> Void = { _ in },
        validatePlexPIN: @escaping (String) async -> PlexPINValidationResult = {
            _ in .unavailable
        },
        onDelete: (() -> Void)? = nil,
        isUnlocked: Bool = true,
        onUnlock: @escaping () -> Void = {}
    ) {
        self.profile = profile
        self.syncEnabled = syncEnabled
        self.offersPlexPINReuse = offersPlexPINReuse
        self.hasParentalPIN = hasParentalPIN
        self.restrictedActionsSealed = restrictedActionsSealed
        self.onEditAppearance = onEditAppearance
        self.onEditLock = onEditLock
        self.onCreateParentalPIN = onCreateParentalPIN
        self.onSetLock = onSetLock
        self.onSetKids = onSetKids
        self.onSetParentalPIN = onSetParentalPIN
        self.validatePlexPIN = validatePlexPIN
        self.onDelete = onDelete
        self.isUnlocked = isUnlocked
        self.onUnlock = onUnlock
    }

    @Environment(\.themePalette) private var palette
    @State private var unlocking = false
    @State private var unlockError: LocalizedStringResource?
    @State private var showingLockOptions = false
    @State private var showingKidsOptions = false
    @State private var confirmDelete = false
    /// Immediate sheet-local unlock result. The app-level unlocked-id set is
    /// deliberately non-observable, so the Bool passed when this sheet opened
    /// cannot update until the sheet is recreated. Keep the successful verdict
    /// here too so this presentation unlocks in place.
    @State private var didUnlockHere = false

    /// A locked profile is sealed until its own PIN is entered — every route in,
    /// not just the picker. Editing includes *removing the lock*, so anyone who
    /// can't open the profile must not be able to unlock it from the outside; a
    /// gate on one entry point would just move the hole. Kids Profiles are no
    /// exception: they can carry a PIN too.
    private var isSealed: Bool {
        profile.isLocked && !isUnlocked && !didUnlockHere
    }

    public var body: some View {
        Group {
            if unlocking {
                // Rendered IN PLACE, not presented. Every host of this list is
                // already inside a presentation — the picker's actions cover, the
                // iOS Settings sheet, a tvOS navigation stack under RootView's
                // stacked covers — and a modal asked for from a covered view is
                // silently dropped, which would leave the unlock button dead.
                PINEntryScaffold(
                    title: ProfileLockCopy.unlockToEdit,
                    name: Text(verbatim: profile.name),
                    errorMessage: unlockError,
                    onSubmit: submitUnlock,
                    onCancel: { unlocking = false; unlockError = nil }
                ) {
                    ProfileAvatarView(profile: profile, size: PINLayout.badgeSize)
                }
            } else if isSealed {
                sealedContent
            } else {
                actions
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
            unlockError = ProfileLockCopy.incorrectPIN
            return
        }
        unlockError = nil
        unlocking = false
        didUnlockHere = true
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

            if !restrictedActionsSealed {
            actionRow(
                icon: profile.isLocked || offersPlexPINReuse
                    ? "lock.fill"
                    : "lock.open",
                title: ProfileLockCopy.title,
                // A profile bound to a PIN-protected Plex user already asks for a
                // code, so a bare "Off" here reads as a bug. Say which lock is
                // which instead: Plex guards playing AS that user, a Profile Lock
                // guards the whole profile.
                subtitle: (!profile.isLocked && offersPlexPINReuse) ? ProfileLockCopy.plexAlreadyAsks : nil,
                value: profile.isLocked
                    ? ProfileLockCopy.on
                    : (offersPlexPINReuse
                        ? ProfileLockCopy.plexPIN
                        : ProfileLockCopy.off)
            ) {
                // Straight to the thing. No summary page in between.
                if profile.isLocked {
                    showingLockOptions = true
                } else {
                    onEditLock()
                }
            }

            actionRow(
                icon: "figure.and.child.holdinghands",
                title: KidsProfileCopy.title,
                value: profile.isKids ? ProfileLockCopy.on : ProfileLockCopy.off
            ) {
                showingKidsOptions = true
            }

            // A Kids Profile with no household Parental PIN restricts nothing —
            // say so here rather than let the "On" above imply otherwise. This
            // replaced a nudge to lock your own profile, which was the
            // workaround for not having a Parental PIN.
            if profile.isKids, !hasParentalPIN {
                Label {
                    Text(KidsProfileCopy.kidsNeedsParentalPIN)
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
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete Profile", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            }
        }
        .confirmationDialog(
            Text(ProfileLockCopy.title),
            isPresented: $showingLockOptions,
            titleVisibility: .visible
        ) {
            Button(String(localized: ProfileLockCopy.editPIN)) { onEditLock() }
            Button(String(localized: ProfileLockCopy.delete), role: .destructive) { onSetLock(nil) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            Text(KidsProfileCopy.title),
            isPresented: $showingKidsOptions,
            titleVisibility: .visible
        ) {
            // Offered here rather than pointed at from a warning: a Kids Profile
            // hides the household section, so "go to Everyone" is an instruction
            // this profile can't follow.
            if !hasParentalPIN {
                Button(String(localized: KidsProfileCopy.parentalPINCreate)) {
                    onCreateParentalPIN()
                }
            }
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
    /// the text unreadable against the inverted focus card.
    @ViewBuilder
    private func actionRow(
        icon: String,
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource? = nil,
        value: LocalizedStringResource? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
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
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .settingsRowSecondary()
                }
            }
        }
        .buttonStyle(SettingsFocusButtonStyle())
    }
}
#endif
