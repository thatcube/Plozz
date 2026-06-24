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
                    SettingsPanel(
                        title: "On \(account.server.name)",
                        footer: "Switching the Plex user changes the watch history, On Deck, and library restrictions Plozz uses for this profile. Protected users need a PIN — Plozz asks for it on playback and never stores it."
                    ) {
                        VStack(spacing: 0) {
                            clearRow
                            if loading && users.isEmpty {
                                Divider()
                                HStack(spacing: 12) {
                                    ProgressView()
                                    Text("Loading Plex users…")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 16)
                            } else if users.isEmpty {
                                Divider()
                                Text("No Plex Home users found for this account.")
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 12)
                            } else {
                                ForEach(users) { user in
                                    Divider()
                                    userRow(user, account: account)
                                }
                            }
                        }
                    }
                } else {
                    SettingsPanel(title: "No Plex Account") {
                        Text("Sign in to a Plex account in Server Accounts to pick a Plex Home user.")
                            .foregroundStyle(.secondary)
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

    private var isClearSelected: Bool {
        context.activeProfile.plexHomeUserID == nil
    }

    /// "Use Plex account owner" — clears the Home-user mapping and falls back
    /// to the admin token. Useful when a profile shouldn't be tied to any
    /// Home user.
    private var clearRow: some View {
        Button {
            if let account {
                context.onSelectPlexHomeUser(account.id, nil)
            }
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.10))
                    Image(systemName: "person.crop.circle.dashed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use account owner")
                        .font(.headline)
                    Text("No Home user — play as the signed-in Plex account")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isClearSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func userRow(_ user: PlexHomeUser, account: Account) -> some View {
        let isSelected = context.activeProfile.plexHomeUserID == user.id
            && context.activeProfile.plexHomeUserAccountID == account.id
        return Button {
            context.onSelectPlexHomeUser(account.id, user)
        } label: {
            HStack(spacing: 16) {
                avatar(for: user, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(user.name).font(.headline)
                        if user.isAdmin {
                            Text("Admin")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(ProviderIcon.tint(.plex).opacity(0.18)))
                                .foregroundStyle(ProviderIcon.tint(.plex))
                        }
                        if user.isRestricted {
                            Text("Restricted")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.18)))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(user.requiresPIN ? "PIN required" : "No PIN")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
