#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings → ‹Profile› → **Your Servers & Libraries**.
///
/// The per-profile half of the "mirror model". *This Apple TV › Servers*
/// manages the household's sign-ins (the global inventory); this screen is
/// personal. Every signed-in server appears here in one list, each with a
/// **master on/off toggle** for this profile. When a server is on, its card
/// expands to pick:
///  - **who it is** on that server ("Watching as" — a Plex Home user, or one of
///    the server's Jellyfin sign-ins), and
///  - **which libraries** are on, as checkmark children of the master toggle.
///
/// Nothing here is global: the master toggle is the profile's active-account set
/// (never a household sign-out), identity is a per-profile binding, and library
/// visibility is profile-namespaced. "Sign in to another server" is the only
/// action that touches the household — it adds a brand-new server for everyone.
///
/// (The type + `.myLibraries` route keep their earlier names.)
struct MyLibrariesDetailView: View {
    let context: SettingsContext

    private var allGroups: [ServerAccountGroup] { serverGroups(from: context.accounts) }

    private func isWatching(_ group: ServerAccountGroup) -> Bool {
        group.accounts.contains { context.isAccountIncludedInActiveProfile($0.id) }
    }

    /// The server's master on/off for this profile: on ⇒ watch it (include a
    /// sign-in), off ⇒ stop watching (drop all its sign-ins from the profile).
    /// The server itself is never removed here — that's a household sign-out on
    /// This Apple TV › Servers.
    private func masterBinding(_ group: ServerAccountGroup) -> Binding<Bool> {
        Binding(
            get: { isWatching(group) },
            set: { $0 ? startWatching(group) : stopWatching(group) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsPageHeader(
                    "Your Servers & Libraries",
                    subtitle: "Choose which servers and libraries this profile sees — and who you're signed in as on each."
                )
                if allGroups.isEmpty {
                    emptyInventoryState
                } else {
                    ForEach(allGroups, id: \.serverKey) { serverCard($0) }
                }
                addServerSection
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .task { await context.reloadLibraries() }
    }

    // MARK: - Empty state

    private var emptyInventoryState: some View {
        SettingsPanel(
            footer: "Sign in to a server under This Apple TV › Servers, then choose what you watch here."
        ) {
            Text("No servers yet.").font(.headline)
        }
    }

    // MARK: - Per-server card

    /// One server, toggled on/off for this profile by its header switch. When on,
    /// the card expands to who you watch as + its libraries; when off it collapses
    /// to just the header, staying in the list so nothing reads as "removed".
    private func serverCard(_ group: ServerAccountGroup) -> some View {
        SettingsPanel {
            VStack(alignment: .leading, spacing: 18) {
                // The whole header row is the master toggle: brand + server name on
                // the left, the On/Off switch on the right.
                Toggle(isOn: masterBinding(group)) {
                    HStack(spacing: 16) {
                        ProviderBrandMark(provider: group.providerKind, size: 48, showsBackground: false)
                            .frame(width: 48)
                        Text(group.serverName)
                    }
                }
                .toggleStyle(SettingsSwitchToggleStyle())

                if isWatching(group) {
                    // A media share has no watcher identity, so it skips "Watching
                    // as" (and the divider that would head it) and shows libraries.
                    if group.providerKind != .mediaShare {
                        Divider()
                        watchingAs(group)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Libraries")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        librarySection(for: group)
                    }
                }
            }
        }
    }

    // MARK: - Watching as (identity)

    /// Who this profile is on the server. Shown only while the server is on and
    /// only when it has a watcher identity (Plex Home users / Jellyfin sign-ins) —
    /// the card gates media shares out before calling this.
    @ViewBuilder
    private func watchingAs(_ group: ServerAccountGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Watching as")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if group.providerKind == .plex {
                ForEach(group.accounts) { plexIdentityLink($0) }
            } else {
                jellyfinIdentity(group)
            }
        }
    }

    /// Plex identity = a Home user, chosen on a drill-in screen (distinct from
    /// the single shared sign-in).
    private func plexIdentityLink(_ account: Account) -> some View {
        let binding = context.activeProfile.homeUserBinding(forPlexAccount: account.id)
            ?? ownerBinding(for: account)
        return NavigationLink(value: SettingsRoute.plexUser(accountID: account.id)) {
            HStack(spacing: 14) {
                plexAvatar(for: binding, size: 40)
                Text(identityName(for: binding)).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).settingsRowSecondary()
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
    }

    /// Jellyfin identity IS one of the server's sign-ins. One → shown plainly;
    /// several → pick which single login represents this profile.
    @ViewBuilder
    private func jellyfinIdentity(_ group: ServerAccountGroup) -> some View {
        if group.accounts.count <= 1, let only = group.accounts.first {
            HStack(spacing: 14) {
                AccountAvatar(name: only.userName, imageURL: resolvedAvatarURL(for: only), size: 40)
                Text(only.userName).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
        } else {
            ForEach(group.accounts) { account in
                Button {
                    setJellyfinIdentity(account, in: group)
                } label: {
                    HStack(spacing: 14) {
                        AccountAvatar(name: account.userName, imageURL: resolvedAvatarURL(for: account), size: 40)
                        Text(account.userName).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer()
                        Image(systemName: context.isAccountIncludedInActiveProfile(account.id)
                            ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(context.isAccountIncludedInActiveProfile(account.id) ? .green : .secondary)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsFocusButtonStyle())
            }
        }
    }

    private func setJellyfinIdentity(_ chosen: Account, in group: ServerAccountGroup) {
        for account in group.accounts {
            context.onSetAccountIncluded(account.id, account.id == chosen.id)
        }
    }

    private func stopWatching(_ group: ServerAccountGroup) {
        for account in group.accounts {
            context.onSetAccountIncluded(account.id, false)
        }
    }

    // MARK: - Add a server

    private var addServerSection: some View {
        SettingsPanel(
            footer: "Signing in a new server makes it available to every profile on this Apple TV. Turn servers you're already signed in to on or off above."
        ) {
            Button(action: context.onAddAccount) {
                Label("Sign in to another server", systemImage: "plus.circle")
            }
            .buttonStyle(SettingsFocusButtonStyle())
        }
    }

    private func startWatching(_ group: ServerAccountGroup) {
        // Default to a single identity (the first sign-in); the user can change
        // "Watching as" once the server appears above.
        guard let first = group.accounts.first else { return }
        for account in group.accounts {
            context.onSetAccountIncluded(account.id, account.id == first.id)
        }
    }

    // MARK: - Libraries on Home (per-profile visibility)

    @ViewBuilder
    private func librarySection(for group: ServerAccountGroup) -> some View {
        switch context.discoveredLibraries {
        case .idle, .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("Discovering libraries…").font(.footnote).foregroundStyle(.secondary)
            }
        case .empty:
            Text("No libraries found on this server.").font(.footnote).foregroundStyle(.secondary)
        case .failed:
            HStack {
                Text("Couldn't load libraries.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await context.reloadLibraries() } } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
        case let .loaded(all):
            let libs = libraries(for: group, in: all)
            if libs.isEmpty {
                Text("No libraries found on this server.").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(libs) { aggregated in
                    libraryRow(aggregated)
                }
            }
        }
    }

    /// One library as a **checkmark** child of its server's master toggle: checked
    /// ⇒ on (shown everywhere — Home, Search, Music, browse), unchecked ⇒ hidden
    /// from this profile. Checkmarks (not switches) read as "which of this server's
    /// libraries count," reinforcing the server → libraries hierarchy.
    private func libraryRow(_ aggregated: AggregatedLibrary) -> some View {
        let key = aggregated.key
        let enabled = context.homeVisibility.isEnabled(key)
        return Button {
            context.homeVisibility.setEnabled(!enabled, for: key)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(enabled ? Color.green : Color.secondary)
                Text(aggregated.library.title)
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
        .accessibilityValue(enabled ? "On" : "Off")
    }

    private func libraries(for group: ServerAccountGroup, in all: [AggregatedLibrary]) -> [AggregatedLibrary] {
        let accountIDs = Set(group.accounts.map(\.id))
        return all.filter { accountIDs.contains($0.accountID) }
    }

    // MARK: - Plex identity display helpers

    private func ownerBinding(for account: Account) -> PlexHomeUserBinding? {
        let name = account.userName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return PlexHomeUserBinding(
            homeUserID: "",
            name: name,
            avatarURL: account.avatarURL?.absoluteString,
            requiresPIN: false
        )
    }

    private func plexAvatar(for binding: PlexHomeUserBinding?, size: CGFloat) -> some View {
        let url = binding?.avatarURL.flatMap(URL.init(string:))
        return ZStack {
            Circle().fill(ProviderIcon.tint(.plex).opacity(0.18))
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image): image.resizable().scaledToFill()
                    default: ProviderIcon(provider: .plex, size: size * 0.55)
                    }
                }
            } else {
                ProviderIcon(provider: .plex, size: size * 0.55)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ProviderIcon.tint(.plex).opacity(0.45), lineWidth: 1.5))
    }

    private func identityName(for binding: PlexHomeUserBinding?) -> String {
        guard let binding, !binding.name.isEmpty else { return "Choose Plex user" }
        return binding.requiresPIN == true ? "\(binding.name) • PIN" : binding.name
    }
}
#endif
