#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// The step a brand-new profile goes through before it's let loose: which
/// servers it uses, who it watches as on each, and which libraries it shows.
///
/// This exists because a new profile inherits EVERY server in the household —
/// no explicit membership means "all of them" — so without it a profile is born
/// holding the household's aggregate watchlist, imported from five servers it
/// never chose. Doing nothing here is still fine and keeps all of them; the
/// point is that it's now a decision rather than an accident.
///
/// Runs with the new profile already ACTIVE, which is what makes it simple: every
/// per-profile model (membership, Plex identity, library visibility) already
/// points at it, so this drives the same code Settings does rather than a
/// parallel set of "…forProfile:" variants. Safe to switch into because the
/// profile is empty and its watchlist import is deferred until this finishes.
struct ProfileSetupView: View {
    @Bindable var appState: AppState
    /// Called once setup is accepted — the caller clears `isAwaitingSetup`,
    /// which releases the watchlist import.
    let onFinish: () -> Void

    @Environment(\.themePalette) private var palette
    @State private var discovery = LibraryDiscoveryModel()
    @State private var libraries: LoadState<[AggregatedLibrary]> = .idle
    @State private var plexUsersByAccount: [String: [PlexHomeUser]] = [:]
    @State private var choosingPlexUserFor: String?
    @State private var reloadRevision = 0

    private var profile: Profile { appState.profilesModel.activeProfile }
    private var accounts: [Account] { appState.accountsProviders.accounts }

    var body: some View {
        ZStack {
            AppBackground(palette: palette).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    header
                    serversPanel
                    librariesPanel
                    finishButton
                }
                .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, 48)
            }
            .scrollClipDisabled()
        }
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .task { await reloadLibraries() }
        .sheet(item: Binding(
            get: { choosingPlexUserFor.map(PlexPickerTarget.init(accountID:)) },
            set: { if $0 == nil { choosingPlexUserFor = nil } }
        )) { target in
            ProfileSetupPlexUserPicker(
                users: plexUsersByAccount[target.accountID] ?? [],
                selectedID: profile.homeUserBinding(forPlexAccount: target.accountID)?.homeUserID,
                onSelect: { user in
                    appState.plexHomeUsers.setPlexHomeUserForActiveProfile(
                        accountID: target.accountID,
                        user: user
                    )
                    choosingPlexUserFor = nil
                },
                onCancel: { choosingPlexUserFor = nil }
            )
        }
    }

    private struct PlexPickerTarget: Identifiable {
        let accountID: String
        var id: String { accountID }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 24) {
            ProfileAvatarView(profile: profile, size: 120)
            VStack(alignment: .leading, spacing: 8) {
                Text("Set up \(profile.name)")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text("Choose what this profile uses. You can change any of it later.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Servers

    private var serversPanel: some View {
        panel(footer: "Turn off a server to hide it from this profile entirely.") {
            VStack(spacing: 14) {
                ForEach(accounts, id: \.id) { account in
                    serverRow(account)
                }
            }
        }
    }

    /// A titled card in the app's settings surface. `SettingsPanel` itself is
    /// internal to FeatureSettings, so this borrows the same shared surface
    /// rather than reaching across the module boundary for one container.
    @ViewBuilder
    private func panel<Content: View>(
        footer: LocalizedStringResource? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .plozzSurface(.raised, cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius)
    }

    @ViewBuilder
    private func serverRow(_ account: Account) -> some View {
        let included = appState.profileFlow.isAccountIncludedInActiveProfile(account.id)
        VStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { included },
                set: { on in
                    appState.profileFlow.setAccount(account.id, includedInActiveProfile: on)
                    Task { await reloadLibraries() }
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: account.server.name).font(.callout.weight(.medium))
                    Text(verbatim: account.userName).font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .toggleStyle(SettingsSwitchToggleStyle())

            // Only Plex has the notion of watching AS someone else, and only
            // when its Home actually has other users.
            if included, account.server.provider == .plex,
               let users = plexUsersByAccount[account.id], users.count > 1 {
                Button {
                    choosingPlexUserFor = account.id
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                        Text("Watching as")
                        Spacer()
                        Text(verbatim: watchingAsName(for: account, users: users))
                            .foregroundStyle(palette.secondaryText)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                .buttonStyle(SettingsFocusButtonStyle())
            }
        }
    }

    private func watchingAsName(for account: Account, users: [PlexHomeUser]) -> String {
        if let bound = profile.homeUserBinding(forPlexAccount: account.id) {
            return bound.name
        }
        return users.first(where: \.isAdmin)?.name ?? account.userName
    }

    // MARK: Libraries

    @ViewBuilder
    private var librariesPanel: some View {
        panel(footer: "Hidden libraries stay off this profile's Home.") {
            switch libraries {
            case .empty:
                Text("No libraries on the servers you picked.")
                    .foregroundStyle(palette.secondaryText)
            case .loading, .idle:
                HStack { ProgressView(); Text("Finding libraries…") }
            case .failed:
                Text("Couldn't reach those servers. You can pick libraries later in Settings.")
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            case let .loaded(all):
                if all.isEmpty {
                    Text("No libraries on the servers you picked.")
                        .foregroundStyle(palette.secondaryText)
                } else {
                    VStack(spacing: 14) {
                        ForEach(all) { library in
                            Toggle(isOn: Binding(
                                get: { appState.profileSettings.homeLibraryVisibilityModel.isEnabled(library.key) },
                                set: { appState.profileSettings.homeLibraryVisibilityModel.setEnabled($0, for: library.key) }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    // Prefer the localized resource when the name
                                    // is Plozz's own invention rather than the
                                    // server's — see `MediaLibrary.title`.
                                    if let synthesized = library.library.synthesizedName {
                                        Text(synthesized.title).font(.callout.weight(.medium))
                                    } else {
                                        Text(verbatim: library.library.title)
                                            .font(.callout.weight(.medium))
                                    }
                                    Text(verbatim: library.serverName)
                                        .font(.footnote)
                                        .foregroundStyle(palette.secondaryText)
                                }
                            }
                            .toggleStyle(SettingsSwitchToggleStyle())
                        }
                    }
                }
            }
        }
    }

    private func reloadLibraries() async {
        reloadRevision += 1
        let revision = reloadRevision
        if libraries.value == nil { libraries = .loading }
        let scoped = appState.accountsProviders.resolvedActiveAccounts.filter {
            appState.profileFlow.isAccountIncludedInActiveProfile($0.account.id)
        }
        await loadPlexUsers(for: scoped.map(\.account))
        let discovered = await discovery.libraryDiscovery(from: scoped)
        guard revision == reloadRevision else { return }
        libraries = .loaded(discovered.libraries)
    }

    /// Fetches Home users so a Plex server can offer "Watching as". Failures are
    /// silent: not being able to list them just means no picker, which is the
    /// same as a Plex account with a single user.
    private func loadPlexUsers(for accounts: [Account]) async {
        for account in accounts where account.server.provider == .plex {
            guard plexUsersByAccount[account.id] == nil else { continue }
            let users = await appState.plexHomeUsers.plexHomeUsers(forAccountID: account.id)
            plexUsersByAccount[account.id] = users
        }
    }

    // MARK: Finish

    private var finishButton: some View {
        Button(action: onFinish) {
            Text("Done")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }
}

/// Picks which Plex Home user this profile plays as on one server.
private struct ProfileSetupPlexUserPicker: View {
    let users: [PlexHomeUser]
    let selectedID: String?
    let onSelect: (PlexHomeUser?) -> Void
    let onCancel: () -> Void

    @Environment(\.themePalette) private var palette

    var body: some View {
        ZStack {
            AppBackground(palette: palette).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Watching as")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    ForEach(users, id: \.id) { user in
                        Button {
                            onSelect(user)
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: user.requiresPIN ? "lock.fill" : "person.crop.circle")
                                Text(verbatim: user.name)
                                Spacer()
                                if user.id == selectedID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(SettingsFocusButtonStyle())
                    }
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(48)
            }
        }
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
    }
}
#endif
