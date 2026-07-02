#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings → This Apple TV → Servers → <Server> detail.
///
/// This screen is **global / household scope** — it manages the server's
/// sign-ins only:
/// - Signed-in accounts (Jellyfin = per-profile creds; Plex = one shared login)
/// - Sign out (removes the token for the whole household)
///
/// Anything *personal* — which Plex user a profile plays as, whether a profile
/// uses this server, and which libraries show on a profile's Home — lives on
/// `<Profile>` › Your Libraries instead, so a personal tweak never reads as
/// household administration.
struct ServerDetailView: View {
    let context: SettingsContext
    let serverKey: String

    /// Account the user has asked to sign out, captured at button-tap so the
    /// confirmation alert can show its name + recompute "is this the last
    /// account?" wording even if the underlying group changes.
    @State private var pendingSignOut: PendingSignOut?

    /// Drives the "Remove Server" confirmation (multi-account servers only).
    @State private var confirmRemoveServer = false

    private struct PendingSignOut: Identifiable {
        let id: String
        let account: Account
        let serverName: String
        let isLastAccount: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let group = currentGroup {
                    header(group)
                    accountsPanel(group)
                    if group.accounts.count > 1 {
                        removeServerPanel(group)
                    }
                } else {
                    // Focusable so Menu/Back can pop back to the Servers list
                    // instead of falling through and quitting the app.
                    VStack(alignment: .leading, spacing: 16) {
                        Text("This server is no longer signed in.")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Button { /* no-op — anchors focus */ } label: {
                            Label("Go back", systemImage: "chevron.backward")
                        }
                    }
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollClipDisabled()
        .alert(item: $pendingSignOut) { pending in
            Alert(
                title: Text("Sign out \(pending.account.userName)?"),
                message: Text(signOutMessage(for: pending)),
                primaryButton: .destructive(Text("Sign Out")) {
                    context.onRemoveAccount(pending.account)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func signOutMessage(for pending: PendingSignOut) -> String {
        let provider = pending.account.server.provider
        let scope = provider == .plex
            ? "This removes the Plex sign-in for \(pending.account.userName) on this Apple TV."
            : "This removes \(pending.account.userName)'s sign-in to \(pending.serverName) on this Apple TV."
        if pending.isLastAccount {
            return scope + " No one else in your household is signed in, so \(pending.serverName) will be removed from your servers until someone signs in again."
        }
        return scope
    }

    private var currentGroup: ServerAccountGroup? {
        serverGroups(from: context.accounts).first { $0.serverKey == serverKey }
    }

    // MARK: - Header

    private func header(_ group: ServerAccountGroup) -> some View {
        HStack(spacing: 16) {
            ProviderIcon(provider: group.providerKind, size: 44)
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

    // MARK: - Accounts

    private func accountsPanel(_ group: ServerAccountGroup) -> some View {
        SettingsPanel(
            footer: group.providerKind == .plex
                ? "Plex shares one sign-in across the household. Each profile picks its own Plex user and libraries under Profile › Your Libraries."
                : "Jellyfin signs in per profile, each with its own credentials. Choose what shows on your Home under Profile › Your Libraries."
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
        let group = currentGroup
        let isLast = (group?.accounts.count ?? 1) <= 1
        let serverName = group?.serverName ?? account.server.name
        return HStack(spacing: 16) {
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
                pendingSignOut = PendingSignOut(
                    id: account.id,
                    account: account,
                    serverName: serverName,
                    isLastAccount: isLast
                )
            } label: {
                Label(isLast ? "Sign Out & Remove Server" : "Sign Out",
                      systemImage: "rectangle.portrait.and.arrow.right")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
            }
            .accessibilityLabel("Sign out \(account.userName) from \(serverName)")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Remove server (household)

    /// A single destructive action for multi-account servers: signs everyone
    /// out at once and drops the server from the Apple TV. (For a single-account
    /// server the per-account "Sign Out & Remove Server" already does this, so
    /// this panel only appears when there's more than one sign-in.)
    private func removeServerPanel(_ group: ServerAccountGroup) -> some View {
        SettingsPanel(
            footer: "Signs out all \(group.accounts.count) accounts and removes \(group.serverName) from this Apple TV for everyone."
        ) {
            Button(role: .destructive) {
                confirmRemoveServer = true
            } label: {
                Label("Remove Server", systemImage: "trash")
                    .font(.callout.weight(.semibold))
            }
            .alert("Remove \(group.serverName)?", isPresented: $confirmRemoveServer) {
                Button("Remove Server", role: .destructive) {
                    for account in group.accounts {
                        context.onRemoveAccount(account)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This signs everyone out of \(group.serverName) on this Apple TV. Any profile will need to sign in again to use it.")
            }
        }
    }
}
#endif
