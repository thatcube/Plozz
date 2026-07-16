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

    /// Bumped on every server/identity mutation so the pushed view re-renders
    /// immediately and re-reads live state through `context`'s closures. This is
    /// what makes the master switch move the instant it's pressed: the settings
    /// screen is a cached navigation destination, so it does NOT otherwise re-run
    /// its body when `AppState.activeAccountIDs` changes underneath it. Reading a
    /// snapshot value here (a copied `Set`) went stale for the same reason — hence
    /// a local revision counter driving live re-reads instead.
    @State private var revision = 0

    private var allGroups: [ServerAccountGroup] { serverGroups(from: context.accounts) }

    private func isWatching(_ group: ServerAccountGroup) -> Bool {
        group.accounts.contains { context.isAccountIncludedInActiveProfile($0.id) }
    }

    /// The server's master on/off for this profile: on ⇒ watch it (include a
    /// sign-in), off ⇒ stop watching (drop all its sign-ins from the profile).
    /// The server itself is never removed here — that's a household sign-out on
    /// This Apple TV › Servers.
    private func toggleWatching(_ group: ServerAccountGroup) {
        let was = isWatching(group)
        was ? stopWatching(group) : startWatching(group)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    SettingsPageHeader(
                        "Your Servers & Libraries",
                        subtitle: "Turn servers and libraries on or off, and pick who you watch as."
                    )
                    if allGroups.isEmpty {
                        emptyInventoryState
                    } else {
                        ForEach(allGroups, id: \.serverKey) {
                            serverCard($0, scrollProxy: scrollProxy)
                        }
                    }
                    addServerSection
                }
                .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
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
    private func serverCard(
        _ group: ServerAccountGroup,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        // `rowContentPadding` + `flushLeading: false` rows make every focus card
        // inside nest concentrically with this panel's border.
        SettingsPanel(contentPadding: .settingsPanelRowContent) {
            VStack(alignment: .leading, spacing: 18) {
                // The whole header row is the master switch: brand + server name
                // on the left, the On/Off switch on the right. A Button (not a
                // Toggle) so the tvOS press reliably fires the side-effectful
                // watch/unwatch action.
                SettingsSwitchButton(
                    isOn: isWatching(group),
                    flushLeading: false,
                    action: {
                        toggleWatching(group)
                        keepServerHeaderVisible(group, using: scrollProxy)
                    }
                ) {
                    HStack(spacing: 16) {
                        ProviderBrandMark(provider: group.providerKind, size: 48, mediaShareTransport: group.transportKind)
                            .frame(width: 48)
                        Text(group.serverName)
                    }
                }
                .id(serverHeaderID(group))

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

    private func serverHeaderID(_ group: ServerAccountGroup) -> String {
        "server-header:\(group.serverKey)"
    }

    private func keepServerHeaderVisible(
        _ group: ServerAccountGroup,
        using scrollProxy: ScrollViewProxy
    ) {
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                scrollProxy.scrollTo(serverHeaderID(group), anchor: .center)
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

    /// Trailing accessory for a "Watching as" selector row.
    private enum IdentityAccessory {
        /// Jellyfin single-select: green check when this sign-in is the chosen one.
        case selected(Bool)
        /// Plex drill-in to the Home-user picker.
        case chevron
        /// Informational only (a lone Jellyfin sign-in — nothing to choose).
        case none
    }

    /// Shared chrome for a "Watching as" selector row so it's the SAME height as a
    /// secondary library checkmark (via ``SettingsRowMetrics``) and focuses
    /// concentrically inside the card. Leading avatar + name + trailing accessory.
    private func identityRow<Avatar: View>(
        title: String,
        @ViewBuilder avatar: () -> Avatar,
        accessory: IdentityAccessory
    ) -> some View {
        HStack(spacing: SettingsRowMetrics.spacing(.secondary)) {
            avatar()
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            Spacer(minLength: SettingsRowMetrics.spacing(.secondary))
            switch accessory {
            case let .selected(on):
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? .green : .secondary)
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .settingsRowSecondary()
            case .none:
                EmptyView()
            }
        }
        .frame(minHeight: SettingsRowMetrics.minHeight(.secondary))
        .padding(.vertical, SettingsRowMetrics.verticalPadding(.secondary))
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .contentShape(Rectangle())
    }

    /// Plex identity = a Home user, chosen on a drill-in screen (distinct from
    /// the single shared sign-in).
    private func plexIdentityLink(_ account: Account) -> some View {
        let binding = context.activeProfile.homeUserBinding(forPlexAccount: account.id)
            ?? ownerBinding(for: account)
        return NavigationLink(value: SettingsRoute.plexUser(accountID: account.id)) {
            identityRow(
                title: identityName(for: binding),
                avatar: { plexAvatar(for: binding, size: 34) },
                accessory: .chevron
            )
        }
        .buttonStyle(SettingsFocusButtonStyle())
    }

    /// Jellyfin identity IS one of the server's sign-ins. One → shown plainly;
    /// several → pick which single login represents this profile.
    @ViewBuilder
    private func jellyfinIdentity(_ group: ServerAccountGroup) -> some View {
        if group.accounts.count <= 1, let only = group.accounts.first {
            identityRow(
                title: only.userName,
                avatar: { AccountAvatar(name: only.userName, imageURL: resolvedAvatarURL(for: only), size: 34) },
                accessory: .none
            )
        } else {
            ForEach(group.accounts) { account in
                Button {
                    setJellyfinIdentity(account, in: group)
                } label: {
                    identityRow(
                        title: account.userName,
                        avatar: { AccountAvatar(name: account.userName, imageURL: resolvedAvatarURL(for: account), size: 34) },
                        accessory: .selected(context.isAccountIncludedInActiveProfile(account.id))
                    )
                }
                .buttonStyle(SettingsFocusButtonStyle())
            }
        }
    }

    private func setJellyfinIdentity(_ chosen: Account, in group: ServerAccountGroup) {
        for account in group.accounts {
            context.onSetAccountIncluded(account.id, account.id == chosen.id)
        }
        revision += 1
    }

    private func stopWatching(_ group: ServerAccountGroup) {
        for account in group.accounts {
            context.onSetAccountIncluded(account.id, false)
        }
        revision += 1
    }

    // MARK: - Add a server

    /// Adding a server is a device-wide action (it affects every profile), so it
    /// lives canonically on This Apple TV › Servers; this mirror of it is styled
    /// identically to that page's "Add Server" row and says "this Apple TV" to
    /// make the device scope obvious next to the per-profile toggles above.
    private var addServerSection: some View {
        SettingsPanel {
            Button(action: context.onAddAccount) {
                Label("Add Server to This Apple TV", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
        }
    }

    private func startWatching(_ group: ServerAccountGroup) {
        // Default to a single identity (the first sign-in); the user can change
        // "Watching as" once the server appears above.
        guard let first = group.accounts.first else { return }
        for account in group.accounts {
            context.onSetAccountIncluded(account.id, account.id == first.id)
        }
        revision += 1
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
                if isRefreshingLibraries(for: group) {
                    discoveringLibraries
                } else {
                    Text("No libraries found on this server.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                // The shared multi-select checklist (same `SettingsCheckableRow` +
                // trailing checkmark as Customize Home / Theme / Display Size), so
                // libraries read as consistent checkmark children of the master
                // toggle — no one-off control. `bordered: false`: it already sits
                // inside the server card under the "Libraries" caption.
                SettingsCheckList(
                    options: libs,
                    title: { $0.library.title },
                    bordered: false,
                    flushLeading: false,
                    isChecked: { context.homeVisibility.isEnabled($0.key) },
                    onToggle: { lib in
                        context.homeVisibility.setEnabled(!context.homeVisibility.isEnabled(lib.key), for: lib.key)
                    }
                )
            }
        }
    }

    private var discoveringLibraries: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Discovering libraries…").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func isRefreshingLibraries(for group: ServerAccountGroup) -> Bool {
        group.accounts.contains {
            context.refreshingLibraryAccountIDs.contains($0.id)
        }
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
