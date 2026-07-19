#if os(iOS)
import SeerService
import SwiftUI

struct PlozziOSSeerrSettingsView: View {
    let appModel: PlozziOSAppModel
    @State private var urlText: String
    @State private var apiKey = ""
    @State private var users: [SeerUser] = []
    @State private var isLoadingUsers = false
    @State private var usersError: String?

    init(appModel: PlozziOSAppModel) {
        self.appModel = appModel
        _urlText = State(initialValue: appModel.seerService.savedBaseURLString ?? "")
    }

    var body: some View {
        Form {
            Section {
                Text(
                    "Connect one Overseerr or Jellyseerr server for the household. "
                        + "Each Plozz profile can make requests as a different user."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Connection") {
                connectionContent
            }

            if appModel.seerService.isConfigured {
                Section {
                    profileMappings
                } header: {
                    Text("Requests are made as")
                } footer: {
                    Text(
                        "Unlinked profiles request as the administrator. "
                            + "Linked profiles use that user’s permissions, quotas, and defaults."
                    )
                }
            }
        }
        .navigationTitle("Requests")
        .task {
            await appModel.seerService.refreshStatus()
            if appModel.seerService.isConfigured {
                await loadUsers()
            }
        }
    }

    @ViewBuilder
    private var connectionContent: some View {
        switch appModel.seerService.phase {
        case .unknown, .connecting:
            HStack {
                ProgressView()
                Text("Checking connection…")
                    .foregroundStyle(.secondary)
            }
        case .unconfigured:
            connectionFields
        case let .connected(summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let savedURL = appModel.seerService.savedBaseURLString {
                Text(savedURL)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Test Connection") {
                Task { await appModel.seerService.refreshStatus() }
            }
            Button("Disconnect", role: .destructive) {
                appModel.disconnectSeerr()
                users = []
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            if appModel.seerService.isConfigured {
                Button("Try Again") {
                    Task { await appModel.seerService.refreshStatus() }
                }
                Button("Disconnect", role: .destructive) {
                    appModel.disconnectSeerr()
                    users = []
                }
            } else {
                connectionFields
            }
        }
    }

    @ViewBuilder
    private var connectionFields: some View {
        TextField("Server address", text: $urlText, prompt: Text("192.168.1.20:5055"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        SecureField("API key", text: $apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        Button("Connect") {
            connect()
        }
        .disabled(!canConnect)
    }

    @ViewBuilder
    private var profileMappings: some View {
        if isLoadingUsers {
            HStack {
                ProgressView()
                Text("Loading users…")
                    .foregroundStyle(.secondary)
            }
        } else if let usersError {
            Label(usersError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button("Try Again") {
                Task { await loadUsers() }
            }
        } else if users.isEmpty {
            Text("No users found.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(appModel.profiles.profiles) { profile in
                Picker(
                    profile.name,
                    selection: Binding(
                        get: { profile.seerrUserID },
                        set: { userID in
                            let user = users.first(where: { $0.id == userID })
                            appModel.setSeerrUser(user, for: profile.id)
                        }
                    )
                ) {
                    Text("Admin — unrestricted")
                        .tag(Optional<Int>.none)
                    if let currentID = profile.seerrUserID,
                       !users.contains(where: { $0.id == currentID }) {
                        Text(profile.seerrUserName ?? "Unavailable user")
                            .tag(Optional(currentID))
                    }
                    ForEach(users) { user in
                        Text(user.name)
                            .tag(Optional(user.id))
                    }
                }
            }
        }
    }

    private var canConnect: Bool {
        SeerConfig.normalizedBaseURL(from: urlText) != nil
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect() {
        guard let url = SeerConfig.normalizedBaseURL(from: urlText) else { return }
        Task {
            await appModel.seerService.connect(baseURL: url, apiKey: apiKey)
            guard appModel.seerService.isConfigured else { return }
            apiKey = ""
            await loadUsers()
        }
    }

    private func loadUsers() async {
        isLoadingUsers = true
        usersError = nil
        defer { isLoadingUsers = false }
        do {
            users = try await appModel.seerService.users()
        } catch {
            usersError = "Couldn’t load Seerr users."
        }
    }
}
#endif
