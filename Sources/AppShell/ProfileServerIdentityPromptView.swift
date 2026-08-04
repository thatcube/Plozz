#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// Asks who a profile watches as on a server it has just switched on.
///
/// Turning a server on outside the setup step is the same decision setup makes,
/// with the same consequence: the watchlist import reads that server as whoever
/// the profile plays as, and with no binding that's the account owner. Silently
/// importing the owner's watchlist into a child's profile is precisely what the
/// setup step exists to prevent, so enabling a server later asks too.
///
/// Only appears for Plex, and only when there's an actual choice — a server with
/// one user has nothing to ask about.
struct ProfileServerIdentityPromptView: View {
    let appState: AppState
    let accountID: String
    let onFinish: () -> Void

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
        .onExitCommand(perform: onFinish)
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
                Text("Couldn't load the users for this server. You can set this later in Libraries.")
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Continue", action: onFinish)
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
