#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// Settings → Libraries → *server* → **Watching as** (Jellyfin / Emby).
///
/// A page rather than an inline list, and reachable even when there's only one
/// user signed in. You can't tell that the person you want is missing until you
/// look — so "sign in as someone else" has to live where you go to look, which
/// means the row must always open something.
///
/// Plex has its own page (`PlexLinkedUserDetailView`): its Home users come from
/// one account, so that list is fetched rather than assembled from sign-ins.
struct ServerUserDetailView: View {
    let scope: ProfileLibrariesScope
    /// Identifies the server whose sign-ins are listed.
    let serverKey: String

    @Environment(\.themePalette) private var palette
    @State private var revision = 0

    private var group: ServerAccountGroup? {
        serverGroups(from: scope.accounts).first { $0.serverKey == serverKey }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsPageHeader(
                    "Watching as",
                    subtitle: group.map {
                        "Who this profile is on \($0.serverName)."
                    } ?? "Who this profile is on this server."
                )
                if let group {
                    usersPanel(group)
                    addUserPanel(group)
                }
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }

    private func usersPanel(_ group: ServerAccountGroup) -> some View {
        SettingsPanel(footer: "This profile watches, and keeps its watchlist, as the user you pick.") {
            VStack(spacing: 14) {
                ForEach(group.accounts) { account in
                    Button {
                        choose(account, in: group)
                    } label: {
                        HStack(spacing: 16) {
                            AccountAvatar(
                                name: account.userName,
                                imageURL: resolvedAvatarURL(for: account),
                                size: 52
                            )
                            Text(verbatim: account.userName)
                                .font(.callout.weight(.medium))
                            Spacer(minLength: 12)
                            if scope.isAccountIncludedInActiveProfile(account.id) {
                                SettingsSelectionIndicator()
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsFocusButtonStyle())
                }
            }
            .tvOSFocusSection()
        }
    }

    /// Signing in an additional user, from where you'd discover one is missing.
    private func addUserPanel(_ group: ServerAccountGroup) -> some View {
        SettingsPanel(footer: "Signing in adds the user to this Apple TV. Any profile can then watch as them.") {
            Button {
                if let server = group.accounts.first?.server {
                    scope.onAddUser(server)
                }
            } label: {
                Label("Add Another User", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
        }
    }

    /// Exactly one sign-in represents the profile on a server, so choosing one
    /// deselects the rest.
    private func choose(_ chosen: Account, in group: ServerAccountGroup) {
        for account in group.accounts {
            scope.onSetAccountIncluded(account.id, account.id == chosen.id)
        }
        revision += 1
    }
}
#endif
