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
                    // Each panel is its own focus section so directional (up/down)
                    // navigation bridges them even when their focusable controls are
                    // horizontally offset — e.g. the left-aligned "Scan now" button
                    // and the right-aligned "Sign Out & Remove Server" button, which
                    // tvOS otherwise can't connect (a diagonal move it won't make).
                    accountsPanel(group)
                        .focusSection()
                    if group.providerKind == .mediaShare {
                        shareLibraryPanel(group)
                            .focusSection()
                    }
                    if group.accounts.count > 1 {
                        removeServerPanel(group)
                            .focusSection()
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
            let transport = MediaShareTransportKind(mediaShareScheme: pending.account.server.baseURL.scheme)
            let isCredentialFree = transport == .nfs
            let trimmedUser = pending.account.userName.trimmingCharacters(in: .whitespaces)
            return Alert(
                title: Text(isCredentialFree
                    ? "Remove \(pending.serverName)?"
                    : (trimmedUser.isEmpty ? "Remove \(pending.serverName)?" : "Sign out \(trimmedUser)?")),
                message: Text(signOutMessage(for: pending)),
                primaryButton: .destructive(Text(isCredentialFree ? "Remove" : "Sign Out")) {
                    context.onRemoveAccount(pending.account)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func signOutMessage(for pending: PendingSignOut) -> String {
        let provider = pending.account.server.provider
        let transport = MediaShareTransportKind(mediaShareScheme: pending.account.server.baseURL.scheme)
        let trimmedUser = pending.account.userName.trimmingCharacters(in: .whitespaces)
        let scope: String
        if transport == .nfs {
            scope = "This removes the connection to \(pending.serverName) on this Apple TV."
        } else if provider == .plex {
            scope = "This removes the Plex sign-in for \(trimmedUser) on this Apple TV."
        } else if trimmedUser.isEmpty {
            scope = "This removes the guest connection to \(pending.serverName) on this Apple TV."
        } else {
            scope = "This removes \(trimmedUser)'s sign-in to \(pending.serverName) on this Apple TV."
        }
        if pending.isLastAccount, transport != .nfs {
            return scope + " No one else in your household is signed in, so \(pending.serverName) will be removed from your servers until someone signs in again."
        }
        return scope
    }

    private var currentGroup: ServerAccountGroup? {
        serverGroups(from: context.accounts).first { $0.serverKey == serverKey }
    }

    /// Provider-appropriate explanation of how sign-in works for this server.
    private func accountsFooter(for provider: ProviderKind, transport: MediaShareTransportKind?) -> String {
        switch provider {
        case .plex:
            return "Plex shares one sign-in across the household. Each profile picks its own Plex user and libraries under Profile › Your Libraries."
        case .jellyfin:
            return "Jellyfin signs in per profile, each with its own credentials. Choose what shows on your Home under Profile › Your Libraries."
        case .mediaShare:
            if transport == .nfs {
                return "This NFS export connects without a sign-in — anyone on this Apple TV can browse it. Choose what shows on your Home under Profile › Your Libraries."
            }
            return "A media share connects with the credentials you entered (or as a guest). Choose what shows on your Home under Profile › Your Libraries."
        }
    }

    // MARK: - Header

    private func header(_ group: ServerAccountGroup) -> some View {
        HStack(spacing: 16) {
            ProviderIcon(provider: group.providerKind, size: 44, mediaShareTransport: group.transportKind)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.serverName).font(.largeTitle.bold())
                Text(headerSubtitle(for: group))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Names what kind of server this is. A file share reads as its transport
    /// (e.g. "WebDAV share") so it's unmistakable; other providers use their
    /// brand name.
    private func headerSubtitle(for group: ServerAccountGroup) -> String {
        if let transport = group.transportKind {
            return "\(transport.badgeLabel) share"
        }
        return group.providerKind.displayName
    }

    // MARK: - Media-share library status

    /// For a media share: last-scanned time / live scan status + a "Scan now"
    /// control. A share has no server to index it, so the library is built by an
    /// on-device scan — surfacing its status makes that legible.
    private func shareLibraryPanel(_ group: ServerAccountGroup) -> some View {
        ShareLibraryStatusPanel(
            account: group.accounts.first,
            onRescanShare: context.onRescanShare
        )
    }

    // MARK: - Accounts

    private func accountsPanel(_ group: ServerAccountGroup) -> some View {
        let isCredentialFree = group.transportKind == .nfs
        return SettingsPanel(
            footer: accountsFooter(for: group.providerKind, transport: group.transportKind)
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text(isCredentialFree ? "Connection" : "Signed in as")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if group.accounts.isEmpty {
                    Text(isCredentialFree
                         ? "This share isn’t connected yet."
                         : "No one in this household is signed in to this server yet.")
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
        let isCredentialFree = group?.transportKind == .nfs
        let trimmedUser = account.userName.trimmingCharacters(in: .whitespaces)
        let displayName = trimmedUser.isEmpty
            ? (isCredentialFree ? "No sign-in required" : "Guest")
            : trimmedUser
        return HStack(spacing: 16) {
            AccountAvatar(name: trimmedUser.isEmpty ? "?" : trimmedUser, imageURL: resolvedAvatarURL(for: account), size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName).font(.headline)
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
                Label(removeButtonTitle(isCredentialFree: isCredentialFree, isLast: isLast),
                      systemImage: isCredentialFree ? "trash" : "rectangle.portrait.and.arrow.right")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
            }
            .accessibilityLabel(isCredentialFree
                ? "Remove \(serverName)"
                : "Sign out \(displayName) from \(serverName)")
        }
        .padding(.vertical, 2)
    }

    /// The destructive-button title. A credential-free share (NFS) isn't a
    /// sign-in, so it reads as "Remove Server" rather than "Sign Out".
    private func removeButtonTitle(isCredentialFree: Bool, isLast: Bool) -> String {
        if isCredentialFree { return "Remove Server" }
        return isLast ? "Sign Out & Remove Server" : "Sign Out"
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

/// Isolates high-frequency scan progress observation from the server detail's
/// confirmation state and focus tree.
private struct ShareLibraryStatusPanel: View {
    let account: Account?
    let onRescanShare: (String) -> Void

    @Environment(ShareScanStatusModel.self) private var shareScanStatus:
        ShareScanStatusModel?

    private var state: ShareScanState? {
        account.flatMap { shareScanStatus?.state(forShareID: $0.id) }
    }

    var body: some View {
        SettingsPanel(
            footer: "Your share's library is built on this Apple TV by scanning it while the app is open. New files appear after the next scan."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Library")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if let state, state.isBusy {
                        if let fraction = state.enrichFraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        } else {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        }
                        Text(Self.busyStatusText(state))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.secondary)
                        Text(Self.lastScannedText(state?.lastScanAt))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .font(.footnote)

                if let account {
                    Button {
                        onRescanShare(account.id)
                    } label: {
                        Label("Scan now", systemImage: "arrow.clockwise")
                    }
                    .disabled(state?.isBusy == true)
                }
            }
        }
    }

    private static func busyStatusText(_ state: ShareScanState) -> String {
        let phase = state.isScanning ? "Scanning" : "Finding artwork & details"
        if let detail = state.progressDetail { return "\(phase) · \(detail)" }
        return "\(phase)…"
    }

    private static func lastScannedText(_ date: Date?) -> String {
        guard let date else { return "Not scanned yet" }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "Last scanned just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last scanned " + formatter.localizedString(
            for: date,
            relativeTo: Date()
        )
    }
}
#endif
