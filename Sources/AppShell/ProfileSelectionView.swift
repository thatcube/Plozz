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
    /// A just-created profile waiting on the "want a lock?" offer.
    @State private var newlyCreated: Profile?
    /// Set once the user accepts that offer, presenting the PIN setup.
    @State private var lockTarget: Profile?
    /// A management action held back until a PIN proves it's allowed.
    @State private var pendingAction: ManagementAction?
    /// Error from the last failed authorization attempt.
    @State private var authError: String?
    /// Whether management has been proved during this presentation.
    @State private var authorized = false

    private enum CreationKind: Identifiable {
        case ordinary
        case kids
        var id: String { self == .kids ? "kids" : "ordinary" }
        var isKids: Bool { self == .kids }
    }

    private enum ManagementAction: Identifiable {
        case add(isKids: Bool)
        case edit(Profile)

        var id: String {
            switch self {
            case let .add(isKids): return isKids ? "add.kids" : "add"
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
                    offersPlexPINReuse: offersPlexPINReuse(for: profile),
                    householdHasOtherLock: appState.profilesModel.profiles.contains {
                        $0.id != profile.id && $0.isLocked
                    },
                    onEditAppearance: {
                        actionsProfileID = nil
                        editingProfile = profile
                    },
                    onSetLock: { appState.setLock($0, forProfile: profile.id) },
                    onSetKids: { appState.setKidsProfile($0, forProfile: profile.id) },
                    onDelete: profile.id == appState.profilesModel.profiles.first?.id ? nil : {
                        appState.profileFlow.removeProfile(id: profile.id)
                        actionsProfileID = nil
                    },
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
                plexHomeUsersFetcher: { await appState.plexHomeUsers.plexHomeUsers(forAccountID: $0) },
                onSave: { draft in
                    // Create WITHOUT switching into it: the picker is a chooser,
                    // and silently activating a profile the moment it's named
                    // would strand a brand-new locked profile behind its own PIN.
                    let created = appState.createProfileWithoutSwitching(draft, isKids: kind.isKids)
                    creating = nil
                    newlyCreated = created
                },
                onCancel: { creating = nil }
            )
        }
        // Offer the lock right after creation. This is the moment the decision
        // makes sense — otherwise locking is something you only discover later.
        .alert(
            Text(ProfileLockCopy.offerTitle),
            isPresented: Binding(
                get: { newlyCreated != nil },
                set: { if !$0 { newlyCreated = nil } }
            ),
            presenting: newlyCreated
        ) { profile in
            Button(String(localized: ProfileLockCopy.create)) {
                newlyCreated = nil
                lockTarget = profile
            }
            Button("Not Now", role: .cancel) { newlyCreated = nil }
        } message: { profile in
            Text(profile.isKids ? ProfileLockCopy.offerMessageKids : ProfileLockCopy.offerMessage)
        }
        .fullScreenCover(item: $lockTarget) { profile in
            ProfileLockSetupView(
                profile: profile,
                syncEnabled: SyncSetupFeatureFlag().isEnabled,
                onComplete: { lock in
                    appState.setLock(lock, forProfile: profile.id)
                    lockTarget = nil
                },
                onCancel: { lockTarget = nil }
            )
        }
        .fullScreenCover(item: $pendingAction) { action in
            if let guardianProfile {
                PINEntryScaffold(
                    title: ProfileLockCopy.manageTitle,
                    subtitle: ProfileLockCopy.manageSubtitle,
                    name: guardianProfile.name,
                    errorMessage: authError,
                    onSubmit: { submitAuthorization($0, action: action) },
                    onCancel: { pendingAction = nil; authError = nil }
                ) {
                    ProfileAvatarView(profile: guardianProfile, size: 200)
                }
            }
        }
    }

    /// Whether this profile plays as a Plex Home user that already asks for a
    /// PIN, so one entry can satisfy both.
    private func offersPlexPINReuse(for profile: Profile) -> Bool {
        if profile.plexHomeUserRequiresPIN == true { return true }
        return profile.plexHomeUserBindings?.values.contains { $0.requiresPIN == true } ?? false
    }

    // MARK: Authorization

    /// The locked profile whose PIN authorises managing profiles — a grown-up's.
    ///
    /// Prefers a locked, unrestricted profile: a Kids Profile with a lock on it
    /// is still a child's, and its PIN shouldn't be the key to the household.
    private var guardianProfile: Profile? {
        let locked = appState.profilesModel.profiles.filter(\.isLocked)
        return locked.first(where: { !$0.isKids }) ?? locked.first
    }

    /// Whether managing profiles has to be proved first.
    ///
    /// The picker can create profiles, and a new profile is unrestricted — so
    /// without a gate a child could step straight out of a Kids Profile by making
    /// themselves a new one, and the launch picker (which is *forced* when the
    /// profile we'd restore is locked) would hand the same escape to anyone.
    ///
    /// The gate is deliberately narrow:
    /// - Nothing locked anywhere? Nothing to protect, and demanding a PIN would
    ///   just block the ordinary first-run case of adding a second profile.
    /// - A live session behind the picker (opened from Switch Profile) already
    ///   passed whatever gate that profile had — unless it's a Kids Profile.
    private var requiresAuthorization: Bool {
        guard guardianProfile != nil else { return false }
        if appState.profilesModel.activeProfile.isKids { return true }
        return !canCancel
    }

    /// Runs a management action, asking for a PIN first when required.
    private func request(_ action: ManagementAction) {
        guard requiresAuthorization, !authorized else {
            perform(action)
            return
        }
        authError = nil
        pendingAction = action
    }

    private func submitAuthorization(_ pin: String, action: ManagementAction) {
        guard let lock = guardianProfile?.lock, lock.matches(pin: pin) else {
            authError = String(localized: "Incorrect PIN. Try again.")
            return
        }
        authorized = true
        authError = nil
        pendingAction = nil
        perform(action)
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
