#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// Settings → Everyone → Profiles → *one profile*.
///
/// Everything that is true *about* a profile as an entity, for any profile in
/// the household rather than just the active one: how it looks, whether it needs
/// a PIN to open, whether it's restricted, and whether it exists at all.
///
/// Managing every profile's lock from one screen — instead of each person
/// locking their own from inside it — is what Netflix does, and it's the only
/// arrangement that actually works here: a Kids Profile deliberately can't reach
/// this section, so a grown-up has to be able to set the child's restrictions
/// (and their own lock) from a profile the child isn't using.
///
/// Appearance stays behind a sheet in the cosmetic editor, which is deliberately
/// cosmetics-only — "what the profile looks like" separated from "what it can
/// do". A permission has no business in the avatar picker.
struct ProfileSettingsDetailView: View {
    let context: SettingsContext
    let profileID: String
    /// Whether these settings currently reach the user's other devices, so a lock
    /// set here can say when it's device-only.
    let syncEnabled: Bool

    @State private var showingEditor = false
    /// PIN setups are PUSHED here, not presented: modals asked for from inside
    /// the Settings tab are silently dropped when `RootView`'s stacked covers
    /// contest the slot. Same reason Appearance above is a push.
    @State private var showingLockSetup = false
    @State private var showingParentalSetup = false

    /// Read live from the context so the page reflects edits made on it (a lock
    /// added, a rename) without needing its own copy to be invalidated.
    private var profile: Profile? {
        context.profiles.first(where: { $0.id == profileID })
    }

    /// The first profile is the household's default and can't be deleted.
    private var canDelete: Bool {
        profileID != context.profiles.first?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let profile {
                    SettingsPageHeader(
                        verbatim: profile.name,
                        subtitle: "How this profile looks, and who can open it."
                    )
                    actionsPanel(profile)
                }
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        // Pushed, not presented. Modals requested from inside the Settings tab
        // are unreliable — `RootView` stacks several `fullScreenCover` modifiers
        // on one host, and a contested slot silently drops the request (the
        // header's Edit button did nothing for exactly this reason). A push uses
        // the navigation stack this page already lives in.
        .navigationDestination(isPresented: $showingLockSetup) {
            if let profile {
                ProfileLockSetupView(
                    profile: profile,
                    offersPlexPINReuse: profile.playsAsPINProtectedPlexUser,
                    syncEnabled: syncEnabled,
                    validatePlexPIN: { await context.validatePlexPIN($0, profileID) },
                    onComplete: { lock in
                        context.onSetProfileLock(profileID, lock)
                        showingLockSetup = false
                    },
                    onCancel: { showingLockSetup = false }
                )
                .toolbar(.hidden, for: .tabBar)
            }
        }
        .navigationDestination(isPresented: $showingParentalSetup) {
            ParentalPINSetupView(
                onComplete: { pin in
                    context.onSetParentalPIN(pin)
                    showingParentalSetup = false
                },
                onCancel: { showingParentalSetup = false }
            )
            .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showingEditor) {
            if let profile {
                ProfileEditorView(
                    editingProfile: profile,
                    canDelete: false,
                    photoSourceAccounts: context.accounts,
                    plexHomeUsersFetcher: context.plexHomeUsersFetcher,
                    onSave: { draft in
                        context.onSaveProfile(draft)
                        showingEditor = false
                    },
                    onLiveChange: { context.onUpdateProfileCosmetics($0) },
                    onCancel: { showingEditor = false }
                )
                .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    // MARK: Actions

    /// The same list the picker's Edit sheet shows — one implementation of
    /// "what can I do to this profile", reached from two places.
    ///
    /// Note there's no longer a Profile Lock *page*: selecting the lock row goes
    /// straight to choosing a PIN (or asks change-or-remove when one is already
    /// set). The page it replaced held a status line and a button that opened the
    /// real screen, which was two presses of nothing.
    private func actionsPanel(_ profile: Profile) -> some View {
        SettingsPanel {
            ProfileActionsList(
                profile: profile,
                syncEnabled: syncEnabled,
                offersPlexPINReuse: profile.playsAsPINProtectedPlexUser,
                hasParentalPIN: context.hasParentalPIN,
                // Sealed only when this profile is BOTH a Kids Profile and the
                // one currently open: a grown-up editing a child's profile from
                // their own is exactly who should be able to change it.
                restrictedActionsSealed: profile.isKids
                    && context.activeProfile.id == profileID
                    && context.hasParentalPIN
                    && !context.isParentalUnlocked,
                onEditAppearance: { showingEditor = true },
                onEditLock: { showingLockSetup = true },
                onCreateParentalPIN: { showingParentalSetup = true },
                onSetLock: { context.onSetProfileLock(profileID, $0) },
                onSetKids: { context.onSetKidsProfile(profileID, $0) },
                onSetParentalPIN: context.onSetParentalPIN,
                validatePlexPIN: {
                    await context.validatePlexPIN($0, profileID)
                },
                onDelete: canDelete ? { context.onDeleteProfile(profileID) } : nil,
                isUnlocked: context.isProfileUnlocked(profileID),
                onUnlock: { context.onProfileUnlocked(profileID) }
            )
            .tvOSFocusSection()
        }
    }


}
#endif
