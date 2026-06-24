#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings → Server Accounts (formerly "Accounts") detail.
///
/// The household account pool grouped by server. Each server group shows:
/// - which household account(s) are signed in on it (Jellyfin = per-user
///   login, so each profile signs in separately; Plex = one login that
///   exposes multiple Home users)
/// - the active profile's per-server "Use this server" toggle (writes
///   through to the profile's account subset, controlling whether the
///   server's libraries appear on Home and whether playback is reported
///   back to it)
/// - the server's libraries with the existing per-library Home visibility
///   toggles
///
/// Edit-profile / add-profile flows live in Profile detail; this page is
/// strictly about *servers*.
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
                    ForEach(serverGroups(), id: \.serverKey) { group in
                        serverGroupPanel(group)
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

    // MARK: - Server group panel

    private func serverGroupPanel(_ group: ServerAccountGroup) -> some View {
        SettingsPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ProviderIcon(provider: group.providerKind, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.serverName).font(.headline)
                        Text(group.providerKind.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // Active profile's per-server inclusion ("Use this server").
                // Combined toggle: when on the server's libraries appear on
                // Home AND playback is reported back to it. Defaults to ON
                // for every signed-in server; explicitly disabling drops both.
                if context.profilesEnabled {
                    Toggle(isOn: useThisServerBinding(group)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Use this server").font(.headline)
                            Text("Show its libraries on Home and report playback back to it as \(context.activeProfile.name).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .disabled(group.accounts.isEmpty)
                }

                if !group.accounts.isEmpty {
                    Divider()
                    Text("Signed in as")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.accounts) { account in
                        accountRow(account)
                    }
                } else {
                    Text("No one in this household is signed in to this server yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider()
                librarySection(for: group)
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 16) {
            AccountAvatar(name: account.userName, imageURL: resolvedAvatarURL(for: account), size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.userName).font(.headline)
                Text(account.server.baseURL.host ?? account.server.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if account.id == context.activeAccountID {
                Label("Primary", systemImage: "star.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Primary account")
            }
            Button(role: .destructive) {
                context.onRemoveAccount(account)
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Remove \(account.userName)")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Libraries

    @ViewBuilder
    private func librarySection(for group: ServerAccountGroup) -> some View {
        switch context.discoveredLibraries {
        case .idle, .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("Discovering libraries…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .empty:
            Text("No libraries found on this server.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed:
            HStack {
                Text("Couldn't load libraries.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await context.reloadLibraries() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
        case let .loaded(all):
            let libs = libraries(for: group, in: all)
            if libs.isEmpty {
                Text("No libraries found on this server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Show on Home")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(libs) { aggregated in
                    Toggle(isOn: Binding(
                        get: { context.homeVisibility.isVisible(aggregated.key) },
                        set: { context.homeVisibility.setVisible($0, for: aggregated.key) }
                    )) {
                        Text(aggregated.library.title)
                    }
                }
            }
        }
    }

    private func libraries(for group: ServerAccountGroup, in all: [AggregatedLibrary]) -> [AggregatedLibrary] {
        let accountIDs = Set(group.accounts.map(\.id))
        return all.filter { accountIDs.contains($0.accountID) }
    }

    // MARK: - Add server

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

    // MARK: - "Use this server" toggle binding

    private func useThisServerBinding(_ group: ServerAccountGroup) -> Binding<Bool> {
        Binding(
            get: {
                // If ANY of this server's accounts is included for the active
                // profile, the server is considered "in use" for that profile.
                group.accounts.contains { context.isAccountIncludedInActiveProfile($0.id) }
            },
            set: { included in
                // Toggle every household account on this server in or out at
                // once: a profile that "uses" a server uses every Jellyfin
                // login (typically its own) AND the Plex login that backs it.
                for account in group.accounts {
                    context.onSetAccountIncluded(account.id, included)
                }
            }
        )
    }

    // MARK: - Grouping

    private struct ServerAccountGroup {
        let serverKey: String
        let serverName: String
        let providerKind: ProviderKind
        let accounts: [Account]
    }

    /// Groups household accounts by (provider, server host). Two profiles
    /// signed in to the same Jellyfin server become two accounts in the same
    /// group; one Plex sign-in is a single account in its own group.
    private func serverGroups() -> [ServerAccountGroup] {
        var order: [String] = []
        var byKey: [String: ServerAccountGroup] = [:]
        for account in context.accounts {
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

    private func serverKey(for account: Account) -> String {
        // Server.name is user-edited, but server.baseURL.host is stable.
        // Combine with provider so two providers that happen to share a
        // hostname aren't collapsed.
        let host = account.server.baseURL.host?.lowercased() ?? account.server.baseURL.absoluteString
        return "\(account.server.provider.rawValue)|\(host)"
    }
}
#endif
