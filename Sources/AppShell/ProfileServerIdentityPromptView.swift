#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// Asks who a profile watches as on a server it has just switched on.
///
/// Turning a server on outside the setup step is the same decision setup makes,
/// with the same consequence: the watchlist reads that server as whoever the
/// profile plays as, and with no binding that's the account owner. Silently
/// showing the owner's watchlist in a child's profile is precisely what the
/// setup step exists to prevent, so enabling a server later asks too.
///
/// Backing out DECLINES. It used to clear the question and then read the server
/// as the owner anyway, which turned "I'd rather not say" into "yes".
///
/// Only appears for Plex, and only when there's an actual choice — a server with
/// one user has nothing to ask about.
struct ProfileServerIdentityPromptView: View {
    let appState: AppState
    let accountID: String
    let onFinish: () -> Void
    let onDecline: () -> Void

    @Environment(\.themePalette) private var palette
    @State private var users: LoadState<[PlexHomeUser]> = .idle

    private var account: Account? {
        appState.accountsProviders.accounts.first { $0.id == accountID }
    }

    var body: some View {
        ZStack {
            AppBackground(palette: palette).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    content
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 60)
                .padding(.vertical, 56)
            }
            .scrollClipDisabled()
        }
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .task { await load() }
        #if os(tvOS)
        .onExitCommand(perform: onDecline)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who are you on \(account?.server.name ?? "this server")?")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("This profile will watch — and keep its watchlist — as whoever you pick.")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch users {
        case .idle, .loading:
            HStack(spacing: 12) { ProgressView(); Text("Loading users…") }
        case .empty, .failed:
            // Nothing to choose, or the list is unavailable — don't block the
            // person over a question that has no answers.
            VStack(alignment: .leading, spacing: 20) {
                Text(
                    "Couldn't load the users for this server. Its watchlist stays out of this profile until you pick someone — switch the server off and on again to try.",
                    comment: "Shown when a server's user list can't be loaded, so nobody can be picked. Explains that the server's own watchlist won't be used here."
                )
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                // Plain shared key: "Continue" is used across the app, and
                // attaching a comment specific to this screen would describe it
                // wrongly everywhere else it appears.
                Button("Continue", action: onDecline)
            }
        case let .loaded(list):
            VStack(spacing: 14) {
                ForEach(list, id: \.id) { user in
                    Button {
                        appState.plexHomeUsers.setPlexHomeUserForActiveProfile(
                            accountID: accountID,
                            user: user
                        )
                        onFinish()
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: user.requiresPIN ? "lock.fill" : "person.crop.circle")
                            Text(verbatim: user.name)
                            Spacer()
                            if user.isAdmin {
                                Text("Owner").foregroundStyle(palette.secondaryText)
                            }
                        }
                    }
                    .buttonStyle(SettingsFocusButtonStyle())
                }
                // Backing out has to be sayable. Left as a dismissal it read as
                // consent, and the consequence — this server's watchlist showing
                // up in the profile as its owner's — was invisible.
                Button(action: onDecline) {
                    Text(
                        "Don't use this server's watchlist",
                        comment: "Button declining to pick a user, which leaves the server's own watchlist out of this profile."
                    )
                }
                .buttonStyle(SettingsFocusButtonStyle())
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private func load() async {
        guard users.value == nil else { return }
        users = .loading
        let list = await appState.plexHomeUsers.plexHomeUsers(forAccountID: accountID)
        // One user is no choice at all — let it through rather than showing a
        // page with a single option.
        guard list.count > 1 else {
            onFinish()
            return
        }
        users = .loaded(list)
    }
}
#endif
