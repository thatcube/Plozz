#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings → ‹Profile› → **Your Libraries**.
///
/// The per-profile half of the "mirror model". *This Apple TV › Servers*
/// manages the household's sign-ins (the global inventory); this screen is
/// personal. For each server THIS profile watches, it picks:
///  - **who it is** on that server ("Watching as" — a Plex Home user, or one of
///    the server's Jellyfin sign-ins), and
///  - **which libraries** appear on its Home.
///
/// It shows only the profile's *subset* of the inventory — "Add a server" pulls
/// in the ones it isn't watching yet. Nothing here is global: identity is a
/// per-profile binding, "watching / not watching" is the profile's
/// active-account set, and library visibility is profile-namespaced.
///
/// (The type + `.myLibraries` route keep their earlier names; the user-facing
/// name is "Your Libraries".)
struct MyLibrariesDetailView: View {
    let context: SettingsContext

    private var allGroups: [ServerAccountGroup] { serverGroups(from: context.accounts) }
    private var watchedGroups: [ServerAccountGroup] { allGroups.filter(isWatching) }
    private var availableGroups: [ServerAccountGroup] { allGroups.filter { !isWatching($0) } }

    private func isWatching(_ group: ServerAccountGroup) -> Bool {
        group.accounts.contains { context.isAccountIncludedInActiveProfile($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Who you watch as, and what shows on \(context.activeProfile.name)'s Home. Only this profile is affected.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if allGroups.isEmpty {
                    emptyInventoryState
                } else {
                    if watchedGroups.isEmpty {
                        notWatchingState
                    } else {
                        ForEach(watchedGroups, id: \.serverKey) { serverCard($0) }
                    }
                    addServerSection
                }
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .task { await context.reloadLibraries() }
    }

    // MARK: - Empty states

    private var emptyInventoryState: some View {
        SettingsPanel(
            footer: "Sign in to a server under This Apple TV › Servers, then choose what you watch here."
        ) {
            Text("No servers yet.").font(.headline)
        }
    }

    private var notWatchingState: some View {
        SettingsPanel(
            footer: "You're signed in to servers, but this profile isn't watching any yet. Add one below."
        ) {
            Text("Not watching any servers.").font(.headline)
        }
    }

    // MARK: - Per-server card

    private func serverCard(_ group: ServerAccountGroup) -> some View {
        SettingsPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ProviderIcon(provider: group.providerKind, size: 40).frame(width: 30)
                    Text(group.serverName).font(.title3.weight(.semibold))
                    Spacer()
                }

                watchingAs(group)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Libraries")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    librarySection(for: group)
                }

                Divider()

                Button(role: .destructive) {
                    stopWatching(group)
                } label: {
                    Label("Stop watching on this profile", systemImage: "minus.circle")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(SettingsFocusButtonStyle())
            }
        }
    }

    // MARK: - Watching as (identity)

    @ViewBuilder
    private func watchingAs(_ group: ServerAccountGroup) -> some View {
        // A media share has no watcher identity (no per-user login / Home users),
        // so the "Watching as" row would show a meaningless "guest" avatar. Skip it.
        if group.providerKind != .mediaShare {
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
            footer: "Add a server this profile isn't watching yet. Signing in a brand-new server makes it available to every profile."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a server")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(availableGroups, id: \.serverKey) { group in
                    Button {
                        startWatching(group)
                    } label: {
                        HStack(spacing: 14) {
                            ProviderIcon(provider: group.providerKind, size: 36).frame(width: 28)
                            Text(group.serverName).font(.callout.weight(.medium))
                            Spacer()
                            Label("Add", systemImage: "plus.circle").labelStyle(.titleAndIcon)
                        }
                        .padding(.vertical, 8).padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsFocusButtonStyle())
                }
                Button(action: context.onAddAccount) {
                    Label("Sign in to another server", systemImage: "plus.circle")
                }
                .buttonStyle(SettingsFocusButtonStyle())
            }
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

    /// One library's whole-library **Enabled** switch (off ⇒ hidden everywhere:
    /// Home, Search, Music, browse). A short caption explains what "on" means,
    /// differing for music (Music tab) vs video (Home & Search). Which *rows* a
    /// video library contributes to Home is chosen separately on Customize Home.
    @ViewBuilder
    private func libraryRow(_ aggregated: AggregatedLibrary) -> some View {
        let key = aggregated.key
        let isMusic = aggregated.library.isMusic
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { context.homeVisibility.isEnabled(key) },
                set: { context.homeVisibility.setEnabled($0, for: key) }
            )) {
                Text(aggregated.library.title)
            }
            .toggleStyle(SettingsSwitchToggleStyle())

            captionText(enabled: context.homeVisibility.isEnabled(key), isMusic: isMusic)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .padding(.bottom, 6)
        }
    }

    private func captionText(enabled: Bool, isMusic: Bool) -> Text {
        if !enabled {
            return Text(isMusic
                        ? "Hidden everywhere, including the Music tab."
                        : "Hidden everywhere, including Search.")
        }
        return Text(isMusic
                    ? "Shown in the Music tab."
                    : "Available in Search and eligible for Home. Choose its Home rows in Customize Home.")
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
