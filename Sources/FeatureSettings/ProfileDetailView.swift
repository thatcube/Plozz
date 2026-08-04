#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// Settings → Profile detail.
///
/// Profile-level controls only: switch profile, edit the *currently selected*
/// profile, and toggle the launch picker. Per-server membership lives in
/// Servers & Libraries — this page intentionally does not duplicate that.
struct ProfileDetailView: View {
    let context: SettingsContext
    let appVersion: String
    let appBuild: String
    let repoURL: String

    @State private var showingNewProfile = false

    /// Settings receives profiles in the model's active-first/recency order.
    private var orderedProfiles: [Profile] { context.profiles }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsPageHeader(
                    "Profiles",
                    subtitle: "Each profile keeps its own settings — theme, playback, subtitles, spoilers, trackers, and Home layout. Only your servers are shared. Open one to lock it or make it a Kids Profile."
                )
                profilesListPanel
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .sheet(isPresented: $showingNewProfile) {
            ProfileEditorView(
                canDelete: false,
                photoSourceAccounts: context.accounts,
                existingColorIndices: context.profiles.map(\.colorIndex),
                existingEmojiAvatars: context.profiles.compactMap(\.avatarEmoji),
                plexHomeUsersFetcher: context.plexHomeUsersFetcher,
                onSave: { draft in
                    // Same path as the picker: create, switch in, then the
                    // app-level setup step. Routing both through one call is what
                    // stops a profile created here from skipping setup.
                    context.onCreateProfile(draft)
                    showingNewProfile = false
                },
                onCancel: { showingNewProfile = false }
            )
        }
    }

    private var profilesListPanel: some View {
        SettingsPanel {
            VStack(alignment: .leading, spacing: 12) {
                // Whether the "Who's watching?" picker appears at launch. Only
                // meaningful with 2+ profiles; pinned to the top of the panel.
                if context.profiles.count > 1 {
                    Toggle("Ask who's watching on startup", isOn: Binding(
                        get: { context.askProfileOnStartup },
                        set: { context.onSetAskProfileOnStartup($0) }
                    ))
                    .toggleStyle(SettingsSwitchToggleStyle())
                    PlozzDivider()
                }
                ForEach(orderedProfiles) { profile in
                    profileRow(profile)
                }
                Button {
                    showingNewProfile = true
                } label: {
                    Label("Add Profile", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .tvOSFocusSection()
        }
    }

    private func profileRow(_ profile: Profile) -> some View {
        NavigationLink(value: SettingsRoute.profileSettings(profileID: profile.id)) {
            HStack(alignment: .center, spacing: 16) {
                ProfileAvatarView(profile: profile, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).font(.headline)
                    if profile.id == context.activeProfile.id {
                        StatusChip("Active")
                    }
                }
                Spacer()
                // Glance the access state so the list answers "who's locked?"
                // and "which one is the kid's?" without drilling into each.
                if profile.isKids {
                    Image(systemName: "figure.and.child.holdinghands")
                        .settingsRowSecondary()
                }
                if profile.isLocked {
                    Image(systemName: "lock.fill")
                        .settingsRowSecondary()
                }
                Image(systemName: "chevron.right")
                    .settingsRowSecondary()
            }
            .padding(.vertical, 2)
        }
    }

}
#endif
