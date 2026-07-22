#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// Settings → Profile detail.
///
/// Profile-level controls only: switch profile, edit the *currently selected*
/// profile, toggle the launch picker, and (for single-profile households)
/// turn profiles off entirely. Per-server membership lives in Servers &
/// Libraries — this page intentionally does not duplicate that.
struct ProfileDetailView: View {
    let context: SettingsContext
    let appVersion: String
    let appBuild: String
    let repoURL: String

    @State private var editorContext: EditorContext?

    private enum EditorContext: Identifiable {
        case edit(Profile)
        case new
        var id: String {
            switch self {
            case let .edit(p): return "edit.\(p.id)"
            case .new: return "new"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsPageHeader(
                    "Profiles",
                    subtitle: "Each profile keeps its own settings — theme, playback, subtitles, spoilers, trackers, and Home layout. Only your servers are shared."
                )
                profilesListPanel
                if context.profiles.count == 1 {
                    disablePanel
                }
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .sheet(item: $editorContext) { ctx in
            switch ctx {
            case let .edit(profile):
                ProfileEditorView(
                    editingProfile: profile,
                    canDelete: profile.id != context.profiles.first?.id,
                    photoSourceAccounts: context.accounts,
                    plexHomeUsersFetcher: context.plexHomeUsersFetcher,
                    onSave: { draft in
                        context.onSaveProfile(draft)
                        editorContext = nil
                    },
                    onLiveChange: { context.onUpdateProfileCosmetics($0) },
                    onDelete: {
                        context.onDeleteProfile(profile.id)
                        editorContext = nil
                    },
                    onCancel: { editorContext = nil }
                )
            case .new:
                ProfileEditorView(
                    canDelete: false,
                    photoSourceAccounts: context.accounts,
                    existingColorIndices: context.profiles.map(\.colorIndex),
                    plexHomeUsersFetcher: context.plexHomeUsersFetcher,
                    onSave: { draft in
                        context.onSaveProfile(draft)
                        editorContext = nil
                    },
                    onCancel: { editorContext = nil }
                )
            }
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
                    Divider()
                }
                ForEach(context.profiles) { profile in
                    profileRow(profile)
                }
                Button {
                    editorContext = .new
                } label: {
                    Label("Add Profile", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .tvOSFocusSection()
        }
    }

    private func profileRow(_ profile: Profile) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ProfileAvatarView(profile: profile, size: 40)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.headline)
                if profile.id == context.activeProfile.id {
                    StatusChip("Active")
                }
            }
            Spacer()
            Button {
                editorContext = .edit(profile)
            } label: {
                Image(systemName: "pencil")
            }
            .accessibilityLabel("Edit \(profile.name)")
            .padding(.top, 6)
        }
        .padding(.vertical, 2)
    }

    private var disablePanel: some View {
        SettingsPanel(
            footer: "Hide all profile UI for solo use. You can re-enable Profiles anytime."
        ) {
            Button(role: .destructive, action: context.onDisableProfiles) {
                Label("Turn Profiles Off", systemImage: "person.crop.circle.badge.minus")
            }
        }
    }
}
#endif
