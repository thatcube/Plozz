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
                    Text(greeting)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)

                    Text("This is your profile — keep it or make it your own.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 820)
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
        // Pressing Menu on this one-time setup screen accepts the seeded profile
        // and continues, so the app never suspends from here.
        .onExitCommand { appState.confirmFirstRunProfile() }
        .sheet(isPresented: $editing) {
            ProfileEditorView(
                editingProfile: profile,
                canDelete: false,
                photoSourceAccounts: appState.accounts,
                plexHomeUsersFetcher: { await appState.plexHomeUsers(forAccountID: $0) },
                onSave: { draft in
                    appState.saveProfile(draft)
                    editing = false
                },
                onCancel: { editing = false }
            )
        }
    }

    private var greeting: String {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "You’re all set" : "You’re all set, \(name)"
    }
}
#endif
