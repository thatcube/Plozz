import Foundation
import Observation
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

    public init(
        profilesModel: ProfilesModel,
        accountsProviders: AccountsProvidersModel,
        plexHomeUsers: PlexHomeUsersModel,
        profileSettings: ProfileSettingsModel,
        audioController: AudioPlaybackController,
        updateTrackersForActiveProfile: @escaping @MainActor () -> Void,
        discardWatchReconciler: @escaping @MainActor (String) -> Void
    ) {
        self.profilesModel = profilesModel
        self.accountsProviders = accountsProviders
        self.plexHomeUsers = plexHomeUsers
        self.profileSettings = profileSettings
        self.audioController = audioController
        self.updateTrackersForActiveProfile = updateTrackersForActiveProfile
        self.discardWatchReconciler = discardWatchReconciler
    }

    // MARK: Launch picker lifecycle (driven by AppState bootstrap / onboarding)

    /// Configures the launch profile picker: shown when the household opted into
    /// "ask on startup" and has more than one profile. Mandatory (not cancelable).
    public func prepareLaunchPicker() {
        isChoosingProfile = profilesModel.askProfileOnStartup
            && profilesModel.profiles.count > 1
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

    /// Switches to `id`, re-scoping settings + the active account set, then
    /// dismisses the picker. Fast: a few `UserDefaults` reads plus an in-memory
    /// account recompute; content reloads async via the rebuilt view subtree.
    public func switchProfile(to id: String) {
        audioController.stop()
        profilesModel.select(id)
        rebuildSettingsModels()
        updateTrackersForActiveProfile()
        accountsProviders.reloadAccounts()
        isChoosingProfile = false
        plexHomeUsers.ensurePlexIdentityForActiveProfile()
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

    /// Removes a profile (the default profile can't be removed). If it was
    /// active, selection falls back to the first profile and re-scopes.
    public func removeProfile(id: String) {
        let wasActive = id == profilesModel.activeProfileID
        discardWatchReconciler(id)
        profilesModel.remove(id)
        if wasActive {
            rebuildSettingsModels()
            updateTrackersForActiveProfile()
            accountsProviders.reloadAccounts()
        }
    }

    // MARK: Household preferences

    /// Opt the household into the profile UX (shows the "Enable Profiles"
    /// affordance in Settings, surfaces profile management). Idempotent.
    public func enableProfiles() {
        profilesModel.enableProfiles()
    }

    /// Opt the household out of the profile UX. Only honored with a single
    /// profile — `ProfilesModel.disableProfiles()` refuses when there are
    /// multiple profiles so they don't become unreachable.
    public func disableProfiles() {
        profilesModel.disableProfiles()
    }

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
