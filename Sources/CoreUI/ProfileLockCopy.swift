import Foundation

/// Copy for the Profile Lock feature, shared by tvOS and iOS.
///
/// The feature is a lock; the PIN is the credential people create/change/remove.
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

    public static let plexPIN = LocalizedStringResource(
        "settings.profileLock.plexPIN",
        defaultValue: "Plex PIN",
        comment: "Value shown when Plex asks for a PIN but the Plozz profile itself does not have a Profile Lock."
    )

    public static let explanation = LocalizedStringResource(
        "settings.profileLock.explanation",
        defaultValue: "Require a PIN to open this profile.",
        comment: "Explains what turning on a Profile Lock does."
    )

    public static let create = LocalizedStringResource(
        "settings.profileLock.create",
        defaultValue: "Create PIN",
        comment: "Button that starts setting a PIN on this profile. Short on purpose — it sits under a title that already says what's being locked."
    )

    public static let editPIN = LocalizedStringResource(
        "settings.profileLock.editPIN",
        defaultValue: "Change PIN",
        comment: "Button that replaces the existing Profile Lock PIN with a new one."
    )

    public static let delete = LocalizedStringResource(
        "settings.profileLock.delete",
        defaultValue: "Remove PIN",
        comment: "Button that removes the PIN so the profile opens without one."
    )

    public static let unlockTitle = LocalizedStringResource(
        "settings.profileLock.unlock.title",
        defaultValue: "Enter your PIN",
        comment: "Heading on the screen asking for a profile's PIN before opening it. No supporting line: the profile's name and avatar sit right beneath it, so anything else would just restate the obvious."
    )

    public static let createTitle = LocalizedStringResource(
        "settings.profileLock.create.title",
        defaultValue: "Create a PIN",
        comment: "Heading on the screen where a new PIN is chosen."
    )

    public static let createSubtitle = LocalizedStringResource(
        "settings.profileLock.create.subtitle",
        defaultValue: "Enter a 4-digit PIN to lock this profile.",
        comment: "Supporting line under the heading while choosing a new PIN, matching the wording on the preceding offer screen."
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
        defaultValue: "Use this for Plex too?",
        comment: "Asked after choosing a PIN, when this profile plays as a PIN-protected Plex Home user, so one PIN can open both."
    )

    public static let usePlexPINDetail = LocalizedStringResource(
        "settings.profileLock.usePlexPIN.detail",
        defaultValue: "This profile plays as a Plex user that asks for its own PIN. If it's the same one, Plozz can send it to Plex for you so you're only asked once.",
        comment: "Explains what saying yes does — including that the PIN is sent to Plex, which the person should know before agreeing."
    )

    public static let usePlexPINYes = LocalizedStringResource(
        "settings.profileLock.usePlexPIN.yes",
        defaultValue: "It's the Same PIN",
        comment: "Confirms that the Plozz PIN and the Plex PIN match, so Plozz may forward it."
    )

    public static let usePlexPINNo = LocalizedStringResource(
        "settings.profileLock.usePlexPIN.no",
        defaultValue: "Keep Separate",
        comment: "Declines forwarding the PIN to Plex; the Plex prompt will still appear separately."
    )

    /// Shown on the lock row when Plex — not Plozz — is what's asking for a PIN.
    /// Without it the row reads a bare "Off" on a profile you demonstrably can't
    /// open without a code, which looks like a bug.
    public static let plexAlreadyAsks = LocalizedStringResource(
        "settings.profileLock.plexAlreadyAsks",
        defaultValue: "Plex protects this user with its own PIN. Add a Profile Lock to protect the whole profile.",
        comment: "Second line on the Profile Lock row when the profile has no Plozz lock but does play as a PIN-protected Plex Home user."
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
        defaultValue: "Create a PIN?",
        comment: "Title of the optional PIN step shown after a profile is created."
    )

    public static let offerMessage = LocalizedStringResource(
        "settings.profileLock.offer.message",
        defaultValue: "Add a 4-digit PIN to lock this profile.",
        comment: "Brief explanation of what creating a Profile Lock does."
    )

    public static let offerMessageKids = LocalizedStringResource(
        "settings.profileLock.offer.message.kids",
        defaultValue: "Usually you lock the grown-ups' profiles instead.",
        comment: "Body of the prompt offering a PIN on a newly created Kids Profile. Locking the child's own profile is the common misunderstanding, so this points the other way in one line."
    )

    public static let unlockToEdit = LocalizedStringResource(
        "settings.profileLock.unlockToEdit",
        defaultValue: "Enter PIN to Edit",
        comment: "Row and heading shown when someone opens a locked profile's settings. Its PIN is required before anything about it can be changed."
    )

    public static let unlockToEditDetail = LocalizedStringResource(
        "settings.profileLock.unlockToEdit.detail",
        defaultValue: "This profile is locked.",
        comment: "Second line under 'Enter PIN to Edit'."
    )

    public static let manageTitle = LocalizedStringResource(
        "settings.profileLock.manage.title",
        defaultValue: "Enter your PIN",
        comment: "Heading shown when a PIN is needed before adding or editing a profile."
    )

    public static let manageSubtitle = LocalizedStringResource(
        "settings.profileLock.manage.subtitle",
        defaultValue: "Adding a profile needs the PIN from a locked profile.",
        comment: "Explains why a PIN is being asked for before adding a profile. Only shown for adding — editing a locked profile asks for that profile's own PIN, which needs no explanation."
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
        defaultValue: "Hides shared settings, so servers and profiles can't be changed from it. Doesn't filter what can be watched.",
        comment: "Explains what marking a profile as a Kids Profile does. The last sentence matters: there is no content filtering yet and the copy must not imply otherwise."
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
