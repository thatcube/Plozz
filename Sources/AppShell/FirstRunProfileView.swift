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
/// It carries the "what profiles are for" explainer the retired prompt used to
/// show, as a short highlight row under the seeded profile — the household
/// still learns it can add people, without being asked to make a decision.
///
/// It never appears again once completed — signing out of everything and
/// re-adding a server skips straight into the app (see
/// `AppState.confirmFirstRunProfile()` / `ProfilesModel.markFirstRunProfileSetupComplete()`).
struct FirstRunProfileView: View {
    @Bindable var appState: AppState
    @State private var editing = false
    @Environment(\.themePalette) private var palette
    @FocusState private var focus: Field?

    private enum Field { case confirm, edit }

    private struct Highlight: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
    }

    private let highlights = [
        Highlight(icon: "house.fill", text: "Personal Home rows and library visibility"),
        Highlight(icon: "externaldrive.fill", text: "Choose which servers each profile uses"),
        Highlight(icon: "arrow.down.circle.fill", text: "Separate watch history and downloads"),
    ]

    private var profile: Profile { appState.profilesModel.activeProfile }

    var body: some View {
        VStack(spacing: 36) {
            Spacer(minLength: 0)

            VStack(spacing: 24) {
                ProfileAvatarView(profile: profile, size: 180)
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
                        .plozzForeground(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 760)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 16) {
                Text("Add a profile for anyone else in Settings — each one keeps its own:")
                    .font(.callout.weight(.medium))
                    .plozzForeground(.secondary)
                    .multilineTextAlignment(.center)

                HStack(alignment: .top, spacing: 20) {
                    ForEach(highlights) { highlight in
                        highlightCard(highlight)
                    }
                }
                .frame(maxWidth: 1180)
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

    private func highlightCard(_ highlight: Highlight) -> some View {
        VStack(spacing: 12) {
            Image(systemName: highlight.icon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(palette.accent)

            Text(highlight.text)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
