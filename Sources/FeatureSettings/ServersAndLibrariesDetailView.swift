#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings → Server Accounts (formerly "Accounts") detail.
///
/// Shows the household account pool grouped by server as a list of summary
/// rows. Each row drills into `ServerDetailView` (via `SettingsRoute.server`)
/// where the "Use this server" toggle, signed-in accounts, and per-library
/// Home visibility toggles live.
struct ServersAndLibrariesDetailView: View {
    let context: SettingsContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Server Accounts & Libraries")
                    .font(.largeTitle.bold())

                if context.accounts.isEmpty {
                    emptyState
                } else {
                    SettingsPanel(
                        footer: context.profilesEnabled
                            ? "Tap a server to manage which household accounts use it, its 'Use this server' toggle, and which libraries appear on Home."
                            : "Tap a server to manage its sign-ins and which libraries appear on Home."
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
        .task { await context.reloadLibraries() }
    }

    private var emptyState: some View {
        SettingsPanel(
            footer: "Sign in to a Jellyfin or Plex server to see your libraries on Home and report your playback back to the server."
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
                ProviderIcon(provider: group.providerKind, size: 28)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.serverName).font(.headline)
                    Text(summary(for: group))
                        .font(.subheadline)
                        .settingsRowSecondary()
                        .lineLimit(1)
                }
                Spacer()
                if context.profilesEnabled, isInUse(group) {
                    inUseChip
                }
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

    /// "In use" capsule with a focus-aware variant so the green stays legible
    /// against the inverted card fill (darker on the white card, lighter on
    /// the black card).
    private var inUseChip: some View {
        InUseChipView()
    }

    private func isInUse(_ group: ServerAccountGroup) -> Bool {
        group.accounts.contains { context.isAccountIncludedInActiveProfile($0.id) }
    }

    private func summary(for group: ServerAccountGroup) -> String {
        let accountCount = group.accounts.count
        let libraryCount: Int = {
            if case let .loaded(all) = context.discoveredLibraries {
                let ids = Set(group.accounts.map(\.id))
                return all.filter { ids.contains($0.accountID) }.count
            }
            return 0
        }()
        var parts: [String] = []
        if accountCount == 0 {
            parts.append("No one signed in")
        } else if accountCount == 1, let only = group.accounts.first {
            parts.append("Signed in as \(only.userName)")
        } else {
            parts.append("\(accountCount) sign-ins")
        }
        if libraryCount > 0 {
            parts.append("\(libraryCount) librar\(libraryCount == 1 ? "y" : "ies")")
        }
        return parts.joined(separator: " · ")
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

/// "In use" chip with focus-aware text + capsule fill so it stays legible
/// when the surrounding row inverts on focus. Reads the unified row focus
/// environment so it adapts uniformly across every row that uses it.
struct InUseChipView: View {
    @Environment(\.settingsRowIsFocused) private var focused
    @Environment(\.colorScheme) private var colorScheme

    private var capsuleTint: Color {
        guard focused else { return Color.green.opacity(0.18) }
        // On the inverted card the faint translucent green disappears; bump
        // the opacity so the chip still reads as a green pill, then let the
        // text color carry contrast against the card.
        return colorScheme == .dark
            ? Color(red: 0.10, green: 0.50, blue: 0.22).opacity(0.18) // dark green on white card
            : Color(red: 0.55, green: 0.95, blue: 0.65).opacity(0.28) // light green on black card
    }

    var body: some View {
        Text("In use")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(capsuleTint))
            .settingsRowGreenIndicator()
    }
}
#endif
