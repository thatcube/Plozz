#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureSyncSetup
import SwiftUI

struct PlozziOSServersSettingsView: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    @State private var selectedServerKey: String?

    private var groups: [ServerAccountGroup] {
        serverGroups(from: appModel.accounts)
    }

    var body: some View {
        SettingsPageList {
            SettingsSectionGroup("Servers") {
                if groups.isEmpty {
                    Text("You’re not signed in to any servers yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groups, id: \.serverKey) { group in
                        // A plain Button (not NavigationLink) because SettingsSectionGroup
                        // re-emits its children through Group(subviews:), which renders
                        // every NavigationLink destination eagerly (tap any → opens the
                        // last) and breaks value links. A Button just sets state, and
                        // navigationDestination(item:) pushes exactly the tapped one.
                        Button {
                            selectedServerKey = group.serverKey
                        } label: {
                            serverRowLabel(group)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                Text("Sign-ins and network shares are available to every profile on this \(deviceName).")
            }

            SettingsSectionGroup {
                Button("Add Server", systemImage: "plus", action: onAddServer)
                NavigationLink {
                    PlozziOSAddShareView(appModel: appModel)
                } label: {
                    HStack(spacing: 12) {
                        ProviderBrandMark(
                            provider: .mediaShare,
                            size: 24
                        )
                        Text("Add Network Share")
                    }
                }
            }
        }
        .navigationTitle("Servers")
        .navigationDestination(item: $selectedServerKey) { key in
            PlozziOSServerSettingsDetailView(appModel: appModel, serverKey: key)
        }
    }

    @ViewBuilder
    private func serverRowLabel(_ group: ServerAccountGroup) -> some View {
        HStack(spacing: 12) {
            ProviderBrandMark(
                provider: group.providerKind,
                size: 32,
                mediaShareTransport: group.transportKind
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(group.serverName)
                if let summary = summary(for: group) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func summary(for group: ServerAccountGroup) -> String? {
        if group.accounts.count > 1 {
            return "\(group.accounts.count) sign-ins"
        }
        guard let account = group.accounts.first else { return nil }
        let user = account.userName.trimmingCharacters(in: .whitespaces)
        if user.isEmpty {
            return group.transportKind == .nfs ? nil : "Guest access"
        }
        return "Signed in as \(user)"
    }

}

private struct PlozziOSServerSettingsDetailView: View {
    let appModel: PlozziOSAppModel
    let serverKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoveServer = false
    @State private var confirmRemoveEverywhere = false
    @State private var selectedAccountID: String?

    private var group: ServerAccountGroup? {
        serverGroups(from: appModel.accounts).first {
            $0.serverKey == serverKey
        }
    }

    var body: some View {
        SettingsPageList {
            if let group {
                SettingsSectionGroup("Signed in as") {
                    ForEach(group.accounts) { account in
                        Button {
                            selectedAccountID = account.id
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.userName.isEmpty ? "Guest" : account.userName)
                                    Text(account.server.baseURL.host() ?? account.server.baseURL.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Removing a sign-in affects every profile on this \(deviceName).")
                }

                if group.accounts.count > 1 {
                    SettingsSectionGroup {
                        Button("Remove Server", role: .destructive) {
                            confirmRemoveServer = true
                        }
                    } footer: {
                        Text("Signs out every account on \(group.serverName).")
                    }
                }
            } else {
                ContentUnavailableView(
                    "Server Removed",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("This server is no longer available.")
                )
            }
        }
        .navigationTitle(group?.serverName ?? "Server")
        // When the server is gone (removed here, or the last sign-in removed on the
        // pushed account detail, or a remote "Remove Everywhere" landed), pop back to
        // the Servers list instead of stranding the user on an empty detail.
        .onChange(of: group == nil) { _, gone in
            if gone { dismiss() }
        }
        .navigationDestination(item: $selectedAccountID) { accountID in
            if let account = appModel.accounts.first(where: { $0.id == accountID }) {
                PlozziOSAccountDetailView(
                    appModel: appModel,
                    account: account
                )
            }
        }
        .confirmationDialog(
            "Remove \(group?.serverName ?? "server")?",
            isPresented: $confirmRemoveServer,
            titleVisibility: .visible
        ) {
            if appModel.offersRemoveEverywhere {
                Button("Remove Everywhere", role: .destructive) { confirmRemoveEverywhere = true }
                Button("Remove from This \(deviceName)", role: .destructive) {
                    for account in group?.accounts ?? [] {
                        appModel.removeAccount(id: account.id)
                    }
                }
            } else {
                Button("Remove Server", role: .destructive) {
                    for account in group?.accounts ?? [] {
                        appModel.removeAccount(id: account.id)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(appModel.offersRemoveEverywhere
                 ? "Remove it from all your devices, or just this \(deviceName)?"
                 : "Signs everyone out and removes this server.")
        }
        .alert("Remove from all devices?", isPresented: $confirmRemoveEverywhere) {
            Button("Remove Everywhere", role: .destructive) {
                for account in group?.accounts ?? [] {
                    appModel.removeAccountEverywhere(id: account.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(group?.serverName ?? "This server")” will also be removed from your other devices signed in to iCloud.")
        }
    }
}

struct PlozziOSMyLibrariesSettingsView: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    @State private var libraries: [ProfileLibraryChoice] = []
    @State private var unreachableAccountIDs: Set<String> = []
    @State private var isLoading = false

    private var groups: [ServerAccountGroup] {
        serverGroups(from: appModel.accounts)
    }

    private var profileID: String {
        appModel.profiles.activeProfileID
    }

    var body: some View {
        SettingsPageList {
            if groups.isEmpty {
                SettingsSectionGroup {
                    Text("No servers are available on this \(deviceName).")
                        .foregroundStyle(.secondary)
                    Button("Add Server", systemImage: "plus", action: onAddServer)
                }
            } else {
                ForEach(groups, id: \.serverKey) { group in
                    serverGroup(group)
                }
            }
        }
        .navigationTitle(SettingsCopy.libraries)
        .task(id: appModel.accounts.map(\.credentialRevision)) {
            await loadLibraries()
        }
    }

    @ViewBuilder
    private func serverGroup(_ group: ServerAccountGroup) -> some View {
        SettingsSectionGroup {
            // The whole row is the master switch: provider brand + server name on
            // the left, the On/Off switch on the right — matching tvOS, where the
            // server's icon and name *are* the toggle.
            Toggle(
                isOn: Binding(
                    get: { isWatching(group) },
                    set: { setWatching($0, group: group) }
                )
            ) {
                HStack(spacing: 12) {
                    ProviderBrandMark(
                        provider: group.providerKind,
                        size: 32,
                        mediaShareTransport: group.transportKind
                    )
                    Text(group.serverName)
                }
            }

            if isWatching(group) {
                identityControl(for: group)

                if isLoading, librariesForActiveIdentity(in: group).isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading libraries…")
                    }
                } else if librariesForActiveIdentity(in: group).isEmpty {
                    if isUnreachable(group) {
                        HStack {
                            Label(
                                "Can't reach this server — it may be offline.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button { Task { await loadLibraries() } } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                        }
                    } else {
                        Text("No video libraries are available.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(librariesForActiveIdentity(in: group)) { library in
                        Toggle(
                            library.title,
                            isOn: Binding(
                                get: {
                                    appModel.settings.homeVisibility.isEnabled(
                                        library.key
                                    )
                                },
                                set: {
                                    appModel.settings.homeVisibility.setEnabled(
                                        $0,
                                        for: library.key
                                    )
                                }
                            )
                        )
                    }
                }
            }
        } footer: {
            Text("Saved for \(appModel.profiles.activeProfile.name).")
        }
    }

    @ViewBuilder
    private func identityControl(for group: ServerAccountGroup) -> some View {
        if group.providerKind == .plex, let account = activeAccount(in: group) {
            NavigationLink {
                PlozziOSPlexHomeUserSettingsView(
                    appModel: appModel,
                    account: account
                )
            } label: {
                HStack(spacing: 12) {
                    PlozziOSPlexIdentityAvatar(
                        url: plexIdentityAvatarURL(for: account),
                        name: plexIdentityName(for: account)
                    )
                    Text(plexIdentityName(for: account))
                }
            }
        } else if group.providerKind != .mediaShare, group.accounts.count > 1 {
            Picker(
                "Watching as",
                selection: Binding(
                    get: { activeAccount(in: group)?.id ?? group.accounts[0].id },
                    set: { selectAccount($0, in: group) }
                )
            ) {
                ForEach(group.accounts) { account in
                    Text(account.userName.isEmpty ? "Guest" : account.userName)
                        .tag(account.id)
                }
            }
        }
    }

    private func plexIdentityName(for account: Account) -> String {
        let homeName = appModel.profiles.activeProfile
            .homeUserBinding(forPlexAccount: account.id)?
            .name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let homeName, !homeName.isEmpty {
            return homeName
        }
        let accountName = account.userName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return accountName.isEmpty ? "Plex Administrator" : accountName
    }

    private func plexIdentityAvatarURL(for account: Account) -> URL? {
        let bindingURL = appModel.profiles.activeProfile
            .homeUserBinding(forPlexAccount: account.id)?
            .avatarURL
            .flatMap(URL.init(string:))
        return bindingURL ?? account.avatarURL
    }

    private func isWatching(_ group: ServerAccountGroup) -> Bool {
        let active = appModel.activeAccountIDs(for: profileID)
        return group.accounts.contains { active.contains($0.id) }
    }

    private struct PlozziOSPlexIdentityAvatar: View {
        let url: URL?
        let name: String

        var body: some View {
            Group {
                if let url {
                    FallbackAsyncImage(
                        urls: [url],
                        variant: .musicThumbnail
                    ) {
                        fallback
                    }
                } else {
                    fallback
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .accessibilityHidden(true)
        }

        private var fallback: some View {
            Circle()
                .fill(Color.accentColor.opacity(0.18))
                .overlay {
                    Text(initials)
                        .font(.subheadline.bold())
                        .foregroundStyle(.tint)
                }
        }

        private var initials: String {
            let letters = name.split(separator: " ")
                .prefix(2)
                .compactMap(\.first)
                .map(String.init)
                .joined()
            return letters.isEmpty ? "P" : letters.uppercased()
        }
    }

    private func activeAccount(in group: ServerAccountGroup) -> Account? {
        let active = appModel.activeAccountIDs(for: profileID)
        return group.accounts.first { active.contains($0.id) }
    }

    private func setWatching(_ enabled: Bool, group: ServerAccountGroup) {
        let selectedID = enabled ? group.accounts.first?.id : nil
        for account in group.accounts {
            appModel.setAccount(
                account.id,
                enabled: account.id == selectedID,
                for: profileID
            )
        }
    }

    private func selectAccount(_ accountID: String, in group: ServerAccountGroup) {
        for account in group.accounts {
            appModel.setAccount(
                account.id,
                enabled: account.id == accountID,
                for: profileID
            )
        }
    }

    private func librariesForActiveIdentity(
        in group: ServerAccountGroup
    ) -> [ProfileLibraryChoice] {
        guard let account = activeAccount(in: group) else { return [] }
        return libraries.filter { $0.accountID == account.id }
    }

    private func loadLibraries() async {
        isLoading = true
        defer { isLoading = false }

        let resolved = appModel.accountsProviders.resolvedAccounts(
            withIDs: appModel.accounts.map(\.id)
        )
        var loaded: [ProfileLibraryChoice] = []
        var unreachable: Set<String> = []
        for account in resolved {
            do {
                let choices = try await account.provider.libraries()
                loaded.append(
                    contentsOf: choices
                        .filter { !$0.isMusic }
                        .map {
                            ProfileLibraryChoice(
                                accountID: account.account.id,
                                library: $0
                            )
                        }
                )
            } catch {
                // A server we couldn't reach is marked unreachable (offline) so the
                // card shows "can't reach this server", not "no libraries".
                unreachable.insert(account.account.id)
            }
        }
        libraries = loaded.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        unreachableAccountIDs = unreachable
    }

    /// Whether every account backing this server card failed its last library
    /// fetch (offline / unreachable).
    private func isUnreachable(_ group: ServerAccountGroup) -> Bool {
        let ids = group.accounts.map(\.id)
        return !ids.isEmpty && ids.allSatisfy { unreachableAccountIDs.contains($0) }
    }
}

private struct ProfileLibraryChoice: Identifiable {
    let accountID: String
    let library: MediaLibrary

    var id: String { key }
    var key: String { "\(accountID):\(library.id)" }
    var title: String { library.title }
}
#endif
