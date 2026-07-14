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
                SettingsPageHeader(
                    "Servers",
                    subtitle: "Sign-ins are shared by everyone on this Apple TV. Choose what each profile sees under Profile › Your Libraries."
                )
                SettingsPanel {
                    // Rows separated by a gap rather than flush dividers: the
                    // focus lift bleeds outward and would otherwise paint over a
                    // divider sitting directly against a row.
                    VStack(spacing: 16) {
                        if context.accounts.isEmpty {
                            Text("You're not signed in to any servers yet.")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 14)
                                .padding(.horizontal, 14)
                        } else {
                            let groups = serverGroups(from: context.accounts)
                            ForEach(groups, id: \.serverKey) { group in
                                serverSummaryRow(group)
                            }
                        }
                        Button(action: context.onAddAccount) {
                            Label(context.accounts.isEmpty ? "Sign In to a Server" : "Add Server", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 14)
                                .padding(.horizontal, 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
                    }
                }
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }

    /// One server's at-a-glance row with a clear chevron so the affordance
    /// reads as "tap to open a level deeper," not just status.
    private func serverSummaryRow(_ group: ServerAccountGroup) -> some View {
        NavigationLink(value: SettingsRoute.server(key: group.serverKey)) {
            HStack(alignment: .top, spacing: 16) {
                ProviderIcon(provider: group.providerKind, size: 48, mediaShareTransport: group.transportKind)
                    .frame(width: 36)
                    .padding(.top, 4)
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
                    .padding(.top, 14)
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

    /// For a media share, the file-share transport (SMB/WebDAV/NFS/…) shown as a
    /// badge on the shared drive icon. `nil` for a dedicated media server, which
    /// uses its branded logo instead.
    var transportKind: MediaShareTransportKind? {
        guard providerKind == .mediaShare else { return nil }
        return MediaShareTransportKind(mediaShareScheme: accounts.first?.server.baseURL.scheme)
    }
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
    // Media shares are the exception: a host can expose SEVERAL distinct shares
    // — an SMB share and a WebDAV share on the same NAS, or two WebDAV shares on
    // different ports/paths — and each is its own "server" the user adds and
    // removes independently. Keying a share by host alone would collapse them
    // into one Settings row (they'd still each show on Home, which doesn't group
    // by host — exactly the "WebDAV missing from Settings" symptom). So key a
    // share by its full root: transport scheme + host + port + path. The share's
    // username is deliberately NOT part of the key, so two users of the SAME
    // share (e.g. `brandon` and `sister`) still group under one server row, just
    // like multiple profiles on one media server.
    if account.server.provider == .mediaShare {
        let url = account.server.baseURL
        let scheme = (url.scheme ?? "").lowercased()
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return "\(account.server.provider.rawValue)|\(scheme)://\(host)\(port)\(path)"
    }
    return "\(account.server.provider.rawValue)|\(host)"
}
#endif
