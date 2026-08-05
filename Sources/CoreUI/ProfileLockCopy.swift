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

    public static let createAlongsidePlexTitle = LocalizedStringResource(
        "settings.profileLock.createAlongsidePlex.title",
        defaultValue: "Add a Profile PIN?",
        comment: "Heading when adding a Plozz Profile Lock to a profile already protected by its selected Plex user's PIN."
    )

    public static let createAlongsidePlexSubtitle = LocalizedStringResource(
        "settings.profileLock.createAlongsidePlex.subtitle",
        defaultValue: "This user already has a Plex PIN. Add another to keep the profile locked if its Plex user changes.",
        comment: "Explains why a separate Plozz PIN can still be useful when the selected Plex user already requires a PIN."
    )

    public static let confirm = LocalizedStringResource(
        "settings.profileLock.confirm",
        defaultValue: "Enter your PIN again",
        comment: "Heading for the second, confirming entry of a new PIN."
    )

    /// Shown when an entered PIN doesn't match.
    ///
    /// One definition: six call sites had this literal inline, each resolving it
    /// eagerly with `String(localized:)`, so a translator saw six identical
    /// strings and a language change froze whichever had already been built.
    public static let incorrectPIN = LocalizedStringResource(
        "profileLock.incorrectPIN",
        defaultValue: "Incorrect PIN. Try again.",
        comment: "Shown under the PIN pad when the entered PIN is wrong."
    )

    /// Shown when Plex rejects a switch for a reason other than a wrong PIN.
    public static let plexSwitchFailed = LocalizedStringResource(
        "plexPIN.switchFailed",
        defaultValue: "Couldn’t switch Plex user. Please try again.",
        comment: "Shown under the Plex PIN pad when switching users failed for a reason other than a wrong PIN."
    )

    public static let mismatch = LocalizedStringResource(
        "settings.profileLock.mismatch",
        defaultValue: "Those PINs didn't match. Start again.",
        comment: "Error shown when the confirming PIN entry differs from the first."
    )

    public static let usePlexPIN = LocalizedStringResource(
        "settings.profileLock.usePlexPIN",
        defaultValue: "Same as your Plex PIN?",
        comment: "Asked after choosing a PIN, when this profile plays as a PIN-protected Plex Home user, so one PIN can open both."
    )

    public static let usePlexPINDetail = LocalizedStringResource(
        "settings.profileLock.usePlexPIN.detail",
        defaultValue: "If yes, Plozz can use one PIN entry for both.",
        comment: "Explains what saying yes does — including that the PIN is sent to Plex, which the person should know before agreeing."
    )

    public static let usePlexPINYes = LocalizedStringResource(
        "settings.profileLock.usePlexPIN.yes",
        defaultValue: "Yes, Same PIN",
        comment: "Confirms that the Plozz PIN and the Plex PIN match, so Plozz may forward it."
    )

    public static let usePlexPINNo = LocalizedStringResource(
        "settings.profileLock.usePlexPIN.no",
        defaultValue: "No, Keep Separate",
        comment: "Declines forwarding the PIN to Plex; the Plex prompt will still appear separately."
    )

    public static let plexPINMismatch = LocalizedStringResource(
        "settings.profileLock.plexPINMismatch",
        defaultValue: "That isn’t this user’s Plex PIN.",
        comment: "Error shown when the proposed shared Profile Lock PIN is rejected by Plex."
    )

    public static let plexPINUnavailableTitle = LocalizedStringResource(
        "settings.profileLock.plexPINUnavailable.title",
        defaultValue: "Couldn’t verify the Plex PIN",
        comment: "Title shown when Plex cannot be reached while verifying a proposed shared PIN."
    )

    public static let plexPINUnavailableDetail = LocalizedStringResource(
        "settings.profileLock.plexPINUnavailable.detail",
        defaultValue: "Try again, or keep the Profile Lock PIN separate.",
        comment: "Recovery choices when Plex PIN verification is unavailable."
    )

    /// Shown on the lock row when Plex — not Plozz — is what's asking for a PIN.
    /// Without it the row reads a bare "Off" on a profile you demonstrably can't
    /// open without a code, which looks like a bug.
    public static let plexAlreadyAsks = LocalizedStringResource(
        "settings.profileLock.plexAlreadyAsks",
        defaultValue: "This user already has a Plex PIN.",
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

    // MARK: Parental PIN
    //
    // The household PIN that turns a Kids Profile from curation into
    // enforcement. Called a "Parental PIN" rather than another kind of lock,
    // because a Profile Lock is personal ("don't open my profile") while this is
    // shared ("you're allowed to change what the child can reach"). Netflix and
    // Apple keep those two ideas apart too; running them together is what forces
    // someone to put a PIN on four grown-up accounts to protect one child.
    //
    // This replaced a nudge telling people to lock their own profile, which was
    // a workaround for not having this.

    public static let parentalPIN = LocalizedStringResource(
        "settings.parentalPIN.title",
        defaultValue: "Parental PIN",
        comment: "The household PIN required to leave a Kids Profile or change its restricted settings."
    )

    public static let parentalPINExplanation = LocalizedStringResource(
        "settings.parentalPIN.explanation",
        defaultValue: "One PIN for the household. Without it, Kids Profiles aren't restricted.",
        comment: "Subtitle of the Parental PIN page. Must stay honest that a Kids Profile alone restricts nothing."
    )

    /// Shown under the Kids Profile row when the household has no Parental PIN.
    ///
    /// Says the state and the fix, and nothing else. This replaced a line that
    /// reused the Parental PIN page's subtitle, which read as a non-sequitur
    /// under a toggle: it opened with "One PIN for the household" with nothing to
    /// attach that to, and said "this screen" of a screen it wasn't on.
    public static let kidsNeedsParentalPIN = LocalizedStringResource(
        "settings.kidsProfile.needsParentalPIN",
        defaultValue: "Not restricted yet — open Kids Profile to add a Parental PIN.",
        comment: "Warning under the Kids Profile row when no household Parental PIN exists. Points at the row directly, because a Kids Profile hides the household section where the PIN otherwise lives."
    )

    public static let parentalPINCreate = LocalizedStringResource(
        "settings.parentalPIN.create",
        defaultValue: "Create a Parental PIN",
        comment: "Action that sets the household's Parental PIN for the first time."
    )

    public static let parentalPINChange = LocalizedStringResource(
        "settings.parentalPIN.change",
        defaultValue: "Change Parental PIN",
        comment: "Action that replaces the household's existing Parental PIN."
    )

    public static let parentalPINRemove = LocalizedStringResource(
        "settings.parentalPIN.remove",
        defaultValue: "Remove Parental PIN",
        comment: "Action that deletes the household's Parental PIN."
    )

    public static let parentalPINRemoveDetail = LocalizedStringResource(
        "settings.parentalPIN.removeDetail",
        defaultValue: "Kids Profiles stay on, but nothing will be locked.",
        comment: "Shown when removing the household Parental PIN, clarifying that Kids Profiles are not turned off by it."
    )

    public static let parentalPINEnter = LocalizedStringResource(
        "settings.parentalPIN.enter",
        defaultValue: "Enter the Parental PIN",
        comment: "Title of the PIN screen shown when leaving a Kids Profile or opening its restricted settings."
    )

    public static let parentalPINSetTitle = LocalizedStringResource(
        "settings.parentalPIN.setTitle",
        defaultValue: "Create a Parental PIN",
        comment: "Title of the screen that collects a new household Parental PIN."
    )

    public static let parentalPINConfirmTitle = LocalizedStringResource(
        "settings.parentalPIN.confirmTitle",
        defaultValue: "Enter it again",
        comment: "Title of the second step when creating a Parental PIN, confirming the digits match."
    )

    // The parent-controlled group on a Kids Profile's settings page.
    //
    // A section, not a door. An earlier version put one row called "Grown-ups"
    // where Libraries had been: tapping it asked for a PIN and returned you to
    // the same list, so it was named for contents it never had. Rows keep their
    // own names now — a locked Libraries row still says Libraries — and the
    // grouping carries the meaning.

    public static let parentalControls = LocalizedStringResource(
        "settings.parentalControls.title",
        defaultValue: "Parental Controls",
        comment: "Heading for the group of settings on a Kids Profile that only a grown-up may change."
    )

    public static let parentalControlsOpen = LocalizedStringResource(
        "settings.parentalControls.open",
        defaultValue: "Unlocked until you switch profiles",
        comment: "Subtitle of the Parental Controls group after the Parental PIN has been entered, making the limited duration clear."
    )

    /// Distinct from the "Appearance" row that holds theme and layout — this one
    /// is the profile's own identity, and naming both "Appearance" on one page
    /// would be two different things wearing the same word.
    public static let nameAndAvatar = LocalizedStringResource(
        "settings.profile.nameAndAvatar",
        defaultValue: "Name & Avatar",
        comment: "Row opening the profile's own name, avatar and colour. Available to a Kids Profile, unlike the parental controls."
    )

    /// Label for the control that opens the profile picker.
    ///
    /// "Switch Profile" is a promise there's someone to switch TO. With a single
    /// profile the picker is still worth opening — you can add one or edit the
    /// one you have — so the label says that instead of offering a switch that
    /// can't happen.
    public static func openProfiles(profileCount: Int) -> LocalizedStringResource {
        profileCount > 1
            ? LocalizedStringResource(
                "settings.profiles.switch",
                defaultValue: "Switch Profile",
                comment: "Opens the profile picker when the household has more than one profile."
            )
            : LocalizedStringResource(
                "settings.profiles.manage",
                defaultValue: "Add or Edit Profiles",
                comment: "Opens the profile picker when the household has only one profile, so there is nothing to switch to."
            )
    }

    public static let manageProfile = LocalizedStringResource(
        "settings.parentalControls.manageProfile",
        defaultValue: "Manage Profile",
        comment: "Row inside Parental Controls leading to this profile's own management page."
    )

    public static let profileManagementDetail = LocalizedStringResource(
        "settings.parentalControls.profileDetail",
        defaultValue: "Name, avatar, lock, and Kids Profile",
        comment: "Subtitle of the Manage Profile row. Lists what the page holds; must not repeat the row's own title."
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

}
