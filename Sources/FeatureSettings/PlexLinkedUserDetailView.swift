#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings → Plex User picker.
///
/// Lists the Plex Home users reachable from each signed-in Plex account, with
/// the user's real Plex avatar, so the user can change which Plex Home user
/// the active profile plays as. Tapping a row writes the mapping to the
/// active profile via `context.onSelectPlexHomeUser`; PIN-protected users
/// trigger the PIN prompt at the next playback / profile re-apply via the
/// AppState's pending-request flow, which is unchanged.
struct PlexLinkedUserDetailView: View {
    let context: SettingsContext
    let accountID: String

    @State private var users: [PlexHomeUser] = []
    @State private var loading = true

    private var plexAccounts: [Account] {
        context.accounts.filter { $0.server.provider == .plex }
    }

    private var account: Account? {
        plexAccounts.first { $0.id == accountID } ?? plexAccounts.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Plex User").font(.largeTitle.bold())

                if let account {
                    let admin = users.first(where: { $0.isAdmin })
                    let managed = users.filter { !$0.isAdmin }
                    SettingsPanel(
                        title: "On \(account.server.name)",
                        footer: "The account owner is the main Plex account holder; the others are managed/family users under it and may need a PIN. Plozz asks for the PIN on playback and never stores it."
                    ) {
                        VStack(spacing: 0) {
                            ownerRow(admin: admin, account: account)
                            if loading && users.isEmpty {
                                Divider()
                                HStack(spacing: 12) {
                                    ProgressView()
                                    Text("Loading Plex users…")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 16)
                            } else if managed.isEmpty {
                                Divider()
                                Text(users.isEmpty
                                     ? "No Plex Home users found for this account."
                                     : "No managed users on this Plex account.")
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 12)
                            } else {
                                ForEach(managed) { user in
                                    Divider()
                                    userRow(user, account: account)
                                }
                            }
                        }
                    }
                } else {
                    SettingsPanel(title: "No Plex Account") {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Sign in to a Plex account in Server Accounts to pick a Plex Home user.")
                                .foregroundStyle(.secondary)
                            // tvOS: at least one focusable element so Menu pops.
                            Button { /* no-op — anchors focus */ } label: {
                                Label("No Plex account", systemImage: "person.crop.circle.badge.xmark")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .task(id: account?.id) {
            guard let account else { return }
            loading = true
            users = await context.plexHomeUsersFetcher(account.id)
            loading = false
        }
    }

    private var isOwnerSelected: Bool {
        guard let account else { return true }
        return context.activeProfile.homeUserBinding(forPlexAccount: account.id) == nil
    }

    /// The single "play as the account owner" row. Uses the admin Home
    /// user's real name + Plex avatar when available, so this row reads as
    /// the owner themselves — not a generic placeholder above a duplicate
    /// admin entry. Selecting it clears the per-account binding (same as
    /// before: no Home-user switch, admin token, no PIN).
    private func ownerRow(admin: PlexHomeUser?, account: Account) -> some View {
        let displayName = admin?.name ?? "Account owner"
        return Button {
            context.onSelectPlexHomeUser(account.id, nil)
        } label: {
            HStack(spacing: 16) {
                if let admin {
                    avatar(for: admin, size: 52)
                } else {
                    ZStack {
                        Circle().fill(ProviderIcon.tint(.plex).opacity(0.18))
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(ProviderIcon.tint(.plex))
                    }
                    .frame(width: 52, height: 52)
                    .overlay(Circle().strokeBorder(ProviderIcon.tint(.plex).opacity(0.45), lineWidth: 1.5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName).font(.headline)
                        Text("Account owner")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(ProviderIcon.tint(.plex).opacity(0.18)))
                            .foregroundStyle(ProviderIcon.tint(.plex))
                    }
                    Text("Main Plex account holder")
                        .font(.footnote)
                        .settingsRowSecondary()
                }
                Spacer()
                if isOwnerSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .settingsRowGreenIndicator()
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
    }

    private func userRow(_ user: PlexHomeUser, account: Account) -> some View {
        let isSelected = context.activeProfile.homeUserBinding(forPlexAccount: account.id)?.homeUserID == user.id
        return Button {
            context.onSelectPlexHomeUser(account.id, user)
        } label: {
            HStack(spacing: 16) {
                avatar(for: user, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(user.name).font(.headline)
                        if user.isRestricted {
                            Text("Restricted")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.18)))
                                .foregroundStyle(.orange)
                        }
                        if user.requiresPIN {
                            Text("PIN")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.yellow.opacity(0.22)))
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("PIN required")
                        }
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .settingsRowGreenIndicator()
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
    }

    private func avatar(for user: PlexHomeUser, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(ProviderIcon.tint(.plex).opacity(0.18))
            if let url = user.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        Text(String(user.name.prefix(1)).uppercased())
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(ProviderIcon.tint(.plex))
                    }
                }
            } else {
                Text(String(user.name.prefix(1)).uppercased())
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(ProviderIcon.tint(.plex))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ProviderIcon.tint(.plex).opacity(0.45), lineWidth: 1.5))
    }
}
#endif
