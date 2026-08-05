#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// Hosts the profile picker — the "Who's watching?" screen.
///
/// Used at launch (when "Ask which profile on startup" is on, the household has
/// more than one profile, or the profile we'd restore is locked) and from
/// Settings → "Switch Profile".
///
/// Adding and editing happen here now, not only in Settings. This is where
/// people already are when they think about profiles, and where a household's
/// second profile actually gets made. The screens it opens are the same ones
/// Settings uses — the cosmetic editor and `ProfileLockSetupView` — so there's
/// one implementation of each, reached from two places.
struct ProfileSelectionView: View {
    @Bindable var appState: AppState
    /// `true` when there is already an active session behind the picker, so the
    /// picker can be cancelled (Settings entry); `false` at first launch.
    let canCancel: Bool

    @Environment(\.themePalette) private var palette

    /// The profile whose actions sheet is open (Edit), held as an **id**.
    ///
    /// `.sheet(item:)` captures the value it was presented with, so holding a
    /// `Profile` here meant the sheet kept rendering the profile as it was when
    /// Edit was pressed — set a lock and the row still read "Off". The id is
    /// stable and the profile is resolved live from the observable model on every
    /// render instead.
    @State private var actionsProfileID: PickerProfileID?
    /// The profile whose cosmetics are being edited, if any.
    @State private var editingProfile: Profile?
    /// Set while creating a profile, so the sheet knows which kind to make.
    @State private var creating: CreationKind?
    /// A management action held back until a PIN proves it's allowed, together
    /// with whose PIN that is.
    @State private var pendingAction: PendingAuthorization?
    /// Error from the last failed authorization attempt.
    @State private var authError: String?

    private enum CreationKind: Identifiable {
        case ordinary
        case kids
        var id: String { self == .kids ? "kids" : "ordinary" }
        var isKids: Bool { self == .kids }
    }

    private enum ManagementAction {
        case add(isKids: Bool)
        case edit(Profile)
    }

    /// An action waiting on a PIN, and the profile whose PIN unlocks it.
    private struct PendingAuthorization: Identifiable {
        let action: ManagementAction
        let gatekeeper: Profile

        /// True when the PIN being asked for belongs to the very profile being
        /// edited — in which case the prompt needs no explanation beyond the name
        /// and avatar already on screen. Only the *add* case, where the PIN comes
        /// from some other profile, has to justify itself.
        var isEditingGatekeeper: Bool {
            if case let .edit(profile) = action { return profile.id == gatekeeper.id }
            return false
        }

        var id: String {
            switch action {
            case let .add(isKids): return "add.\(isKids)"
            case let .edit(profile): return "edit.\(profile.id)"
            }
        }
    }

    var body: some View {
        ProfilePickerView(
            // Whoever watched on this Apple TV most recently leads the row, since
            // tvOS opens focus on the first tile and that's the likeliest pick.
            profiles: appState.profilesModel.profilesByRecency,
            activeProfileID: appState.profilesModel.activeProfileID,
            onSelect: { appState.profileFlow.switchProfile(to: $0.id) },
            onAddProfile: { request(.add(isKids: false)) },
            onEditProfile: { request(.edit($0)) },
            onAddKidsProfile: { request(.add(isKids: true)) },
            onCancel: canCancel ? { appState.profileFlow.cancelProfileSelection() } : nil
        )
        // tvOS Menu button: the picker is rendered as a top-level view (not a
        // sheet / NavigationStack push), so without this handler Menu falls
        // through to the system and quits the app.
        //
        // - canCancel: act like Cancel — dismiss back to the current profile.
        // - !canCancel: first launch / no active profile yet — consume the event
        //   silently so Menu can't exit the app from the mandatory picker.
        .onExitCommand {
            if canCancel { appState.profileFlow.cancelProfileSelection() }
        }
        .sheet(item: $actionsProfileID) { wrapper in
            // Resolved on every render so the sheet reflects edits made from
            // inside it — the lock it just set, a rename, the Kids toggle.
            if let profile = appState.profilesModel.profiles.first(where: { $0.id == wrapper.id }) {
                ProfileActionsSheet(
                    profile: profile,
                    syncEnabled: SyncSetupFeatureFlag().isEnabled,
                    offersPlexPINReuse: profile.playsAsPINProtectedPlexUser,
                    householdHasOtherLock: appState.profilesModel.profiles.contains {
                        $0.id != profile.id && $0.isLocked
                    },
                    onEditAppearance: {
                        actionsProfileID = nil
                        editingProfile = profile
                    },
                    onSetLock: { appState.setLock($0, forProfile: profile.id) },
                    onSetKids: { appState.setKidsProfile($0, forProfile: profile.id) },
                    validatePlexPIN: {
                        await appState.plexHomeUsers.validatePlexPIN(
                            $0,
                            forProfile: profile.id
                        )
                    },
                    onDelete: profile.id == appState.profilesModel.profiles.first?.id ? nil : {
                        appState.profileFlow.removeProfile(id: profile.id)
                        actionsProfileID = nil
                    },
                    isUnlocked: appState.profileFlow.isUnlockedThisRun(profile.id),
                    onUnlock: { appState.profileFlow.noteUnlocked(profile.id) },
                    onClose: { actionsProfileID = nil }
                )
            }
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(
                editingProfile: profile,
                canDelete: profile.id != appState.profilesModel.profiles.first?.id,
                photoSourceAccounts: appState.accountsProviders.accounts,
                plexHomeUsersFetcher: { await appState.plexHomeUsers.plexHomeUsers(forAccountID: $0) },
                onSave: { appState.profileFlow.saveProfile($0); editingProfile = nil },
                onLiveChange: { appState.profileFlow.updateProfileCosmetics($0) },
                onDelete: {
                    appState.profileFlow.removeProfile(id: profile.id)
                    editingProfile = nil
                },
                onCancel: { editingProfile = nil }
            )
        }
        .sheet(item: $creating) { kind in
            ProfileEditorView(
                canDelete: false,
                photoSourceAccounts: appState.accountsProviders.accounts,
                existingColorIndices: appState.profilesModel.profiles.map(\.colorIndex),
                existingEmojiAvatars: appState.profilesModel.profiles.compactMap(\.avatarEmoji),
                plexHomeUsersFetcher: { await appState.plexHomeUsers.plexHomeUsers(forAccountID: $0) },
                onSave: { draft in
                    // Creates and switches in: setup needs the profile active so
                    // it can drive the ordinary per-profile machinery. Its
                    // watchlist import stays deferred until setup finishes.
                    // Creates, switches in, and hands off to the app-level setup
                    // step — the picker is dismissed by the switch, so it can't
                    // own what comes next.
                    appState.createProfileForSetup(draft, isKids: kind.isKids)
                    creating = nil
                },
                onCancel: { creating = nil }
            )
        }
        .fullScreenCover(item: $pendingAction) { pending in
            PINEntryScaffold(
                title: ProfileLockCopy.manageTitle,
                subtitle: ProfileLockCopy.manageSubtitle,
                name: pending.gatekeeper.name,
                errorMessage: authError,
                onSubmit: { submitAuthorization($0, pending: pending) },
                onCancel: { pendingAction = nil; authError = nil }
            ) {
                ProfileAvatarView(profile: pending.gatekeeper, size: PINLayout.badgeSize)
            }
        }
    }


    // MARK: Authorization

    /// Which profile's PIN a given action needs, if any.
    ///
    /// Two different questions, and conflating them is what made the prompt read
    /// oddly ("adding or changing profiles needs the PIN from a locked profile"
    /// while editing your own):
    ///
    /// - **Editing** a profile is gated by *that profile's own* lock, inside the
    ///   actions list — the only PIN that means anything there, since editing
    ///   includes removing the lock.
    /// - **Adding** a profile has no profile to take a PIN from, and a new
    ///   profile is unrestricted — which is an escape hatch out of a Kids
    ///   Profile. So it's gated by any locked grown-up profile, but ONLY when the
    ///   household is actually using parental controls (a Kids Profile exists and
    ///   something is locked). Otherwise there's nothing to escape and the prompt
    ///   would be pure friction on the ordinary "add a second profile" case.
    private func gatekeeper(for action: ManagementAction) -> Profile? {
        switch action {
        case .edit:
            // Not gated here: `ProfileActionsList` seals a locked profile itself,
            // so every route into it — picker, Settings, either platform — is
            // covered by one rule instead of a gate per entry point.
            return nil
        case .add:
            guard householdUsesParentalControls else { return nil }
            return guardianProfile
        }
    }

    /// A locked, unrestricted profile — a grown-up's. A Kids Profile that happens
    /// to carry a lock is still a child's, so its PIN shouldn't be the key to the
    /// household.
    private var guardianProfile: Profile? {
        appState.profilesModel.profiles.first { $0.isLocked && !$0.isKids }
    }

    /// Whether the household has actually set up parental controls: a restricted
    /// profile to contain someone, and a lock to contain them with.
    private var householdUsesParentalControls: Bool {
        let profiles = appState.profilesModel.profiles
        return profiles.contains(where: \.isKids) && profiles.contains { $0.isLocked && !$0.isKids }
    }

    /// Runs a management action, asking for a PIN first when one is required.
    private func request(_ action: ManagementAction) {
        guard let gate = gatekeeper(for: action) else {
            perform(action)
            return
        }
        authError = nil
        pendingAction = PendingAuthorization(action: action, gatekeeper: gate)
    }

    private func submitAuthorization(_ pin: String, pending: PendingAuthorization) {
        guard let lock = pending.gatekeeper.lock, lock.matches(pin: pin) else {
            authError = String(localized: "Incorrect PIN. Try again.")
            return
        }
        // Knowing a profile's PIN is knowing it — don't re-ask to open it later.
        appState.profileFlow.noteUnlocked(pending.gatekeeper.id)
        authError = nil
        pendingAction = nil
        perform(pending.action)
    }

    private func perform(_ action: ManagementAction) {
        switch action {
        case let .add(isKids):
            creating = isKids ? .kids : .ordinary
        case let .edit(profile):
            actionsProfileID = PickerProfileID(id: profile.id)
        }
    }
}

/// Identifiable wrapper so a profile id can drive `.sheet(item:)` without the
/// sheet capturing a stale copy of the profile itself.
private struct PickerProfileID: Identifiable, Hashable {
    let id: String
}
#endif
