#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// One-time first-run step shown after the user chose to set up profiles on a
/// brand-new install. The always-present default profile has already been
/// seeded with the signed-in identity (name + photo); this lets the user keep
/// it ("Looks good") or open the shared editor to change the name/avatar. The
/// Apple-TV-user explanation lives on the preceding `EnableProfilesView`.
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
                    Text(displayName)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)

                    Text("Profile created automatically")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text("We created this profile from your \(providerName) account. You can rename it or change the photo here, or any time in Settings.")
                        .font(.body)
                        .foregroundStyle(.secondary)
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
                .buttonStyle(.bordered)
                .focused($focus, equals: .edit)

                Button {
                    appState.confirmFirstRunProfile()
                } label: {
                    Text("Looks good")
                        .fontWeight(.semibold)
                        .frame(minWidth: 280)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
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
                    appState.saveProfile(draft)
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

    private var displayName: String {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Your Profile" : name
    }

    /// The provider the seeded identity came from — the first account added on
    /// this fresh install. Defaults to a neutral word if none is resolvable.
    private var providerName: String {
        appState.accountsProviders.accounts.first?.server.provider.displayName ?? "media"
    }
}
#endif
