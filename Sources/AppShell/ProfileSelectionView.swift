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
/// people already are when they think about profiles, and it's where a new
/// household's second profile gets made; making them hunt through Settings for
/// it was the wrong shape. The screens it opens are the same ones Settings uses
/// — the cosmetic editor and `ProfileLockSetupView` — so there's one
/// implementation of each, reached from two places.
struct ProfileSelectionView: View {
    @Bindable var appState: AppState
    /// `true` when there is already an active session behind the picker, so the
    /// picker can be cancelled (Settings entry); `false` at first launch.
    let canCancel: Bool

    @Environment(\.themePalette) private var palette

    /// The profile whose cosmetics are being edited, if any.
    @State private var editingProfile: Profile?
    /// Set while creating a profile, so the sheet knows which kind to make.
    @State private var creating: CreationKind?
    /// A just-created profile waiting on the "want a lock?" offer.
    @State private var newlyCreated: Profile?
    /// Set once the user accepts the offer, presenting the PIN setup.
    @State private var lockTarget: Profile?

    private enum CreationKind: Identifiable {
        case ordinary
        case kids
        var id: String { self == .kids ? "kids" : "ordinary" }
        var isKids: Bool { self == .kids }
    }

    /// Whether the picker may create and edit profiles.
    ///
    /// Managing profiles from the picker is a hole if it's unconditional: the
    /// launch picker is *forced* when the profile we'd restore is locked, so an
    /// unrestricted "Add Profile" there would let anyone walk past a lock by
    /// simply making themselves a new profile. Same from inside a Kids Profile —
    /// a child could create an unrestricted one and step out of the restriction.
    ///
    /// So management needs someone to have proved they belong:
    /// - `canCancel` means there's a live session behind the picker (it was
    ///   opened from Settings → Switch Profile), so whatever gate that profile
    ///   had has already been passed — unless that profile is a Kids Profile.
    /// - If nothing in the household is locked there is nothing to protect, and
    ///   demanding proof would just block the common first-run case of adding a
    ///   second profile.
    private var canManageProfiles: Bool {
        if appState.profilesModel.activeProfile.isKids { return false }
        return canCancel || !appState.profilesModel.profiles.contains(where: \.isLocked)
    }

    var body: some View {
        ProfilePickerView(
            profiles: appState.profilesModel.profiles,
            activeProfileID: appState.profilesModel.activeProfileID,
            onSelect: { appState.profileFlow.switchProfile(to: $0.id) },
            onAddProfile: canManageProfiles ? { creating = .ordinary } : nil,
            onEditProfile: canManageProfiles ? { editingProfile = $0 } : nil,
            onAddKidsProfile: canManageProfiles ? { creating = .kids } : nil,
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
                    // (which `ProfileFlowModel.saveProfile` does) would strand a
                    // brand-new locked profile behind its own PIN.
                    let created = appState.createProfileWithoutSwitching(draft, isKids: kind.isKids)
                    creating = nil
                    newlyCreated = created
                },
                onCancel: { creating = nil }
            )
        }
        // Offer the lock right after creation. This is the moment the decision
        // makes sense — the alternative is that locking is something you only
        // discover later in Settings, which is how it ends up never being set.
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
    }
}
#endif
