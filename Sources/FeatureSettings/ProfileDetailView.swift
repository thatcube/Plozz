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
                Text("Profile")
                    .font(.largeTitle.bold())

                activeProfilePanel
                askOnStartupPanel
                profilesListPanel
                if context.profiles.count == 1 {
                    disablePanel
                }
            }
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

    private var activeProfilePanel: some View {
        SettingsPanel(
            title: "Current profile",
            footer: "Switching profiles swaps every setting on this Settings screen (theme, subtitles, spoilers, Trakt) and which servers/libraries you watch. The last-used profile is remembered for this Apple TV user."
        ) {
            HStack(spacing: 20) {
                ProfileAvatarView(profile: context.activeProfile, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.activeProfile.name).font(.title3.weight(.semibold))
                    Text("Active profile")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editorContext = .edit(context.activeProfile)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(action: context.onSwitchProfile) {
                    Label("Switch Profile", systemImage: "person.2.circle")
                }
            }
        }
    }

    private var askOnStartupPanel: some View {
        SettingsPanel(
            footer: "When on, Plozz shows the “Who's watching?” picker every time the app launches. When off, it boots straight into the last-used profile on this Apple TV user."
        ) {
            Toggle("Ask which profile on startup", isOn: Binding(
                get: { context.askProfileOnStartup },
                set: { context.onSetAskProfileOnStartup($0) }
            ))
            .disabled(context.profiles.count <= 1)
        }
    }

    private var profilesListPanel: some View {
        SettingsPanel(
            title: "Profiles",
            footer: "Each profile keeps its own preferences, Home customization, and Trakt account. Server logins live in the household pool — share them between profiles in Server Accounts."
        ) {
            VStack(alignment: .leading, spacing: 12) {
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
            .focusSection()
        }
    }

    private func profileRow(_ profile: Profile) -> some View {
        HStack(spacing: 16) {
            ProfileAvatarView(profile: profile, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.headline)
                if profile.id == context.activeProfile.id {
                    Text("Active")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            Button {
                editorContext = .edit(profile)
            } label: {
                Image(systemName: "pencil")
            }
            .accessibilityLabel("Edit \(profile.name)")
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
