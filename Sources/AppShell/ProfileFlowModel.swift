import Foundation
import Observation
import AppRuntime
import CoreModels
import CoreUI
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

    /// A just-created profile that still needs its setup step (servers, identity,
    /// libraries).
    ///
    /// Lives here rather than in whichever view created the profile: creating one
    /// switches into it, which dismisses the picker — so a cover presented BY the
    /// picker is torn down before it can appear. App-level flow, app-level state.
    public private(set) var pendingSetupProfile: Profile?
    /// A profile that has finished setup and is being offered a lock.
    public private(set) var pendingLockOfferProfile: Profile?

    @ObservationIgnored private let profilesModel: ProfilesModel
    @ObservationIgnored private let accountsProviders: AccountsProvidersModel
    @ObservationIgnored private let plexHomeUsers: PlexHomeUsersModel
    @ObservationIgnored private let profileSettings: ProfileSettingsModel
    @ObservationIgnored private let audioController: AudioPlaybackController
    /// Re-points the tracker services (Trakt/Simkl/Seerr/AniList/MAL/Last.fm) +
    /// identity index at the active profile. Injected because the tracker services
    /// still live on `AppState`.
    @ObservationIgnored private let updateTrackersForActiveProfile: @MainActor () async -> Void
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
        updateTrackersForActiveProfile: @escaping @MainActor () async -> Void,
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
        isChoosingProfile = activeProfileAwaitsUnlock
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
    public private(set) var profileLockError: LocalizedStringResource?

    /// A profile the household is trying to reach *out of* a Kids Profile, held
    /// until the Parental PIN is entered.
    ///
    /// Separate from `pendingLockedProfile` because it asks a different question:
    /// that one is "may you open this profile", this one is "may you leave the
    /// child's". Both can apply to one switch — a parent leaving the kid for
    /// their own locked profile answers the Parental PIN, then their own.
    public private(set) var pendingParentalSwitch: Profile?
    /// The enforced Kids Profile the device was moved OUT of without anyone
    /// asking — a local or synced deletion re-points `activeProfileID` on its
    /// own. Held until the Parental PIN clears it.
    ///
    /// It exists because the obvious check is wrong: after the fall-through
    /// `activeProfile` is already the grown-up, so anything that derives the
    /// gate from it concludes there is nothing to gate. This keeps the child's
    /// profile as the authority for the whole episode, and deliberately survives
    /// a cancel — otherwise one tap on Cancel lands exactly where the gate was
    /// meant to prevent.
    public private(set) var parentalFallThrough: Profile?
    /// Message from the last failed Parental PIN attempt, or `nil`.
    public private(set) var parentalPINError: LocalizedStringResource?

    /// Whether profile management (add/edit) must be withheld right now.
    ///
    /// The household policy plus the fall-through hold, so a child dropped into
    /// a grown-up profile by a synced deletion can't create or edit their way
    /// out while the picker is up.
    public var managementRequiresParentalPIN: Bool {
        profilesModel.managementRequiresParentalPIN || parentalFallThrough != nil
    }

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
    /// Two gates sit in front of the switch, in this order:
    ///
    /// 1. **May you leave?** Walking out of a Kids Profile into a grown-up one
    ///    needs the household's Parental PIN. This is the child's front door, so
    ///    it is checked before anything is touched.
    /// 2. **May you enter?** The target's own `ProfileLock`, as before.
    ///
    /// Nothing is switched until both are satisfied: no settings rebuild, no
    /// account reload, and above all no Plex identity apply for a profile the
    /// person hasn't proved they can open.
    public func switchProfile(to id: String) {
        guard let target = profilesModel.profiles.first(where: { $0.id == id }) else {
            performSwitch(to: id)
            return
        }
        // The hold wins over `activeProfile`: after an involuntary fall-through
        // the active profile is already the grown-up one, and asking it whether
        // we may leave a Kids Profile answers "there is no Kids Profile here".
        if profilesModel.requiresParentalPIN(
            switchingFrom: parentalFallThrough ?? profilesModel.activeProfile,
            to: target
        ) {
            parentalPINError = nil
            pendingParentalSwitch = target
            return
        }
        continueSwitch(to: target)
    }

    /// The switch past the parental gate, still subject to the target's own lock.
    private func continueSwitch(to target: Profile) {
        if target.isLocked, !unlockedProfileIDs.contains(target.id) {
            profileLockError = nil
            pendingLockedProfile = target
            return
        }
        performSwitch(to: target.id)
    }

    /// Checks `pin` against the household's Parental PIN and, on a match, lets
    /// the held switch continue.
    ///
    /// Deliberately **not** remembered for the run, unlike `unlockedProfileIDs`.
    /// Remembering it would mean that once a grown-up stepped out of the child's
    /// profile, the child could too until the next cold launch — which is the
    /// whole thing this gate exists to prevent. Leaving a Kids Profile is rare
    /// enough that asking every time costs the adults almost nothing.
    ///
    /// - Returns: `true` when the PIN was accepted.
    @discardableResult
    public func submitParentalPIN(_ pin: String) -> Bool {
        guard let target = pendingParentalSwitch else { return false }
        guard profilesModel.matchesParentalPIN(pin) else {
            parentalPINError = ProfileLockCopy.incorrectPIN
            return false
        }
        pendingParentalSwitch = nil
        parentalPINError = nil
        continueSwitch(to: target)
        return true
    }

    /// Abandons a held switch, leaving the child where they were.
    public func cancelParentalSwitch() {
        pendingParentalSwitch = nil
        parentalPINError = nil
    }

    /// The unconditional switch, past the lock gate.
    ///
    /// Ordering is load-bearing. The universal watchlist import reads whatever
    /// credentials the trackers and Plex currently hold, so it must not start
    /// until BOTH have been re-pointed at the new profile — otherwise it imports
    /// the profile you just left into the profile you just opened, and writes it
    /// to disk. Everything the UI needs synchronously still happens
    /// synchronously; only the import waits.
    private func performSwitch(to id: String) {
        profilesModel.select(id)
        // `select` NO-OPS for an id this device doesn't have — a peer can delete
        // a profile between the picker rendering and the tap, which is exactly
        // the fall-through case. Releasing the hold and dismissing the forced
        // picker on a switch that never happened would strand the child in the
        // grown-up profile the gate exists to withhold.
        guard profilesModel.activeProfileID == id else { return }
        audioController.stop()
        // Past both gates, so the hold has done its job — released here rather
        // than in `submitParentalPIN` so that switching into ANOTHER Kids
        // Profile (which needs no PIN) also releases it.
        parentalFallThrough = nil
        rebuildSettingsModels()
        accountsProviders.reloadAccounts()
        isChoosingProfile = false
        // Installs the new profile's Plex Home-user token (synchronously from
        // cache for unprotected users; protected ones raise the PIN prompt).
        plexHomeUsers.ensurePlexIdentityForActiveProfile()
        // Switching INTO a profile that never finished setup — abandoned here, or
        // created on another device and synced across — asks the question again
        // rather than leaving it permanently unable to import.
        resumeSetupIfNeeded()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.updateTrackersForActiveProfile()
            // Re-check: the person may have switched again while the trackers
            // were re-pointing, and the later switch owns the import.
            guard self.profilesModel.activeProfileID == id else { return }
            self.activateUniversalWatchlist()
        }
    }

    /// Checks `pin` against the pending profile's lock and, on a match, completes
    /// the switch that `switchProfile(to:)` held back.
    ///
    /// - Returns: `true` when the PIN was accepted.
    @discardableResult
    public func submitProfileLockPIN(_ pin: String) -> Bool {
        guard let profile = pendingLockedProfile, let lock = profile.lock else { return false }
        guard lock.matches(pin: pin) else {
            profileLockError = ProfileLockCopy.incorrectPIN
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
    /// Whether the ACTIVE profile is locked and unproven this run.
    /// See `UniversalWatchlistHost.activeProfileAwaitsUnlock`.
    public var activeProfileAwaitsUnlock: Bool {
        let active = profilesModel.activeProfile
        return active.isLocked && !unlockedProfileIDs.contains(active.id)
    }

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
                Task { await updateTrackersForActiveProfile() }
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
            Task { await updateTrackersForActiveProfile() }
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

    /// Creates a profile from a draft and switches into it, ready for setup.
    ///
    /// Switching in is what makes the setup step simple: every per-profile model
    /// (membership, Plex identity, library visibility) then points at the new
    /// profile, so setup drives the same code Settings does instead of a
    /// parallel set of "…forProfile:" variants. Safe because the profile is
    /// empty and marked `needsSetup`, which defers its watchlist import until
    /// setup says which servers it actually uses.
    ///
    /// - Returns: the created profile, so the caller can run setup on it.
    @discardableResult
    public func createProfileForSetup(_ draft: ProfileDraft, isKids: Bool) -> Profile {
        // Shared with the iOS shell so the setup gate can't be forgotten on one
        // platform — see `addAwaitingSetup`.
        let configured = profilesModel.addAwaitingSetup(
            draft,
            isKids: isKids,
            activeAccountIDs: draft.activeAccountIDs
        )
        // Claim the root setup page BEFORE switching dismisses the picker. Root
        // can then render setup directly underneath the editor sheet, so the
        // sheet's fade-out never exposes Home.
        pendingSetupProfile = configured
        performSwitch(to: configured.id)
        return configured
    }

    /// Re-presents setup for a profile that never finished it.
    ///
    /// The gate is PERSISTED, so quitting mid-setup leaves it set — and a profile
    /// stuck behind it never imports a watchlist at all, silently and forever.
    /// Resuming asks the question that was never answered, which is the only
    /// answer that's both safe and correct: importing anyway is the leak the gate
    /// exists to prevent, and clearing it without asking is the same thing.
    public func resumeSetupIfNeeded() {
        guard pendingSetupProfile == nil else { return }
        let active = profilesModel.activeProfile
        guard active.needsSetup else { return }
        pendingSetupProfile = active
    }

    /// Marks setup finished and releases the deferred watchlist import.
    public func completeSetup(for id: String) {
        pendingSetupProfile = nil
        guard profilesModel.finishSetup(for: id) else { return }
        guard let profile = profilesModel.profiles.first(where: { $0.id == id }) else { return }
        // Only now, with the profile's servers and identity settled, is an
        // import meaningful — see `Profile.isAwaitingSetup`.
        activateUniversalWatchlist()
        // NOTHING is presented here. This runs from inside the setup cover, and
        // SwiftUI shows one cover at a time — asking for the next one while the
        // current is still on screen gets it dropped, which is why the theme
        // picker kept not appearing. The caller raises it from the cover's
        // `onDismiss`, once the screen is actually free. See `presentPostSetupStep`.
        profileAwaitingThemePick = profile
    }

    /// Releases the watchlist import after Libraries while keeping the full setup
    /// cover alive for Seerr, Theme and Lock.
    public func completeLibrariesInsideSetup(for id: String) {
        guard profilesModel.finishSetup(for: id) else { return }
        activateUniversalWatchlist()
    }

    /// Dismisses the one persistent added-profile setup cover.
    public func finishSetupFlow() {
        pendingSetupProfile = nil
    }

    /// Held between one cover closing and the next opening.
    @ObservationIgnored private var profileAwaitingThemePick: Profile?
    @ObservationIgnored private var profileAwaitingLockOffer: Profile?

    /// Raises the theme picker for a just-set-up profile. Call from the setup
    /// cover's `onDismiss`, never while it's still presented.
    public func presentPostSetupStep() {
        guard let profile = profileAwaitingThemePick else { return }
        profileAwaitingThemePick = nil
        profileAwaitingLockOffer = profile
        isPickingThemeForNewProfile = true
    }

    /// Raises the lock offer once the theme picker has actually gone. Call from
    /// the theme cover's `onDismiss`.
    public func presentPostThemeStep() {
        guard let profile = profileAwaitingLockOffer else { return }
        profileAwaitingLockOffer = nil
        pendingLockOfferProfile = profile
    }

    /// Dismisses the post-setup lock offer.
    public func dismissLockOffer() {
        pendingLockOfferProfile = nil
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
        let outgoingProfile = profilesModel.activeProfile
        discardWatchReconciler(id)
        removeMediaAliases(id)
        profilesModel.remove(id)
        if wasActive {
            if enforceLockOnActiveProfile(leaving: outgoingProfile) { return }
            rebuildSettingsModels()
            Task { await updateTrackersForActiveProfile() }
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
    /// - Parameter leaving: the profile that was active before the fall-through,
    ///   when the caller knows it. See the iOS twin: a deleted Kids Profile
    ///   otherwise drops straight into a grown-up profile, and with a Parental
    ///   PIN in play those profiles deliberately carry no lock of their own.
    @discardableResult
    public func enforceLockOnActiveProfile(leaving outgoing: Profile? = nil) -> Bool {
        let active = profilesModel.activeProfile
        if let outgoing,
           profilesModel.requiresParentalPIN(switchingFrom: outgoing, to: active) {
            // Hold the child's profile as the gate's authority. `activeProfile`
            // is ALREADY the grown-up by now, so every predicate that derives
            // the answer from it — `switchProfile`'s `from`, the picker's
            // management gate — would read "not a Kids Profile" and stand aside.
            // The hold outlives this call and is released only by the PIN.
            parentalFallThrough = outgoing
            parentalPINError = nil
            isProfileSelectionCancelable = false
            isChoosingProfile = true
            return true
        }
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
        // Noted BEFORE the reload, which schedules a watchlist import: the whole
        // point is that the import waits for the answer, and a note taken after
        // it has already been scheduled is too late.
        if included {
            noteServerAwaitingIdentity(accountID, profileID: profileID)
        } else {
            // Switched back off — there's nothing left to be anyone on, and an
            // unanswerable question would gate the import forever.
            resolveIdentityPrompt(for: accountID)
        }
        accountsProviders.reloadAccounts()
    }

    /// The server this profile has just enabled and not yet chosen an identity
    /// on, if any. `RootView` presents the picker from this.
    ///
    /// Read from the PROFILE, not from memory: the question has to outlive a
    /// relaunch, because the enabled-but-unidentified server does. See
    /// `Profile.accountsAwaitingIdentity`.
    public var pendingIdentityAccountID: String? {
        profilesModel.actionableIdentityAccountIDs(
            forProfile: profilesModel.activeProfileID,
            importAccountIDs: ProfileServerIdentityPolicy
                .importPlexAccountIDs(
                    in: NativeWatchlistAccounts.resolve(
                        profiles: profilesModel,
                        accountsProviders: accountsProviders
                    )
                )
        ).first
    }

    private func noteServerAwaitingIdentity(_ accountID: String, profileID: String) {
        guard let account = accountsProviders.accounts.first(where: { $0.id == accountID }),
              var profile = profilesModel.profiles.first(where: { $0.id == profileID }),
              ProfileServerIdentityPolicy.shouldAsk(
                  provider: account.server.provider,
                  hasExistingBinding: profile.homeUserBinding(forPlexAccount: accountID) != nil
              ),
              profile.noteAccountAwaitingIdentity(accountID)
        else { return }
        profilesModel.update(profile)
    }

    /// Clears the pending question once an identity is chosen (or declined).
    public func resolveIdentityPrompt(for accountID: String) {
        let profileID = profilesModel.activeProfileID
        guard var profile = profilesModel.profiles.first(where: { $0.id == profileID }),
              profile.resolveAccountAwaitingIdentity(accountID)
        else { return }
        profilesModel.update(profile)
        // The import was deferred while this was outstanding; with the answer in
        // it can finally run, against the identity that was just chosen.
        if !profile.needsSetup, profilesModel.actionableIdentityAccountIDs(
            forProfile: profile.id,
            importAccountIDs: ProfileServerIdentityPolicy
                .importPlexAccountIDs(
                    in: NativeWatchlistAccounts.resolve(
                        profiles: profilesModel,
                        accountsProviders: accountsProviders
                    )
                )
        ).isEmpty {
            activateUniversalWatchlist()
        }
    }

    // MARK: Internals

    private func rebuildSettingsModels() {
        profileSettings.rebuild(namespace: profilesModel.activeNamespace)
    }
}
