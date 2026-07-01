#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings → This Apple TV → Servers detail.
///
/// **Global / household scope.** Lists every server the household is signed in
/// to, grouped by server, as summary rows. Each row drills into
/// `ServerDetailView` to manage that server's sign-ins (add / sign out).
///
/// Personal choices — which Plex user a profile plays as, whether a profile
/// uses a server, and which libraries appear on a profile's Home — are NOT
/// here; they live on `<Profile>` › Your Libraries.
struct ServersAndLibrariesDetailView: View {
    let context: SettingsContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if context.accounts.isEmpty {
                    emptyState
                } else {
                    SettingsPanel(
                        footer: "These sign-ins are shared by everyone on this Apple TV. Tap a server to add or sign out accounts. Set what each profile sees under Profile › Your Libraries."
                    ) {
                        VStack(spacing: 0) {
                            let groups = serverGroups(from: context.accounts)
                            ForEach(Array(groups.enumerated()), id: \.element.serverKey) { idx, group in
                                if idx > 0 { Divider() }
                                serverSummaryRow(group)
                            }
                        }
                    }
                }

                addServerPanel
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }

    private var emptyState: some View {
        SettingsPanel(
            footer: "Sign in to a Jellyfin or Plex server. Sign-ins are shared across every profile on this Apple TV."
        ) {
            Text("You're not signed in to any servers yet.")
                .font(.headline)
        }
    }

    /// One server's at-a-glance row with a clear chevron so the affordance
    /// reads as "tap to open a level deeper," not just status.
    private func serverSummaryRow(_ group: ServerAccountGroup) -> some View {
        NavigationLink(value: SettingsRoute.server(key: group.serverKey)) {
            HStack(spacing: 16) {
                ProviderIcon(provider: group.providerKind, size: 48)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.serverName).font(.headline)
                    Text(summary(for: group))
                        .font(.subheadline)
                        .settingsRowSecondary()
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .settingsRowSecondary()
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
    }

    /// Global sign-in summary — who's signed in to this server, household-wide.
    private func summary(for group: ServerAccountGroup) -> String {
        let accountCount = group.accounts.count
        if accountCount == 0 {
            return "No one signed in"
        } else if accountCount == 1, let only = group.accounts.first {
            return "Signed in as \(only.userName)"
        } else {
            return "\(accountCount) sign-ins"
        }
    }

    private var addServerPanel: some View {
        SettingsPanel(
            footer: "Add another Jellyfin or Plex server. Plex shares one sign-in across profiles; each Jellyfin profile signs in with its own credentials."
        ) {
            Button(action: context.onAddAccount) {
                Label(context.accounts.isEmpty ? "Sign In to a Server" : "Add Server", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Server grouping (shared with ServerDetailView)

/// One server's view of the household account pool. Two profiles signed in
/// to the same Jellyfin server become two `accounts` here; one Plex sign-in
/// is a single entry. `serverKey` is the routing key used by `.server`.
struct ServerAccountGroup {
    let serverKey: String
    let serverName: String
    let providerKind: ProviderKind
    let accounts: [Account]
}

func serverGroups(from accounts: [Account]) -> [ServerAccountGroup] {
    var order: [String] = []
    var byKey: [String: ServerAccountGroup] = [:]
    for account in accounts {
        let key = serverKey(for: account)
        if byKey[key] == nil {
            order.append(key)
            byKey[key] = ServerAccountGroup(
                serverKey: key,
                serverName: account.server.name,
                providerKind: account.server.provider,
                accounts: []
            )
        }
        var grp = byKey[key]!
        grp = ServerAccountGroup(
            serverKey: grp.serverKey,
            serverName: grp.serverName,
            providerKind: grp.providerKind,
            accounts: grp.accounts + [account]
        )
        byKey[key] = grp
    }
    return order.compactMap { byKey[$0] }
}

func serverKey(for account: Account) -> String {
    // Server.name is user-edited but baseURL.host is stable. Combine with
    // provider so two providers that happen to share a hostname aren't
    // collapsed into one group.
    let host = account.server.baseURL.host?.lowercased() ?? account.server.baseURL.absoluteString
    return "\(account.server.provider.rawValue)|\(host)"
}
#endif
