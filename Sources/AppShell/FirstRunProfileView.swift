#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// One-time first-run step on a brand-new install. The always-present default
/// profile has already been seeded with the signed-in identity (name + photo);
/// this lets the user keep it ("Looks good") or open the shared editor to
/// change the name/avatar.
///
/// Profiles are always on, so there is no opt-in gate in front of this screen.
/// Confirming is the only job here; the fact that more profiles exist is a
/// single quiet line UNDER the actions, because it's an aside, not a decision.
///
/// It never appears again once completed — signing out of everything and
/// re-adding a server skips straight into the app (see
/// `AppState.confirmFirstRunProfile()` / `ProfilesModel.markFirstRunProfileSetupComplete()`).
struct FirstRunProfileView: View {
    @Bindable var appState: AppState
    @State private var editing = false
    @FocusState private var focus: Field?

    private enum Field { case confirm, edit }

    private var profile: Profile { appState.profilesModel.activeProfile }

    var body: some View {
        VStack(spacing: 44) {
            Spacer(minLength: 0)

            VStack(spacing: 28) {
                ProfileAvatarView(profile: profile, size: 220)
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 10)

                VStack(spacing: 14) {
                    displayName
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)

                    VStack(spacing: 6) {
                        Text("Almost all settings are saved per profile.")
                        Text("You can add more profiles in Settings.")
                    }
                    .font(.body)
                    .plozzForeground(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 24) {
                Button {
                    editing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .frame(minWidth: 240)
                        .padding(.vertical, 8)
                }
                .plozzActionButton(role: .secondary)
                .focused($focus, equals: .edit)

                Button {
                    appState.confirmFirstRunProfile()
                } label: {
                    Text("Looks good")
                        .frame(minWidth: 280)
                }
                .plozzActionButton()
                .focused($focus, equals: .confirm)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focus, .confirm)
        // tvOS's defaultFocus can miss when this screen appears right after the
        // profile is seeded, so land focus on "Looks good" explicitly too.
        .onAppear { focus = .confirm }
        // Pressing Menu on this one-time setup screen accepts the seeded profile
        // and continues, so the app never suspends from here.
        .onExitCommand { appState.confirmFirstRunProfile() }
        .sheet(isPresented: $editing) {
            ProfileEditorView(
                editingProfile: profile,
                canDelete: false,
                photoSourceAccounts: appState.accountsProviders.accounts,
                plexHomeUsersFetcher: { await appState.plexHomeUsers.plexHomeUsers(forAccountID: $0) },
                onSave: { draft in
                    appState.profileFlow.saveProfile(draft)
                    editing = false
                    focus = .confirm
                },
                onCancel: {
                    editing = false
                    focus = .confirm
                }
            )
        }
    }

    /// Text rather than a resource: the profile's own name is content, and only
    /// the unnamed fallback is copy.
    private var displayName: Text {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? Text("Your Profile") : Text(verbatim: name)
    }

}
#endif
