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
        .sheet(isPresented: $showingEditor) {
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
                offersPlexPINReuse: boundToProtectedPlexUser(profile),
                householdHasOtherLock: context.profiles.contains {
                    $0.id != profile.id && $0.isLocked
                },
                onEditAppearance: { showingEditor = true },
                onSetLock: { context.onSetProfileLock(profileID, $0) },
                onSetKids: { context.onSetKidsProfile(profileID, $0) },
                onDelete: canDelete ? { context.onDeleteProfile(profileID) } : nil,
                isUnlocked: context.isProfileUnlocked(profileID),
                onUnlock: { context.onProfileUnlocked(profileID) }
            )
            .tvOSFocusSection()
        }
    }

    /// Whether this profile plays as a Plex Home user that already asks for a
    /// PIN — the only case where offering to reuse it makes sense.
    private func boundToProtectedPlexUser(_ profile: Profile) -> Bool {
        if profile.plexHomeUserRequiresPIN == true { return true }
        return profile.plexHomeUserBindings?.values.contains { $0.requiresPIN == true } ?? false
    }

}
#endif
