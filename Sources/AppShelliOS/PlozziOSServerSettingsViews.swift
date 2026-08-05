#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureSettings
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
                        .plozzForeground(.secondary)
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
                        .plozzForeground(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .plozzForeground(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func summary(for group: ServerAccountGroup) -> LocalizedStringResource? {
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
                                        .plozzForeground(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .plozzForeground(.tertiary)
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
    /// Signs an additional user in to an already-added server. Same capability as
    /// the tvOS "Watching as" page, in the idiom iOS uses for this screen.
    var onAddUser: (MediaServer) -> Void = { _ in }
    /// Where this screen is being shown. Shared with tvOS, which renders the same
    /// page in both places for the same reason — see `ProfileLibrariesScope`.
    ///
    /// The controls are identical; only surrounding copy and presentation differ.
    /// Add-account actions are supplied by whichever host owns the screen, so
    /// they remain inside Settings or profile setup instead of escaping either.
    var presentation: ProfileLibrariesScope.Presentation = .settings
    @State private var libraries: [ProfileLibraryChoice] = []
    @State private var unreachableAccountIDs: Set<String> = []
    @State private var isLoading = false

    /// Server keys whose switch has been flipped but whose write hasn't landed.
    @State private var pendingWatching: [String: Bool] = [:]

    /// Slightly longer than the knob's 0.18s travel, so the commit lands after
    /// the animation rather than during it.
    private static let switchSettleMilliseconds = 220

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
                        .plozzForeground(.secondary)
                    Button("Add Server", systemImage: "plus", action: onAddServer)
                }
            } else {
                ForEach(groups, id: \.serverKey) { group in
                    serverGroup(group)
                }
            }
        }
        .navigationTitle(SettingsCopy.libraries)
        // Optimistic switch positions belong to the profile they were tapped for.
        .onChange(of: appModel.profiles.activeProfileID) { _, _ in
            pendingWatching.removeAll()
        }
        .task(id: appModel.accounts.map(\.credentialRevision)) {
            await loadLibraries()
        }
        // Asks who you are on a Plex server you just switched on — the same
        // question setup asks, at the other moment it matters. Without it,
        // enabling a server later silently plays (and imports a watchlist) as the
        // account owner, which is the leak the setup step exists to prevent.
        //
        // Presented HERE, from the screen that owns the toggle, rather than from
        // the root: this screen is already inside a presented Settings sheet, and
        // SwiftUI won't show a second presentation from a view that's covered —
        // asking from the root would silently never appear.
        //
        // Suppressed during setup, which asks the same question inline.
        .sheet(item: identityPromptBinding) { account in
            PlozziOSServerIdentityPromptView(
                appModel: appModel,
                account: account,
                onFinish: { appModel.concludeIdentityPrompt(for: account.id) },
                onDecline: { appModel.declineIdentityPrompt(for: account.id) }
            )
        }
    }

    private var identityPromptBinding: Binding<Account?> {
        Binding(
            // Only while Settings is actually up: the root presents the same
            // question when it isn't, and two presenters racing one piece of
            // state is undefined. Suppressed during setup, which asks inline.
            get: {
                presentation == .settings && appModel.isSettingsPresented
                    ? appModel.pendingIdentityAccount
                    : nil
            },
            set: { if $0 == nil { appModel.resolveIdentityPromptForPending() } }
        )
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
                    set: { setWatchingSmoothly($0, group: group) }
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
                            .plozzForeground(.secondary)
                            Spacer()
                            Button { Task { await loadLibraries() } } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                        }
                    } else {
                        Text("No video libraries are available.")
                            .plozzForeground(.secondary)
                    }
                } else {
                    // Checkmarks, not switches. The server above IS a switch —
                    // one thing, on or off — while these are a multi-select
                    // subset of it, which is what a checkmark means everywhere
                    // else in the app (Customize Home, Theme, Display Size).
                    // tvOS already drew them this way; a column of identical
                    // switches here made "watch this server" and "show this
                    // library" look like the same kind of decision.
                    ForEach(librariesForActiveIdentity(in: group)) { library in
                        libraryCheckRow(library)
                    }
                }
            }
        } footer: {
            Text("Saved for \(appModel.profiles.activeProfile.name).")
        }
    }

    /// One library, as a checkmark child of its server's master switch.
    private func libraryCheckRow(_ library: ProfileLibraryChoice) -> some View {
        let isOn = appModel.settings.homeVisibility.isEnabled(library.key)
        return Button {
            appModel.settings.homeVisibility.setEnabled(!isOn, for: library.key)
        } label: {
            HStack {
                Text(verbatim: library.title)
                Spacer(minLength: 12)
                SettingsCheckmark(isChecked: isOn, prominence: .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
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
        addUserButton(group)
    }

    /// Signs another user in to this server.
    ///
    /// Always shown, including when only one user is signed in — that's precisely
    /// the case where you can't otherwise tell the person you want is missing,
    /// and previously the only route was adding the whole server again from the
    /// chooser. Matches the tvOS "Watching as" page.
    @ViewBuilder
    private func addUserButton(_ group: ServerAccountGroup) -> some View {
        if group.providerKind != .mediaShare,
           let server = group.accounts.first?.server {
            Button {
                onAddUser(server)
            } label: {
                Label(
                    group.providerKind == .plex ? "Add Another Plex Account" : "Add Another User",
                    systemImage: "person.badge.plus"
                )
            }
        }
    }

    private func plexIdentityName(for account: Account) -> String {   // l10n:content — Plex user name
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
        // The optimistic value wins while a write is in flight, so the switch
        // reflects the tap immediately rather than waiting on the model.
        if let pending = pendingWatching[group.serverKey] { return pending }
        return isWatchingCommitted(group)
    }

    private func isWatchingCommitted(_ group: ServerAccountGroup) -> Bool {
        let active = appModel.activeAccountIDs(for: profileID)
        return group.accounts.contains { active.contains($0.id) }
    }

    /// Flips the switch now and commits once it has finished moving.
    ///
    /// `setAccount` re-scopes the profile, reloads the account set and rebuilds
    /// the crash context, all on the main actor. Running that from the switch's
    /// own action meant the work landed in the middle of the knob's 0.18s
    /// animation and stalled it — the switch felt heavy and late even though the
    /// tap had registered. Painting the new state from local state first makes the
    /// control answer instantly; the rows below arrive a beat later, which is the
    /// natural reading order anyway.
    private func setWatchingSmoothly(_ enabled: Bool, group: ServerAccountGroup) {
        let key = group.serverKey
        // Pinned BEFORE the wait. `profileID` reads the ACTIVE profile live, so
        // resolving it after the sleep would write to whatever profile happened
        // to be active by then — and a synced deletion can re-point that with no
        // user action at all.
        let targetProfileID = profileID
        pendingWatching[key] = enabled
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.switchSettleMilliseconds))
            // The person moved on; their new profile's membership isn't ours to
            // change, and the switch they were looking at is long gone.
            guard profileID == targetProfileID else {
                if pendingWatching[key] == enabled { pendingWatching[key] = nil }
                return
            }
            setWatching(enabled, group: group, for: targetProfileID)
            // Only clear our own value: a second tap during the wait owns the key.
            if pendingWatching[key] == enabled { pendingWatching[key] = nil }
        }
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

    private func setWatching(
        _ enabled: Bool,
        group: ServerAccountGroup,
        for targetProfileID: String? = nil
    ) {
        let profile = targetProfileID ?? profileID
        let selectedID = enabled ? group.accounts.first?.id : nil
        for account in group.accounts {
            appModel.setAccount(
                account.id,
                enabled: account.id == selectedID,
                for: profile
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
    var title: String { library.title }   // l10n:content — library name from the server
}
#endif
