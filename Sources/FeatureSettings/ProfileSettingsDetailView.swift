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

    @State private var showingEditor = false
    @State private var confirmDelete = false

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
                    identityPanel(profile)
                    accessPanel(profile)
                    if canDelete { deletePanel(profile) }
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
        .alert("Delete this profile?", isPresented: $confirmDelete) {
            Button("Delete Profile", role: .destructive) {
                context.onDeleteProfile(profileID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting removes this profile's preferences (theme, playback, subtitles, spoilers, trackers) and which servers it includes. Signed-in server accounts stay shared.")
        }
    }

    // MARK: Identity

    private func identityPanel(_ profile: Profile) -> some View {
        SettingsPanel {
            Button {
                showingEditor = true
            } label: {
                HStack(spacing: 16) {
                    ProfileAvatarView(profile: profile, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Appearance").font(.headline)
                        Text("Name, avatar, and colour")
                            .font(.footnote)
                            .settingsRowSecondary()
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .settingsRowSecondary()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Access

    private func accessPanel(_ profile: Profile) -> some View {
        SettingsPanel(footer: KidsProfileCopy.explanation) {
            VStack(alignment: .leading, spacing: 14) {
                NavigationLink(value: SettingsRoute.profileLock(profileID: profile.id)) {
                    HStack(spacing: 16) {
                        Image(systemName: profile.isLocked ? "lock" : "lock.open")
                            .frame(width: 30, height: 30)
                        Text(ProfileLockCopy.title).font(.callout.weight(.medium))
                        Spacer()
                        Text(profile.isLocked ? ProfileLockCopy.on : ProfileLockCopy.off)
                            .settingsRowSecondary()
                        Image(systemName: "chevron.right")
                            .settingsRowSecondary()
                    }
                }

                PlozzDivider()

                Toggle(isOn: Binding(
                    get: { profile.isKids },
                    set: { context.onSetKidsProfile(profile.id, $0) }
                )) {
                    Text(KidsProfileCopy.title)
                }
                .toggleStyle(SettingsSwitchToggleStyle())

                // Only nag once the restriction is on AND nothing else is
                // locked — that's the combination that leaves the child a way
                // straight into a grown-up's profile.
                if profile.isKids, !householdHasAnyLock {
                    Label {
                        Text(KidsProfileCopy.pairWithLock)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .settingsRowSecondary()
                }
            }
            .tvOSFocusSection()
        }
    }

    /// Whether any *other* profile carries a lock. A Kids Profile only contains
    /// anyone if there's something locked to keep them out of.
    private var householdHasAnyLock: Bool {
        context.profiles.contains { $0.id != profileID && $0.isLocked }
    }

    // MARK: Delete

    private func deletePanel(_ profile: Profile) -> some View {
        SettingsPanel {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Profile", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
#endif
