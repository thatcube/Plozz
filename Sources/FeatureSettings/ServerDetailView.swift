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
    @Environment(\.dismiss) private var dismiss

    /// Account the user has asked to sign out, captured at button-tap so the
    /// confirmation alert can show its name + recompute "is this the last
    /// account?" wording even if the underlying group changes.
    @State private var pendingSignOut: PendingSignOut?

    /// Drives the "Remove Server" confirmation (multi-account servers only).
    @State private var confirmRemoveServer = false

    /// Drives the second "remove from all devices?" confirmation for the household
    /// tombstone, captured so its accounts + name survive the first sheet dismissing.
    @State private var everywhereRemoval: EverywhereRemoval?

    private struct EverywhereRemoval: Identifiable {
        let id = UUID()
        let serverName: String
        let accounts: [Account]
    }

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
                        .tvOSFocusSection()
                    if group.providerKind == .mediaShare {
                        shareLibraryPanel(group)
                            .tvOSFocusSection()
                    }
                    if group.accounts.count > 1 {
                        removeServerPanel(group)
                            .tvOSFocusSection()
                    }
                } else {
                    // Safety net if the group vanishes while viewing (e.g. a remote
                    // "Remove Everywhere" landed): offer a working way back.
                    VStack(alignment: .leading, spacing: 16) {
                        Text("This server is no longer signed in.")
                            .font(.headline)
                            .plozzForeground(.secondary)
                        Button { dismiss() } label: {
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
        .alert(
            pendingSignOutTitle(pendingSignOut),
            isPresented: Binding(
                get: { pendingSignOut != nil },
                set: { if !$0 { pendingSignOut = nil } }
            ),
            presenting: pendingSignOut
        ) { pending in
            if context.offersRemoveEverywhere {
                Button("Remove Everywhere", role: .destructive) {
                    everywhereRemoval = EverywhereRemoval(
                        serverName: pending.serverName, accounts: [pending.account])
                }
                Button("Remove from This Apple TV", role: .destructive) {
                    context.onRemoveAccount(pending.account)
                    if pending.isLastAccount { dismiss() }
                }
            } else {
                Button(signOutPrimaryLabel(pending), role: .destructive) {
                    context.onRemoveAccount(pending.account)
                    if pending.isLastAccount { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(context.offersRemoveEverywhere
                 ? "Remove it from all your devices, or just this Apple TV?"
                 : signOutMessage(for: pending))
        }
        .alert(item: $everywhereRemoval) { removal in
            Alert(
                title: Text("Remove from all devices?"),
                message: Text("“\(removal.serverName)” will also be removed from your other devices signed in to iCloud."),
                primaryButton: .destructive(Text("Remove Everywhere")) {
                    for account in removal.accounts { context.onRemoveAccountEverywhere(account) }
                    dismiss()   // the server is gone → return to the Servers list
                },
                secondaryButton: .cancel()
            )
        }
    }

    /// Title for the sign-out/remove confirmation, derived from the pending account.
    private func pendingSignOutTitle(_ pending: PendingSignOut?) -> LocalizedStringResource {
        guard let pending else { return "" }
        let transport = MediaShareTransportKind(mediaShareScheme: pending.account.server.baseURL.scheme)
        let isCredentialFree = transport == .nfs
        let trimmedUser = pending.account.userName.trimmingCharacters(in: .whitespaces)
        if isCredentialFree || trimmedUser.isEmpty { return "Remove \(pending.serverName)?" }
        return "Sign out \(trimmedUser)?"
    }

    /// Primary button label when sync is off (a credential-free share reads "Remove").
    private func signOutPrimaryLabel(_ pending: PendingSignOut) -> LocalizedStringResource {
        let transport = MediaShareTransportKind(mediaShareScheme: pending.account.server.baseURL.scheme)
        return transport == .nfs ? "Remove" : "Sign Out"
    }

    /// The sign-out confirmation body.
    ///
    /// Composed as whole sentences rather than a scope string plus an appended
    /// clause: concatenating two halves fixes English word order, and the joined
    /// result is an expression the extractor never sees. Each branch is therefore
    /// its own complete, translatable sentence.
    private func signOutMessage(for pending: PendingSignOut) -> LocalizedStringResource {
        let provider = pending.account.server.provider
        let transport = MediaShareTransportKind(mediaShareScheme: pending.account.server.baseURL.scheme)
        let trimmedUser = pending.account.userName.trimmingCharacters(in: .whitespaces)
        let server = pending.serverName
        let isLast = pending.isLastAccount && transport != .nfs

        if transport == .nfs {
            return "This removes the connection to \(server) on this Apple TV."
        }
        if provider == .plex {
            return isLast
                ? "This removes the Plex sign-in for \(trimmedUser) on this Apple TV. No one else in your household is signed in, so \(server) will be removed from your servers until someone signs in again."
                : "This removes the Plex sign-in for \(trimmedUser) on this Apple TV."
        }
        if trimmedUser.isEmpty {
            return isLast
                ? "This removes the guest connection to \(server) on this Apple TV. No one else in your household is signed in, so \(server) will be removed from your servers until someone signs in again."
                : "This removes the guest connection to \(server) on this Apple TV."
        }
        return isLast
            ? "This removes \(trimmedUser)'s sign-in to \(server) on this Apple TV. No one else in your household is signed in, so \(server) will be removed from your servers until someone signs in again."
            : "This removes \(trimmedUser)'s sign-in to \(server) on this Apple TV."
    }

    private var currentGroup: ServerAccountGroup? {
        serverGroups(from: context.accounts).first { $0.serverKey == serverKey }
    }

    /// Provider-appropriate explanation of how sign-in works for this server.
    private func accountsFooter(for provider: ProviderKind, transport: MediaShareTransportKind?) -> LocalizedStringResource {
        switch provider {
        case .plex:
            return "Plex shares one sign-in across the household. Each profile picks its own Plex user and libraries under Profile › Your Libraries."
        case .jellyfin:
            return "Jellyfin signs in per profile, each with its own credentials. Choose what shows on your Home under Profile › Your Libraries."
        case .emby:
            return "Emby signs in per profile, each with its own credentials. Choose what shows on your Home under Profile › Your Libraries."
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
                Text(verbatim: group.serverName).font(.largeTitle.bold())
                headerSubtitle(for: group)
                    .font(.subheadline)
                    .plozzForeground(.secondary)
            }
            Spacer()
        }
    }

    /// Names what kind of server this is. A file share reads as its transport
    /// (e.g. "WebDAV share") so it's unmistakable; other providers use their
    /// brand name.
    private func headerSubtitle(for group: ServerAccountGroup) -> Text {
        if let transport = group.transportKind {
            return Text("\(transport.badgeLabel) share")
        }
        // Provider names are brands — never translated.
        return Text(verbatim: group.providerKind.displayName)
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
                    .plozzForeground(.secondary)
                if group.accounts.isEmpty {
                    Text(isCredentialFree
                         ? "This share isn’t connected yet."
                         : "No one in this household is signed in to this server yet.")
                        .font(.footnote)
                        .plozzForeground(.secondary)
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
                    .plozzForeground(.secondary)
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
    private func removeButtonTitle(isCredentialFree: Bool, isLast: Bool) -> LocalizedStringResource {
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
                if context.offersRemoveEverywhere {
                    Button("Remove Everywhere", role: .destructive) {
                        everywhereRemoval = EverywhereRemoval(
                            serverName: group.serverName, accounts: group.accounts)
                    }
                    Button("Remove from This Apple TV", role: .destructive) {
                        for account in group.accounts { context.onRemoveAccount(account) }
                        dismiss()   // server gone → back to the Servers list
                    }
                } else {
                    Button("Remove Server", role: .destructive) {
                        for account in group.accounts { context.onRemoveAccount(account) }
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(context.offersRemoveEverywhere
                     ? "Remove it from all your devices, or just this Apple TV?"
                     : "This signs everyone out of \(group.serverName) on this Apple TV. Any profile will need to sign in again to use it.")
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
                    .plozzForeground(.secondary)
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
                            .plozzForeground(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .plozzForeground(.secondary)
                        Text(Self.lastScannedText(state?.lastScanAt))
                            .plozzForeground(.secondary)
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

    private static func busyStatusText(_ state: ShareScanState) -> LocalizedStringResource {
        let phase = state.isScanning ? "Scanning" : "Finding artwork & details"
        if let detail = state.progressDetail { return "\(phase) · \(detail)" }
        return "\(phase)…"
    }

    private static func lastScannedText(_ date: Date?) -> LocalizedStringResource {
        guard let date else { return "Not scanned yet" }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "Last scanned just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // Interpolated, not concatenated: the relative phrase has to be able to
        // move within the sentence, and `+` produces an expression the extractor
        // cannot see at all.
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return "Last scanned \(relative)"
    }
}
#endif
