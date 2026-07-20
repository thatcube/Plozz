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
                    if let summary = summary(for: group) {
                        Text(summary)
                            .font(.subheadline)
                            .settingsRowSecondary()
                            .lineLimit(1)
                    }
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
    /// `nil` when there's nothing worth a second line (a credential-free NFS
    /// connection), so the row shows just the server name.
    private func summary(for group: ServerAccountGroup) -> String? {
        let accountCount = group.accounts.count
        if accountCount == 0 {
            return "No one signed in"
        } else if accountCount == 1, let only = group.accounts.first {
            let userName = only.userName.trimmingCharacters(in: .whitespaces)
            if userName.isEmpty {
                // NFS is credential-free (AUTH_UNIX, no login) — no subtitle. An
                // empty user on any other share is an anonymous/guest connection.
                return group.transportKind == .nfs ? nil : "Guest access"
            }
            return "Signed in as \(userName)"
        } else {
            return "\(accountCount) sign-ins"
        }
    }
}

#endif
