#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles
import SeerService

/// Settings → This Apple TV → Seerr.
///
/// Seerr (Overseerr / Jellyseerr) is **household scope**: one shared admin
/// connection powers the Home hero's trending row and lets everyone on this
/// Apple TV request movies & shows. It therefore lives under *This Apple TV*
/// alongside Servers and Profiles — not inside a profile's per-account
/// Trackers, which each link one person's own login.
///
/// The per-profile nuance ("requests are made as") is still managed here: it's
/// household-level data (profiles are shared) that maps each profile to a
/// Seerr user so their requests use that person's quota, approvals, and
/// default quality profile.
///
/// Unlike the OAuth trackers (device-code flows), Seerr is self-hosted, so this
/// collects a server URL and an admin API key, then drives
/// ``SeerService/connect(baseURL:apiKey:userId:)`` and reflects the resulting
/// ``SeerConnectionPhase``.
struct SeerDetailView: View {
    let seer: SeerService
    /// Hosts of already-configured media servers (Jellyfin/Plex/etc.), used to
    /// give Seerr auto-discovery a near-instant hit when it's co-hosted on the
    /// same box — very common for self-hosted setups.
    var knownServerHosts: [String] = []
    /// Household profiles for the "requests are made as" mapping list.
    var profiles: [Profile] = []
    /// Persists a profile → Seerr-user mapping (or clears it when `nil`).
    var onSetSeerrUser: (String, SeerUser?) -> Void = { _, _ in }

    @State private var urlText: String = ""
    @State private var apiKeyText: String = ""
    @State private var didPrefill = false
    @State private var discovered: [DiscoveredSeerServer] = []
    @State private var discoveryScanning = false
    /// Loaded Seerr users for the mapping picker; `LoadState` mirrors the app's
    /// idle/loading/loaded/failed convention so the list shows a spinner, an
    /// error + Retry, or the picker rows.
    @State private var users: LoadState<[SeerUser]> = .idle
    private let discovery = SeerDiscovery()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsPageHeader("Seerr", subtitle: headerSubtitle)
                switch seer.phase {
                case let .connected(summary):
                    connectionPanel(summary: summary)
                    requestsAsPanel
                default:
                    connectPanel
                }
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .task { await seer.refreshStatus() }
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            if let saved = seer.savedBaseURLString { urlText = saved }
        }
    }

    /// Subtitle conveys the one thing the "Seerr" title doesn't: that this is a
    /// device-wide connection. When disconnected it also names what Seerr is,
    /// since that's the first-run context a new user needs to connect.
    private var headerSubtitle: String {
        if case .connected = seer.phase {
            return "Shared across every profile on this Apple TV."
        }
        return "Connect a Seerr server (Overseerr / Jellyseerr) to discover and request movies, shows & anime for everyone on this Apple TV."
    }

    // MARK: - Connect (not yet connected)

    private var connectPanel: some View {
        SettingsPanel {
            VStack(alignment: .leading, spacing: 16) {
                discoveredSection

                TextField("Server address (e.g. https://requests.example.com)", text: $urlText)
                    .textContentType(.URL)
                    #if os(tvOS) || os(iOS)
                    .keyboardType(.URL)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    #endif

                SecureField("Admin API key", text: $apiKeyText)
                    .textContentType(.password)
                    #if os(tvOS) || os(iOS)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    #endif

                if case .connecting = seer.phase {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Connecting…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(action: connect) {
                        Label("Connect", systemImage: "link")
                    }
                    .disabled(!canConnect)
                }

                if case let .failed(message) = seer.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await scanForServers() }
    }

    /// Auto-discovered Seerr servers on the local network — tapping a row
    /// fills the address field, but the API key still has to be entered by
    /// hand (finding a server needs no auth; connecting to it does).
    @ViewBuilder
    private var discoveredSection: some View {
        if discoveryScanning || !discovered.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("On your network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if discoveryScanning {
                        ProgressView().controlSize(.small)
                    }
                }
                ForEach(discovered) { server in
                    Button {
                        urlText = server.baseURL.absoluteString
                    } label: {
                        HStack {
                            Label(server.baseURL.host ?? server.baseURL.absoluteString, systemImage: "server.rack")
                            Spacer()
                            if let version = server.version {
                                Text("v\(version)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func scanForServers() async {
        discoveryScanning = true
        defer { discoveryScanning = false }
        for await server in discovery.discover(hostHints: knownServerHosts) {
            if !discovered.contains(where: { $0.id == server.id }) {
                discovered.append(server)
            }
        }
    }

    // MARK: - Connected

    private func connectionPanel(summary: String) -> some View {
        SettingsPanel(title: "Connection") {
            VStack(alignment: .leading, spacing: 18) {
                Label("Connected", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let host = seer.savedBaseURLString {
                    Text(host)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    seer.disconnect()
                    apiKeyText = ""
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
        }
    }

    /// "Requests are made as" — one row per household profile, mapping it to a
    /// Seerr user so that person's requests use their own quota / approvals /
    /// default quality profile. Unmapped profiles request as the unrestricted
    /// admin. Shown only when the household actually has profiles to map.
    @ViewBuilder
    private var requestsAsPanel: some View {
        if !profiles.isEmpty {
            SettingsPanel(
                title: "Requests are made as",
                footer: "Link each profile to a Seerr user so their requests use that person’s quota, approvals, and quality profile. Unlinked profiles request as the admin (unrestricted)."
            ) {
                switch users {
                case .loading, .idle:
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Loading Seerr users…").font(.callout).foregroundStyle(.secondary)
                    }
                case .failed:
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Couldn’t load Seerr users.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Button { Task { await loadUsers() } } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                    }
                case let .loaded(list):
                    VStack(spacing: 14) {
                        ForEach(profiles) { profile in
                            NavigationLink {
                                SeerUserPickerView(
                                    profileName: profile.name,
                                    users: list,
                                    selectedUserID: profile.seerrUserID,
                                    onSelect: { onSetSeerrUser(profile.id, $0) }
                                )
                            } label: {
                                profileMappingRow(profile: profile, users: list)
                            }
                            .buttonStyle(SettingsFocusButtonStyle())
                        }
                    }
                case .empty:
                    Text("No Seerr users found.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .task { await loadUsersIfNeeded() }
        }
    }

    /// A single profile → Seerr-user row: profile name on the left, the mapped
    /// user (or "Admin — unrestricted") on the right.
    private func profileMappingRow(profile: Profile, users: [SeerUser]) -> some View {
        // Prefer the freshly-loaded user's name (self-heals a stale cached name),
        // else the cached name, else the neutral admin label.
        let mappedName: String? = profile.seerrUserID.flatMap { id in
            users.first(where: { $0.id == id })?.name ?? profile.seerrUserName
        }
        return HStack(spacing: 16) {
            ProfileAvatarView(profile: profile, size: 40)
            Text(profile.name)
            Spacer()
            Text(mappedName ?? "Admin — unrestricted")
                .foregroundStyle(mappedName == nil ? .secondary : .primary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private func loadUsersIfNeeded() async {
        if case .loaded = users { return }
        await loadUsers()
    }

    private func loadUsers() async {
        users = .loading
        do {
            let list = try await seer.users()
            users = list.isEmpty ? .empty : .loaded(list)
        } catch {
            users = .failed((error as? AppError) ?? .unknown(""))
        }
    }

    private var canConnect: Bool {
        SeerConfig.normalizedBaseURL(from: urlText) != nil
            && !apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect() {
        guard let url = SeerConfig.normalizedBaseURL(from: urlText) else { return }
        let key = apiKeyText
        Task { await seer.connect(baseURL: url, apiKey: key) }
    }
}

/// Push-navigation picker for mapping one household profile to a Seerr user.
/// Mirrors the other Settings pickers (e.g. Plex Home users): a width-restricted
/// page whose focusable rows live in a shared ``SettingsPanel``, with
/// "Admin — unrestricted" first, then each Seerr user; the current selection
/// is checkmarked. Selecting a row writes the mapping and pops back.
private struct SeerUserPickerView: View {
    let profileName: String
    let users: [SeerUser]
    let selectedUserID: Int?
    let onSelect: (SeerUser?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsPanel(
                    title: "Requests as — \(profileName)",
                    footer: "Requests from \(profileName) will use this Seerr user’s quota, approvals, and default quality profile."
                ) {
                    VStack(spacing: 14) {
                        row(
                            title: "Admin — unrestricted",
                            subtitle: "Requests as the admin; no per-user quota or approval.",
                            isSelected: selectedUserID == nil
                        ) {
                            onSelect(nil)
                            dismiss()
                        }

                        if !users.isEmpty {
                            Text("Seerr users")
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }

                        ForEach(users) { user in
                            row(
                                title: user.name,
                                subtitle: user.subtitle,
                                isSelected: user.id == selectedUserID
                            ) {
                                onSelect(user)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private func row(title: String, subtitle: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
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
}
#endif
