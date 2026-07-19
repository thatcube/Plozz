#if os(iOS)
import CoreModels
import CoreNetworking
import FeatureAuthCore
import ProviderPlex
import SwiftUI

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider: ProviderKind = .jellyfin
    @State private var address = ""
    @State private var server: MediaServer?
    @State private var showingPlexSignIn = false
    @State private var validationMessage: String?

    let appModel: PlozziOSAppModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $provider) {
                        Text("Jellyfin").tag(ProviderKind.jellyfin)
                        Text("Emby").tag(ProviderKind.emby)
                        Text("Plex").tag(ProviderKind.plex)
                    }

                    if provider != .plex {
                        TextField("Server address", text: $address)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Media server")
                } footer: {
                    if provider == .plex {
                        Text("Plex sign-in finds every server linked to your account.")
                    } else {
                        Text("Use a hostname, IP address, or full URL.")
                    }
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(provider == .plex ? "Link Plex account" : "Continue") {
                        continueSignIn()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Add Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $server) { server in
                PasswordServerSignInView(
                    server: server,
                    appModel: appModel,
                    onComplete: { dismiss() }
                )
            }
            .navigationDestination(isPresented: $showingPlexSignIn) {
                PlexServerSignInView(
                    appModel: appModel,
                    onComplete: { dismiss() }
                )
            }
        }
    }

    private func continueSignIn() {
        validationMessage = nil
        if provider == .plex {
            showingPlexSignIn = true
            return
        }
        guard let url = ServerURLNormalizer.normalize(address) else {
            validationMessage = "Enter a valid server address."
            return
        }
        server = MediaServer(
            id: url.absoluteString,
            name: provider.displayName,
            baseURL: url,
            provider: provider
        )
    }
}

private struct PasswordServerSignInView: View {
    @State private var viewModel: PasswordSignInViewModel

    private let server: MediaServer
    private let onComplete: () -> Void

    init(
        server: MediaServer,
        appModel: PlozziOSAppModel,
        onComplete: @escaping () -> Void
    ) {
        self.server = server
        self.onComplete = onComplete
        _viewModel = State(
            initialValue: PasswordSignInViewModel(
                service: PasswordSignInService(
                    server: server,
                    deviceID: appModel.deviceID
                ),
                onAuthenticated: {
                    appModel.persist([$0])
                    onComplete()
                }
            )
        )
    }

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $viewModel.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
                    .onSubmit { viewModel.submit() }
            } header: {
                Text(server.name)
            } footer: {
                Text(server.baseURL.absoluteString)
            }

            if case let .error(message) = viewModel.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    viewModel.submit()
                } label: {
                    if case .submitting = viewModel.phase {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!viewModel.canSubmit)
            }
        }
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { viewModel.cancel() }
    }
}

private struct PlexServerSignInView: View {
    @Environment(\.openURL) private var openURL
    @State private var viewModel: PlexAuthViewModel

    private let onComplete: () -> Void

    init(appModel: PlozziOSAppModel, onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        _viewModel = State(
            initialValue: PlexAuthViewModel(
                service: PlexAuthService(deviceID: appModel.deviceID),
                onAuthenticated: {
                    appModel.persist([$0])
                    onComplete()
                },
                onAuthenticatedMany: {
                    appModel.persist($0)
                    onComplete()
                }
            )
        )
    }

    var body: some View {
        List {
            switch viewModel.phase {
            case .idle, .requesting:
                ProgressView("Requesting a Plex link code…")
                    .frame(maxWidth: .infinity)
            case let .awaitingLink(code, authorizationURL, _):
                Section("Link your Plex account") {
                    Text(code)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospaced()
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)

                    Button("Open Plex to link") {
                        openURL(authorizationURL)
                    }
                }
            case .loadingServers:
                ProgressView("Loading your Plex servers…")
                    .frame(maxWidth: .infinity)
            case let .selectingServer(servers):
                Section("Choose a server") {
                    ForEach(servers) { server in
                        Button {
                            viewModel.selectServer(server)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(server.name)
                                Text(server.baseURL.host() ?? server.baseURL.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            case let .error(message):
                ContentUnavailableView {
                    Label("Unable to link Plex", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { viewModel.start() }
                }
            }
        }
        .navigationTitle("Plex")
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.startIfNeeded() }
        .onDisappear { viewModel.cancel() }
    }
}
#endif
