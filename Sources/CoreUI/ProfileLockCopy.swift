import Foundation

/// Copy for the Profile Lock feature, shared by tvOS and iOS.
///
/// Wording is borrowed from Netflix's Profile Lock rather than invented, because
/// this is a feature people meet elsewhere first and the vocabulary is already
/// settled: "Profile Lock", "Create a Profile Lock", "Enter 4 numbers...",
/// "Forgot PIN?". Matching it means someone who has locked a Netflix profile
/// already knows what this row does.
public enum ProfileLockCopy {
    public static let title = LocalizedStringResource(
        "settings.profileLock.title",
        defaultValue: "Profile Lock",
        comment: "Settings row for an optional 4-digit PIN that must be entered to open this profile."
    )

    public static let on = LocalizedStringResource(
        "settings.profileLock.on",
        defaultValue: "On",
        comment: "Value shown on the Profile Lock row when a PIN is set."
    )

    public static let off = LocalizedStringResource(
        "settings.profileLock.off",
        defaultValue: "Off",
        comment: "Value shown on the Profile Lock row when no PIN is set."
    )

    public static let explanation = LocalizedStringResource(
        "settings.profileLock.explanation",
        defaultValue: "Require a 4-digit PIN to open this profile. Anyone can still use the profiles that aren't locked.",
        comment: "Explains what turning on a Profile Lock does. The second sentence is important: locking your own profile is how you keep a child out of it, since child profiles are left open."
    )

    public static let create = LocalizedStringResource(
        "settings.profileLock.create",
        defaultValue: "Create a Profile Lock",
        comment: "Button that starts setting a PIN on this profile."
    )

    public static let editPIN = LocalizedStringResource(
        "settings.profileLock.editPIN",
        defaultValue: "Edit PIN",
        comment: "Button that replaces the existing Profile Lock PIN with a new one."
    )

    public static let delete = LocalizedStringResource(
        "settings.profileLock.delete",
        defaultValue: "Delete Profile Lock",
        comment: "Button that removes the PIN so the profile opens without one."
    )

    public static let unlockTitle = LocalizedStringResource(
        "settings.profileLock.unlock.title",
        defaultValue: "Enter your PIN",
        comment: "Heading on the screen asking for a profile's PIN before opening it. No supporting line: the profile's name and avatar sit right beneath it, so anything else would just restate the obvious."
    )

    public static let createTitle = LocalizedStringResource(
        "settings.profileLock.create.title",
        defaultValue: "Create a Profile Lock",
        comment: "Heading on the screen where a new PIN is chosen."
    )

    /// Says what the PIN will DO, rather than restating the instruction. The pad
    /// and its four dots already say "type four numbers"; a subtitle that repeats
    /// it is two sentences of nothing.
    public static let createSubtitle = LocalizedStringResource(
        "settings.profileLock.create.subtitle",
        defaultValue: "This PIN will be needed to open this profile.",
        comment: "Supporting line under the heading while choosing a new PIN."
    )

    public static let confirm = LocalizedStringResource(
        "settings.profileLock.confirm",
        defaultValue: "Enter your PIN again",
        comment: "Heading for the second, confirming entry of a new PIN."
    )

    public static let mismatch = LocalizedStringResource(
        "settings.profileLock.mismatch",
        defaultValue: "Those PINs didn't match. Start again.",
        comment: "Error shown when the confirming PIN entry differs from the first."
    )

    public static let usePlexPIN = LocalizedStringResource(
        "settings.profileLock.usePlexPIN",
        defaultValue: "Use my Plex PIN",
        comment: "Toggle offered when this profile plays as a PIN-protected Plex Home user, so one PIN opens both."
    )

    public static let usePlexPINDetail = LocalizedStringResource(
        "settings.profileLock.usePlexPIN.detail",
        defaultValue: "This profile plays as a Plex user that already asks for a PIN. Enter the same one and you'll only be asked once.",
        comment: "Explains the 'Use my Plex PIN' option."
    )

    /// Shown under the keypad, and on the setup screen, when iCloud Sync is off.
    ///
    /// Worth saying out loud: a parent setting a lock reasonably assumes it
    /// applies everywhere, and with Sync off it does not — the same profile is
    /// still open on the iPhone.
    public static let lockIsDeviceOnly = LocalizedStringResource(
        "settings.profileLock.deviceOnly",
        defaultValue: "iCloud Sync is off, so this lock only applies on this device.",
        comment: "Caveat shown when a Profile Lock is set while iCloud Sync is off, meaning the user's other devices won't have the lock."
    )

    public static let offerTitle = LocalizedStringResource(
        "settings.profileLock.offer.title",
        defaultValue: "Lock this profile?",
        comment: "Title of the prompt offered immediately after a profile is created, asking whether to set a PIN."
    )

    public static let offerMessage = LocalizedStringResource(
        "settings.profileLock.offer.message",
        defaultValue: "A 4-digit PIN will be needed to open it. You can change this later in Settings.",
        comment: "Body of the prompt offering a PIN on a newly created ordinary profile."
    )

    public static let offerMessageKids = LocalizedStringResource(
        "settings.profileLock.offer.message.kids",
        defaultValue: "Kids profiles are usually left open — it's the grown-ups' profiles that need locking, so a child can't switch into them. You can lock this one anyway if you'd like.",
        comment: "Body of the prompt offering a PIN on a newly created Kids Profile. It explains why the answer is usually no, since locking the child's own profile is the common misunderstanding."
    )

    public static let manageTitle = LocalizedStringResource(
        "settings.profileLock.manage.title",
        defaultValue: "Enter your PIN",
        comment: "Heading shown when someone tries to add or edit profiles and the household has a locked profile, so the action needs proving first."
    )

    public static let manageSubtitle = LocalizedStringResource(
        "settings.profileLock.manage.subtitle",
        defaultValue: "Adding or changing profiles needs the PIN from a locked profile.",
        comment: "Explains why a PIN is being asked for before managing profiles."
    )

    public static let forgotPIN = LocalizedStringResource(
        "settings.profileLock.forgot",
        defaultValue: "Forgot PIN?",
        comment: "Button offering a way out when the user can't remember their Profile Lock PIN."
    )

    public static let forgotPINDetail = LocalizedStringResource(
        "settings.profileLock.forgot.detail",
        defaultValue: "Removing the lock from another signed-in device, or signing out and setting Plozz up again, will clear it.",
        comment: "Explains how to recover from a forgotten Profile Lock PIN. There is no email reset because Plozz has no account of its own."
    )
}

/// Copy for Kids Profiles — the restriction half of the lock.
///
/// "Kids Profile" is the term Netflix, Disney+ and Hulu all use, so it needs no
/// explaining. The description is deliberately precise about what it does and
/// does NOT do: Plozz has no maturity filtering yet, so promising "only suitable
/// content" would be a lie.
public enum KidsProfileCopy {
    public static let title = LocalizedStringResource(
        "settings.kidsProfile.title",
        defaultValue: "Kids Profile",
        comment: "Toggle marking a profile as a child's, which hides the shared household settings while it's in use."
    )

    public static let explanation = LocalizedStringResource(
        "settings.kidsProfile.explanation",
        defaultValue: "Hides shared settings while this profile is in use, so servers, profiles and sign-outs can't be changed from it. It doesn't filter what can be watched.",
        comment: "Explains exactly what marking a profile as a Kids Profile does. The last sentence matters: there is no content filtering yet and the copy must not imply otherwise."
    )

    public static let pairWithLock = LocalizedStringResource(
        "settings.kidsProfile.pairWithLock",
        defaultValue: "Lock your own profile too, so this one can't be used to open yours.",
        comment: "Nudge shown when a Kids Profile is turned on but the current profile has no Profile Lock — the two features only work as a pair."
    )

    public static let addTile = LocalizedStringResource(
        "settings.kidsProfile.addTile",
        defaultValue: "Add Kids Profile",
        comment: "Tile on the profile picker that creates a new restricted profile, shown beside the ordinary Add Profile tile."
    )

    public static let turnOn = LocalizedStringResource(
        "settings.kidsProfile.turnOn",
        defaultValue: "Turn On Kids Profile",
        comment: "Confirming button that marks a profile as a child's."
    )

    public static let turnOff = LocalizedStringResource(
        "settings.kidsProfile.turnOff",
        defaultValue: "Turn Off Kids Profile",
        comment: "Confirming button that lifts a profile's Kids restriction."
    )

    public static let restrictedHere = LocalizedStringResource(
        "settings.kidsProfile.restrictedHere",
        defaultValue: "Shared settings are hidden on a Kids Profile. Switch to another profile to change them.",
        comment: "Shown in Settings while a Kids Profile is active, explaining why the shared section isn't there."
    )
}
