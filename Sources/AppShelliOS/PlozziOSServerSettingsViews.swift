#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import SwiftUI

struct PlozziOSServersSettingsView: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void

    private var groups: [ServerAccountGroup] {
        serverGroups(from: appModel.accounts)
    }

    var body: some View {
        List {
            SettingsSectionGroup("Servers") {
                if groups.isEmpty {
                    Text("You’re not signed in to any servers yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groups, id: \.serverKey) { group in
                        NavigationLink {
                            PlozziOSServerSettingsDetailView(
                                appModel: appModel,
                                serverKey: group.serverKey
                            )
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: symbol(for: group))
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.serverName)
                                    if let summary = summary(for: group) {
                                        Text(summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
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
                    Label(
                        "Add Network Share",
                        systemImage: "externaldrive.connected.to.line.below"
                    )
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Servers")
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

    private func symbol(for group: ServerAccountGroup) -> String {
        switch group.providerKind {
        case .plex: "play.rectangle.on.rectangle"
        case .jellyfin, .emby: "server.rack"
        case .mediaShare: "externaldrive.connected.to.line.below"
        }
    }
}

private struct PlozziOSServerSettingsDetailView: View {
    let appModel: PlozziOSAppModel
    let serverKey: String
    @State private var confirmRemoveServer = false

    private var group: ServerAccountGroup? {
        serverGroups(from: appModel.accounts).first {
            $0.serverKey == serverKey
        }
    }

    var body: some View {
        List {
            if let group {
                SettingsSectionGroup("Signed in as") {
                    ForEach(group.accounts) { account in
                        NavigationLink {
                            PlozziOSAccountDetailView(
                                appModel: appModel,
                                account: account,
                                onRemove: {
                                    appModel.removeAccount(id: account.id)
                                }
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.userName.isEmpty ? "Guest" : account.userName)
                                Text(account.server.baseURL.host() ?? account.server.baseURL.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
        .settingsPageSurface()
        .navigationTitle(group?.serverName ?? "Server")
        .alert(
            "Remove \(group?.serverName ?? "server")?",
            isPresented: $confirmRemoveServer
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Server", role: .destructive) {
                for account in group?.accounts ?? [] {
                    appModel.removeAccount(id: account.id)
                }
            }
        } message: {
            Text("This signs everyone out and removes the server from this \(deviceName).")
        }
    }
}

struct PlozziOSMyLibrariesSettingsView: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    @State private var libraries: [ProfileLibraryChoice] = []
    @State private var isLoading = false

    private var groups: [ServerAccountGroup] {
        serverGroups(from: appModel.accounts)
    }

    private var profileID: String {
        appModel.profiles.activeProfileID
    }

    var body: some View {
        List {
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
        .settingsPageSurface()
        .navigationTitle("Your Servers & Libraries")
        .task(id: appModel.accounts.map(\.credentialRevision)) {
            await loadLibraries()
        }
    }

    @ViewBuilder
    private func serverGroup(_ group: ServerAccountGroup) -> some View {
        SettingsSectionGroup(group.serverName) {
            Toggle(
                "Use This Server",
                isOn: Binding(
                    get: { isWatching(group) },
                    set: { setWatching($0, group: group) }
                )
            )

            if isWatching(group) {
                identityControl(for: group)

                if isLoading, librariesForActiveIdentity(in: group).isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading libraries…")
                    }
                } else if librariesForActiveIdentity(in: group).isEmpty {
                    Text("No video libraries are available.")
                        .foregroundStyle(.secondary)
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
                Label("Plex User", systemImage: "person.crop.circle")
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

    private func isWatching(_ group: ServerAccountGroup) -> Bool {
        let active = appModel.activeAccountIDs(for: profileID)
        return group.accounts.contains { active.contains($0.id) }
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
        for account in resolved {
            guard let choices = try? await account.provider.libraries() else {
                continue
            }
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
        }
        libraries = loaded.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
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
