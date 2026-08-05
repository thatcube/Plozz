#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SeerService
import SwiftUI

/// Profile-setup step for the household Seerr connection and per-profile acting
/// user.
///
/// One screen serves first run and every later profile. If Seerr is disconnected,
/// it can be enabled here; once connected, the adult chooses which Seerr user owns
/// this profile's requests. Kids Profiles never offer the unrestricted admin.
public struct ProfileSeerrSetupView: View {
    private let seer: SeerService
    private let profile: Profile
    private let onSelect: (SeerUser?) -> Void
    private let onContinue: () -> Void

    @Environment(\.themePalette) private var palette
    @State private var serverAddress = ""
    @State private var apiKey = ""
    @State private var users: LoadState<[SeerUser]> = .idle
    @State private var selectedUserID: Int?
    @State private var hasSelection = false
    @State private var didPrefill = false

    public init(
        seer: SeerService,
        profile: Profile,
        onSelect: @escaping (SeerUser?) -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.seer = seer
        self.profile = profile
        self.onSelect = onSelect
        self.onContinue = onContinue
    }

    public var body: some View {
        ZStack {
            AppBackground(palette: palette).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    SettingsPageHeader(
                        "Requests as — \(profile.name)",
                        subtitle: "Choose whose Seerr permissions, quota, approvals, and quality profile this Plozz profile uses."
                    )
                    switch seer.phase {
                    case .connected:
                        connectedContent
                    default:
                        connectionContent
                    }
                    actionBar
                }
                .frame(
                    maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, 32)
            }
            .scrollClipDisabled()
        }
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .task {
            guard !didPrefill else { return }
            didPrefill = true
            serverAddress = seer.savedBaseURLString ?? ""
            selectedUserID = profile.seerrUserID
            hasSelection = profile.seerrUserID != nil
            await seer.refreshStatus()
            if seer.isConfigured { await loadUsers() }
        }
        .onChange(of: seer.phase) { _, phase in
            if case .connected = phase {
                Task { await loadUsers() }
            }
        }
    }

    private var connectionContent: some View {
        SettingsPanel(
            title: "Connect Seerr",
            footer: "Seerr is shared by every Plozz profile. The acting user is chosen separately for each profile."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                TextField(
                    "Server address (e.g. https://requests.example.com)",
                    text: $serverAddress
                )
                .textContentType(.URL)
                #if os(tvOS) || os(iOS)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                #endif

                SecureField("Admin API key", text: $apiKey)
                    .textContentType(.password)
                    #if os(tvOS) || os(iOS)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    #endif

                if case .connecting = seer.phase {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Connecting…").plozzForeground(.secondary)
                    }
                } else {
                    Button {
                        connect()
                    } label: {
                        Label("Connect", systemImage: "link")
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
                    .disabled(!canConnect)
                }

                if case let .failed(message) = seer.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var connectedContent: some View {
        SettingsPanel(
            footer: profile.isKids
                ? "Kids Profiles must use a Seerr user. Admin requests are unavailable."
                : "Admin is unrestricted. Choose a user to use their quota and approval flow instead."
        ) {
            VStack(spacing: 14) {
                if !profile.isKids {
                    selectionRow(
                        title: Text("Admin — unrestricted"),
                        subtitle: Text("No per-user quota or approval."),
                        avatarURL: nil,
                        fallback: "person.crop.circle.badge.checkmark",
                        selected: hasSelection && selectedUserID == nil
                    ) {
                        selectedUserID = nil
                        hasSelection = true
                    }
                }

                switch users {
                case .idle, .loading:
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Loading Seerr users…").plozzForeground(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                case .failed:
                    Button {
                        Task { await loadUsers() }
                    } label: {
                        Label("Retry loading users", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SettingsFocusButtonStyle())
                case .empty:
                    Text("No Seerr users found.")
                        .plozzForeground(.secondary)
                        .padding(.vertical, 12)
                case let .loaded(list):
                    ForEach(list) { user in
                        selectionRow(
                            title: Text(verbatim: user.name),
                            subtitle: user.subtitle.map { Text(verbatim: $0) },
                            avatarURL: user.avatarURL,
                            fallback: "person.fill",
                            selected: hasSelection && selectedUserID == user.id
                        ) {
                            selectedUserID = user.id
                            hasSelection = true
                        }
                    }
                }
            }
            .tvOSFocusSection()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 20) {
            Button("Not Now", action: onContinue)
                .buttonStyle(.bordered)
                .controlSize(.large)
            Button("Continue") {
                guard hasSelection else { return }
                let selected = users.value?.first { $0.id == selectedUserID }
                onSelect(selected)
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!hasSelection)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .tvOSFocusSection()
    }

    /// - Parameters:
    ///   - title: `Text` rather than `String` because callers pass BOTH app copy
    ///     ("Admin — unrestricted") and provider content (a Seerr user's name); a
    ///     `String` forced the copy case to resolve eagerly and rendered verbatim.
    private func selectionRow(
        title: Text,
        subtitle: Text?,
        avatarURL: URL?,
        fallback: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                avatar(url: avatarURL, fallback: fallback)
                VStack(alignment: .leading, spacing: 3) {
                    title.font(.headline)
                    if let subtitle {
                        subtitle
                            .font(.caption)
                            .settingsRowSecondary()
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .settingsRowGreenIndicator()
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
    }

    private func avatar(url: URL?, fallback: String) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: fallback)
                    }
                }
            } else {
                Image(systemName: fallback)
            }
        }
        .frame(width: 52, height: 52)
        .background(palette.cardSurface, in: Circle())
        .clipShape(Circle())
    }

    private var canConnect: Bool {
        SeerConfig.normalizedBaseURL(from: serverAddress) != nil
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect() {
        guard let url = SeerConfig.normalizedBaseURL(from: serverAddress) else { return }
        Task { await seer.connect(baseURL: url, apiKey: apiKey) }
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
}
#endif
