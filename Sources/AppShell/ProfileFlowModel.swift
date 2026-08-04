import Foundation
import Observation
import AppRuntime
import CoreModels
import FeatureMusic
import FeatureProfiles

/// The profile-flow + household facet, extracted from `AppState`.
///
/// Owns the profile-switching orchestration (launch picker state, switch/create/
/// edit/remove sequencing) and the household membership model (enable/disable
/// profiles, ask-on-startup, per-server inclusion). This is the profile lifecycle
/// coordinator the earlier batches' injected `switchProfile` callback lands on —
/// now that this facet is the owner, the Plex-home-user facet's PIN-cancel
/// fallback wires directly to `switchProfile(to:)`.
///
/// A profile change re-scopes nearly everything, so this facet depends INTO the
/// other facets/models via their typed interfaces — `ProfilesModel`,
/// `AccountsProvidersModel` (reload + active set), `PlexHomeUsersModel` (identity
/// re-apply), `ProfileSettingsModel` (per-profile settings rebuild), and the
/// app-scoped `AudioPlaybackController` (stop on switch) — plus two injected
/// closures for the domains still owned by `AppState`: re-scoping the tracker
/// services and discarding a removed profile's watch reconciler. It never reaches
/// back into `AppState`. Kept `@MainActor @Observable` so the picker-state
/// observation is identical to before.
@MainActor
@Observable
public final class ProfileFlowModel {
    /// When `true`, `RootView` shows the profile picker instead of the signed-in
    /// UI (shown at launch with >1 profile, and from "Switch Profile").
    public private(set) var isChoosingProfile = false
    /// Whether the profile picker may be dismissed without choosing (false at the
    /// mandatory launch picker; true when opened from Settings behind an active
    /// profile).
    public private(set) var isProfileSelectionCancelable = false
    /// True while the one-time theme picker for a just-created in-app profile is
    /// showing (cleared by `finishPickingThemeForNewProfile()`).
    public private(set) var isPickingThemeForNewProfile = false

    @ObservationIgnored private let profilesModel: ProfilesModel
    @ObservationIgnored private let accountsProviders: AccountsProvidersModel
    @ObservationIgnored private let plexHomeUsers: PlexHomeUsersModel
    @ObservationIgnored private let profileSettings: ProfileSettingsModel
    @ObservationIgnored private let audioController: AudioPlaybackController
    /// Re-points the tracker services (Trakt/Simkl/Seerr/AniList/MAL/Last.fm) +
    /// identity index at the active profile. Injected because the tracker services
    /// still live on `AppState`.
    @ObservationIgnored private let updateTrackersForActiveProfile: @MainActor () -> Void
    /// Drops a removed profile's retained watch reconciler. Injected because the
    /// watch-outbox domain still lives on `AppState`.
    @ObservationIgnored private let discardWatchReconciler: @MainActor (String) -> Void
    /// Removes all durable media aliases owned by a deleted profile.
    @ObservationIgnored private let removeMediaAliases: @MainActor (String) -> Void
    @ObservationIgnored private let activateUniversalWatchlist:
        @MainActor () -> Void

    public init(
        profilesModel: ProfilesModel,
        accountsProviders: AccountsProvidersModel,
        plexHomeUsers: PlexHomeUsersModel,
        profileSettings: ProfileSettingsModel,
        audioController: AudioPlaybackController,
        updateTrackersForActiveProfile: @escaping @MainActor () -> Void,
        discardWatchReconciler: @escaping @MainActor (String) -> Void,
        removeMediaAliases: @escaping @MainActor (String) -> Void = { _ in },
        activateUniversalWatchlist: @escaping @MainActor () -> Void = {}
    ) {
        self.profilesModel = profilesModel
        self.accountsProviders = accountsProviders
        self.plexHomeUsers = plexHomeUsers
        self.profileSettings = profileSettings
        self.audioController = audioController
        self.updateTrackersForActiveProfile = updateTrackersForActiveProfile
        self.discardWatchReconciler = discardWatchReconciler
        self.removeMediaAliases = removeMediaAliases
        self.activateUniversalWatchlist = activateUniversalWatchlist
    }

    // MARK: Launch picker lifecycle (driven by AppState bootstrap / onboarding)

    /// Configures the launch profile picker: shown when the household opted into
    /// "ask on startup" and has more than one profile.
    ///
    /// Also forced when the profile we'd otherwise restore is locked. Landing on
    /// the picker (rather than restoring the profile and putting a PIN screen
    /// over it) is both safer and simpler: the locked profile's rows never render
    /// behind the prompt, and the unlock then runs through the ordinary
    /// `switchProfile(to:)` gate with the picker sitting behind it. It also
    /// matches what people expect from "who's watching?" elsewhere.
    public func prepareLaunchPicker() {
        let restoredProfileIsLocked = profilesModel.activeProfile.isLocked
            && !unlockedProfileIDs.contains(profilesModel.activeProfile.id)
        isChoosingProfile = restoredProfileIsLocked
            || (profilesModel.askProfileOnStartup && profilesModel.profiles.count > 1)
        isProfileSelectionCancelable = false
    }

    /// Force-dismisses the picker (used by the debug first-run reset).
    public func dismissPicker() {
        isChoosingProfile = false
    }

    /// Clears the "picking theme for a new profile" state once the one-time theme
    /// picker is dismissed. Returns whether it was showing (so the caller can skip
    /// the follow-up Plex identity re-apply when it wasn't).
    @discardableResult
    public func finishPickingThemeForNewProfile() -> Bool {
        guard isPickingThemeForNewProfile else { return false }
        isPickingThemeForNewProfile = false
        return true
    }

    // MARK: Profiles

    /// Opens the profile picker (from Settings → "Switch Profile").
    public func requestProfileSelection() {
        isProfileSelectionCancelable = true
        isChoosingProfile = true
    }

    /// Dismisses the profile picker without changing the active profile (only
    /// allowed when a profile is already active behind it).
    public func cancelProfileSelection() {
        isChoosingProfile = false
    }

    /// A profile waiting on its PIN before it can be opened.
    ///
    /// Set when `switchProfile(to:)` is asked for a locked profile and cleared on
    /// success or cancel. `RootView` presents the PIN screen off this, exactly
    /// like the Plex Home PIN prompt it sits in front of.
    public private(set) var pendingLockedProfile: Profile?
    /// Message from the last failed unlock attempt, or `nil`.
    public private(set) var profileLockError: String?

    /// Profiles unlocked during this app run, so a person who has already proved
    /// they know the PIN isn't asked again every time they hop between profiles.
    ///
    /// Deliberately in-memory: it dies with the process, so a cold launch always
    /// re-asks. Persisting it would quietly turn "locked" into "locked once".
    @ObservationIgnored private var unlockedProfileIDs: Set<String> = []

    /// Switches to `id`, re-scoping settings + the active account set, then
    /// dismisses the picker. Fast: a few `UserDefaults` reads plus an in-memory
    /// account recompute; content reloads async via the rebuilt view subtree.
    ///
    /// When the target profile carries a `ProfileLock` and hasn't been unlocked
    /// yet this run, nothing is switched — the PIN prompt is raised instead and
    /// the real switch happens in `submitProfileLockPIN(_:)`. The gate sits ahead
    /// of everything else on purpose: no settings rebuild, no account reload, and
    /// above all no Plex identity apply happens for a profile the person hasn't
    /// proved they can open.
    public func switchProfile(to id: String) {
        if let profile = profilesModel.profiles.first(where: { $0.id == id }),
           profile.isLocked,
           !unlockedProfileIDs.contains(id) {
            profileLockError = nil
            pendingLockedProfile = profile
            return
        }
        performSwitch(to: id)
    }

    /// The unconditional switch, past the lock gate.
    private func performSwitch(to id: String) {
        audioController.stop()
        profilesModel.select(id)
        rebuildSettingsModels()
        updateTrackersForActiveProfile()
        accountsProviders.reloadAccounts()
        activateUniversalWatchlist()
        isChoosingProfile = false
        plexHomeUsers.ensurePlexIdentityForActiveProfile()
    }

    /// Checks `pin` against the pending profile's lock and, on a match, completes
    /// the switch that `switchProfile(to:)` held back.
    ///
    /// - Returns: `true` when the PIN was accepted.
    @discardableResult
    public func submitProfileLockPIN(_ pin: String) -> Bool {
        guard let profile = pendingLockedProfile, let lock = profile.lock else { return false }
        guard lock.matches(pin: pin) else {
            profileLockError = String(localized: "Incorrect PIN. Try again.")
            return false
        }
        unlockedProfileIDs.insert(profile.id)
        pendingLockedProfile = nil
        profileLockError = nil

        // Hand the same digits to Plex when the person told us the two PINs are
        // the same, so a profile bound to a PIN-protected Plex Home user asks
        // once rather than twice. Advisory only — the local verifier above
        // already decided, so this failing (offline, PINs drifted since) still
        // opens the profile and simply leaves the Plex prompt to appear.
        if lock.matchesPlexPIN {
            plexHomeUsers.prefillPlexPIN(pin, forProfile: profile.id)
        }
        performSwitch(to: profile.id)
        return true
    }

    /// Abandons a pending unlock, leaving the active profile untouched.
    public func cancelProfileLockPrompt() {
        pendingLockedProfile = nil
        profileLockError = nil
    }

    /// Whether `id` has already been proved this run, so a second gate (editing
    /// it from the picker) doesn't ask for the same PIN again.
    public func isUnlockedThisRun(_ id: String) -> Bool {
        unlockedProfileIDs.contains(id)
    }

    /// Records that `id`'s PIN was proved outside `submitProfileLockPIN` — e.g.
    /// to edit it from the picker. Knowing the PIN is knowing the PIN, so it
    /// counts for opening the profile too.
    public func noteUnlocked(_ id: String) {
        unlockedProfileIDs.insert(id)
    }

    /// Forgets that `id` was unlocked this run — called when its PIN changes or
    /// is removed, so a stale unlock can't outlive the lock that granted it.
    public func forgetUnlock(for id: String) {
        unlockedProfileIDs.remove(id)
    }

    /// Creates or updates a profile from an editor draft. Updating the active
    /// profile re-applies its settings + account scope immediately.
    ///
    /// A cosmetic-only edit (the new Settings → Profile editor) passes an
    /// empty `activeAccountIDs` to mean "leave membership alone." Settings →
    /// Servers & Libraries is the authoritative surface for membership now and
    /// writes through `setAccount(_, includedInActiveProfile:)`.
    public func saveProfile(_ draft: ProfileDraft) {
        if let id = draft.id {
            if var profile = profilesModel.profiles.first(where: { $0.id == id }) {
                profile.name = draft.name
                profile.avatarSymbol = draft.avatarSymbol
                profile.colorIndex = draft.colorIndex
                profile.linkedAccountID = draft.linkedAccountID
                profile.plexHomeUserID = draft.plexHomeUserID
                profile.plexHomeUserName = draft.plexHomeUserName
                profile.plexHomeUserAccountID = draft.plexHomeUserAccountID
                profile.plexHomeUserRequiresPIN = draft.plexHomeUserRequiresPIN
                profile.plexHomeUserAvatarURL = draft.plexHomeUserAvatarURL
                profile.plexHomeUserBindings = draft.plexHomeUserBindings
                profile.avatarImageURL = draft.avatarImageURL
                profile.avatarEmoji = draft.avatarEmoji
                profile.avatarEmojiColorIndex = draft.avatarEmojiColorIndex
                profilesModel.update(profile)
            }
            if !draft.activeAccountIDs.isEmpty {
                profilesModel.setActiveAccountIDs(draft.activeAccountIDs, for: id)
            }
            if id == profilesModel.activeProfileID {
                rebuildSettingsModels()
                updateTrackersForActiveProfile()
                accountsProviders.reloadAccounts()
                activateUniversalWatchlist()
                plexHomeUsers.ensurePlexIdentityForActiveProfile()
            }
        } else {
            let created = profilesModel.add(
                name: draft.name,
                avatarSymbol: draft.avatarSymbol,
                colorIndex: draft.colorIndex,
                linkedAccountID: draft.linkedAccountID,
                activeAccountIDs: draft.activeAccountIDs,
                plexHomeUserID: draft.plexHomeUserID,
                plexHomeUserName: draft.plexHomeUserName,
                plexHomeUserAccountID: draft.plexHomeUserAccountID,
                plexHomeUserRequiresPIN: draft.plexHomeUserRequiresPIN,
                plexHomeUserAvatarURL: draft.plexHomeUserAvatarURL,
                plexHomeUserBindings: draft.plexHomeUserBindings,
                avatarImageURL: draft.avatarImageURL,
                avatarEmoji: draft.avatarEmoji,
                avatarEmojiColorIndex: draft.avatarEmojiColorIndex
            )
            // Switch to the freshly created profile so the per-profile theme
            // picker edits *its* namespace, then present it. Mirrors
            // `switchProfile(to:)` minus the Plex identity check, which is
            // deferred to `finishPickingThemeForNewProfile()` so any PIN prompt
            // surfaces as the new profile actually enters the app — not stacked
            // under the theme cover.
            audioController.stop()
            profilesModel.select(created.id)
            rebuildSettingsModels()
            updateTrackersForActiveProfile()
            accountsProviders.reloadAccounts()
            activateUniversalWatchlist()
            isChoosingProfile = false
            isPickingThemeForNewProfile = true
        }
    }

    /// Persists ONLY a profile's cosmetic fields (name, avatar symbol/emoji,
    /// colours, borrowed photo) — used by the editor's live auto-save while you
    /// tweak an existing profile.
    ///
    /// Deliberately does **none** of `saveProfile`'s "the active profile's
    /// substance changed" work — no `rebuildSettingsModels`, `reloadAccounts` or
    /// `ensurePlexIdentityForActiveProfile`. Those re-scope which servers feed
    /// Home and can raise a Plex PIN prompt; running them on every keystroke of a
    /// cosmetic edit would reload/flicker Home and could pop a spurious PIN. A
    /// name/avatar/colour change touches none of that, so we just write the
    /// value through. No-op for an unknown id.
    public func updateProfileCosmetics(_ draft: ProfileDraft) {
        guard let id = draft.id,
              var profile = profilesModel.profiles.first(where: { $0.id == id }) else { return }
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never persist a blank name (the field may be momentarily empty while
        // retyping) — keep the last valid one.
        if !trimmed.isEmpty { profile.name = draft.name }
        profile.avatarSymbol = draft.avatarSymbol
        profile.colorIndex = draft.colorIndex
        profile.avatarImageURL = draft.avatarImageURL
        profile.avatarEmoji = draft.avatarEmoji
        profile.avatarEmojiColorIndex = draft.avatarEmojiColorIndex
        profilesModel.update(profile)
    }

    /// Creates a profile from a draft **without** activating it.
    ///
    /// `saveProfile` deliberately switches into a newly created profile (it's
    /// called from a flow that then shows the one-time theme picker for it). The
    /// picker needs the opposite: it's a chooser, and creating a profile there —
    /// especially one that's about to be locked — must not silently move the
    /// household into it and strand the user behind a PIN they haven't set yet.
    ///
    /// - Returns: the created profile, so the caller can offer to lock it.
    @discardableResult
    public func createProfileWithoutSwitching(_ draft: ProfileDraft, isKids: Bool) -> Profile {
        let created = profilesModel.add(
            name: draft.name,
            avatarSymbol: draft.avatarSymbol,
            colorIndex: draft.colorIndex,
            linkedAccountID: draft.linkedAccountID,
            activeAccountIDs: draft.activeAccountIDs,
            plexHomeUserID: draft.plexHomeUserID,
            plexHomeUserName: draft.plexHomeUserName,
            plexHomeUserAccountID: draft.plexHomeUserAccountID,
            plexHomeUserRequiresPIN: draft.plexHomeUserRequiresPIN,
            plexHomeUserAvatarURL: draft.plexHomeUserAvatarURL,
            plexHomeUserBindings: draft.plexHomeUserBindings,
            avatarImageURL: draft.avatarImageURL,
            avatarEmoji: draft.avatarEmoji,
            avatarEmojiColorIndex: draft.avatarEmojiColorIndex
        )
        guard isKids else { return created }
        var restricted = created
        restricted.isKids = true
        profilesModel.update(restricted)
        return restricted
    }

    /// Removes a profile (the default profile can't be removed). If it was
    /// active, selection falls back to the first profile and re-scopes.
    ///
    /// The fallback is chosen by `ProfilesModel.remove(_:)` and may well be a
    /// LOCKED profile, so this can't just re-scope into it — deleting your own
    /// profile would otherwise be a way into someone else's without their PIN.
    /// `enforceLockOnActiveProfile()` sends us to the picker in that case.
    public func removeProfile(id: String) {
        let wasActive = id == profilesModel.activeProfileID
        discardWatchReconciler(id)
        removeMediaAliases(id)
        profilesModel.remove(id)
        if wasActive {
            if enforceLockOnActiveProfile() { return }
            rebuildSettingsModels()
            updateTrackersForActiveProfile()
            accountsProviders.reloadAccounts()
            activateUniversalWatchlist()
            // `profilesModel.remove(id)` above already selected the fallback profile
            // as active, so re-apply ITS Plex identity — re-installing the fallback's
            // Home-user binding or dropping the removed profile's stale token override.
            // Mirrors `switchProfile(to:)`'s ordering (ensure runs last, after reload);
            // without it the fallback could be left on the deleted profile's stale
            // Plex override until the next explicit switch.
            plexHomeUsers.ensurePlexIdentityForActiveProfile()
        }
    }

    /// Sends the user to the profile picker when the profile that is *already*
    /// active is locked and hasn't been unlocked this run.
    ///
    /// The backstop for every path that makes a profile active without going
    /// through `switchProfile(to:)` — deleting the active profile, and sync
    /// applying a remote change that removes it. Routing to the picker (rather
    /// than raising the PIN over whatever is on screen) keeps the locked
    /// profile's content from rendering behind the prompt, and the unlock then
    /// runs through the normal gate.
    ///
    /// - Returns: `true` when the picker was raised, so callers can stop.
    @discardableResult
    public func enforceLockOnActiveProfile() -> Bool {
        let active = profilesModel.activeProfile
        guard active.isLocked, !unlockedProfileIDs.contains(active.id) else { return false }
        isProfileSelectionCancelable = false
        isChoosingProfile = true
        return true
    }

    // MARK: Household preferences

    /// Persists the "Ask which profile on startup" launch-picker toggle.
    public func setAskProfileOnStartup(_ value: Bool) {
        profilesModel.setAskProfileOnStartup(value)
    }

    /// Whether `accountID` is included in the active profile's "Use this
    /// server" set. Used by Settings to drive the per-server toggle.
    public func isAccountIncludedInActiveProfile(_ accountID: String) -> Bool {
        accountsProviders.activeAccountIDs.contains(accountID)
    }

    /// Toggles inclusion of `accountID` in the active profile's account set
    /// ("Use this server" toggle on Settings → Servers & Libraries → server).
    public func setAccount(_ accountID: String, includedInActiveProfile included: Bool) {
        let profileID = profilesModel.activeProfileID
        // Mutate the resolved set that the UI is actually showing, not the raw
        // stored set. The latter can contain only stale account ids after a
        // server is removed/re-added; reloadAccounts() intentionally resolves
        // that situation to the current household set. Starting from the stale
        // stored value would make removing a visible account a no-op, then the
        // next reload would fall back to every account and leave the switch On.
        let current = accountsProviders.activeAccountIDs
        var next = current
        if included { next.insert(accountID) } else { next.remove(accountID) }
        profilesModel.setActiveAccountIDs(Array(next), for: profileID)
        accountsProviders.reloadAccounts()
    }

    // MARK: Internals

    private func rebuildSettingsModels() {
        profileSettings.rebuild(namespace: profilesModel.activeNamespace)
    }
}
