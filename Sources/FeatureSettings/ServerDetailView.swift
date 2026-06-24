#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings → Server Accounts → <Server> detail.
///
/// All of the controls that used to live inline on the Servers list now
/// belong here, behind a drill-in row:
/// - "Use this server" toggle (per-profile fan-out across every household
///   account on this server)
/// - Signed-in accounts (Jellyfin = per-profile; Plex = one shared login)
/// - Per-library "Show on Home" toggles
struct ServerDetailView: View {
    let context: SettingsContext
    let serverKey: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let group = currentGroup {
                    header(group)
                    useThisServerPanel(group)
                    accountsPanel(group)
                    librariesPanel(group)
                } else {
                    Text("This server is no longer signed in.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .task { await context.reloadLibraries() }
    }

    private var currentGroup: ServerAccountGroup? {
        serverGroups(from: context.accounts).first { $0.serverKey == serverKey }
    }

    // MARK: - Header

    private func header(_ group: ServerAccountGroup) -> some View {
        HStack(spacing: 16) {
            ProviderIcon(provider: group.providerKind, size: 36)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.serverName).font(.largeTitle.bold())
                Text(group.providerKind.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Use this server

    @ViewBuilder
    private func useThisServerPanel(_ group: ServerAccountGroup) -> some View {
        if context.profilesEnabled {
            SettingsPanel(
                footer: "When on, this server's libraries appear on Home and playback is reported back to it as \(context.activeProfile.name)."
            ) {
                Toggle(isOn: useThisServerBinding(group)) {
                    Text("Use this server").font(.headline)
                }
                .disabled(group.accounts.isEmpty)
            }
        }
    }

    private func useThisServerBinding(_ group: ServerAccountGroup) -> Binding<Bool> {
        Binding(
            get: {
                group.accounts.contains { context.isAccountIncludedInActiveProfile($0.id) }
            },
            set: { included in
                for account in group.accounts {
                    context.onSetAccountIncluded(account.id, included)
                }
            }
        )
    }

    // MARK: - Accounts

    private func accountsPanel(_ group: ServerAccountGroup) -> some View {
        SettingsPanel(
            footer: group.providerKind == .plex
                ? "Plex shares one sign-in across the household; each profile picks its own Plex user from the profile page."
                : "Jellyfin signs in per profile. Each profile uses its own credentials and token."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Signed in as")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if group.accounts.isEmpty {
                    Text("No one in this household is signed in to this server yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(group.accounts) { account in
                        accountRow(account)
                    }
                }
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
    private func librariesPanel(_ group: ServerAccountGroup) -> some View {
        SettingsPanel(
            footer: "Toggle off to hide a library's rows on Home without signing the account out."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Libraries on Home")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                librarySection(for: group)
            }
        }
    }

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
}
#endif
