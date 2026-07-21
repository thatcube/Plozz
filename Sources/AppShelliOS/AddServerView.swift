#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import FeatureAuthCore
import FeatureDiscoveryCore
import ProviderPlex
import SwiftUI

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider: ProviderKind
    @State private var address = ""
    @State private var server: MediaServer?
    @State private var jellyfinDiscovery = ServerPickerViewModel(provider: .jellyfin)
    @State private var embyDiscovery = ServerPickerViewModel(provider: .emby)
    @State private var showingPlexSignIn = false
    @State private var validationMessage: String?

    let appModel: PlozziOSAppModel

    init(appModel: PlozziOSAppModel, initialProvider: ProviderKind = .jellyfin) {
        self.appModel = appModel
        // Media Share isn't a media *server*; callers route it elsewhere. Guard
        // against it here so the provider picker never lands on an invalid state.
        _provider = State(initialValue: initialProvider == .mediaShare ? .jellyfin : initialProvider)
    }

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
                        ManagedServerDiscoverySection(
                            model: discoveryModel,
                            onSelect: selectDiscoveredServer
                        )

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
            .settingsPageSurface()
            .navigationTitle("Add Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $server) { server in
                ManagedServerSignInView(
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
            .task(id: provider) {
                guard provider != .plex else { return }
                let model = discoveryModel
                model.startScan()
                defer { model.stopScan() }
                try? await Task.sleep(for: .seconds(86_400))
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

    private var discoveryModel: ServerPickerViewModel {
        provider == .emby ? embyDiscovery : jellyfinDiscovery
    }

    private func selectDiscoveredServer(_ selectedServer: MediaServer) {
        address = selectedServer.baseURL.absoluteString
        validationMessage = nil
    }
}

private struct ManagedServerDiscoverySection: View {
    let model: ServerPickerViewModel
    let onSelect: (MediaServer) -> Void

    var body: some View {
        if !discoveryServers.isEmpty || model.phase == .scanning {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Nearby servers", systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline)

                    Spacer()

                    if model.phase == .scanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Scan Again") {
                            model.startScan()
                        }
                        .font(.subheadline)
                    }
                }

                ForEach(discoveryServers) { server in
                    Button {
                        model.select(server)
                        onSelect(server)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: server.provider == .emby
                                ? "play.rectangle.on.rectangle"
                                : "play.tv")
                                .foregroundStyle(.tint)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .foregroundStyle(.primary)
                                Text(server.baseURL.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.left")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var discoveryServers: [MediaServer] {
        model.recentServers + model.discoveredServers
    }
}

private struct ManagedServerSignInView: View {
    @State private var usesPassword: Bool
    let server: MediaServer
    let appModel: PlozziOSAppModel
    let onComplete: () -> Void

    init(
        server: MediaServer,
        appModel: PlozziOSAppModel,
        onComplete: @escaping () -> Void
    ) {
        self.server = server
        self.appModel = appModel
        self.onComplete = onComplete
        _usesPassword = State(initialValue: server.provider == .emby)
    }

    var body: some View {
        if usesPassword {
            PasswordServerSignInView(
                server: server,
                appModel: appModel,
                onComplete: onComplete,
                onUseQuickConnect: server.provider == .jellyfin
                    ? { usesPassword = false }
                    : nil
            )
        } else {
            QuickConnectServerSignInView(
                server: server,
                appModel: appModel,
                onComplete: onComplete,
                onUsePassword: { usesPassword = true }
            )
        }
    }
}

private struct QuickConnectServerSignInView: View {
    @State private var viewModel: QuickConnectViewModel
    private let server: MediaServer
    private let onUsePassword: () -> Void

    init(
        server: MediaServer,
        appModel: PlozziOSAppModel,
        onComplete: @escaping () -> Void,
        onUsePassword: @escaping () -> Void
    ) {
        self.server = server
        self.onUsePassword = onUsePassword
        _viewModel = State(
            initialValue: QuickConnectViewModel(
                service: QuickConnectService(
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
                Text(
                    "Open Jellyfin on another device, choose Quick Connect, "
                        + "and enter this code."
                )
                .foregroundStyle(.secondary)
                Text(server.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                phaseContent
                    .frame(maxWidth: .infinity)
            }

            Section("Other options") {
                Button("Sign in with username and password", systemImage: "person.fill") {
                    onUsePassword()
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .idle, .requesting:
            ProgressView("Requesting a code…")
        case let .awaitingApproval(code, expiresAt):
            VStack(spacing: 20) {
                Text(code)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .tracking(8)
                    .monospaced()
                    .textSelection(.enabled)
                    .accessibilityLabel("Quick Connect code \(code)")
                PlozziOSQuickConnectCountdown(
                    expiresAt: expiresAt,
                    lifetime: viewModel.codeLifetime
                )
                Text("Waiting for approval…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        case .success:
            Label("Signed in", systemImage: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case let .error(message):
            ContentUnavailableView {
                Label("Quick Connect unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { viewModel.retry() }
                Button("Use Password") { onUsePassword() }
            }
        }
    }
}

private struct PlozziOSQuickConnectCountdown: View {
    let expiresAt: Date
    let lifetime: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let fraction = lifetime > 0 ? remaining / lifetime : 0
            let tint: Color = remaining <= 15 ? .orange : .accentColor

            ZStack {
                Circle()
                    .stroke(tint.opacity(0.16), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("\(Int(remaining.rounded(.up)))")
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }
            .frame(width: 76, height: 76)
            .accessibilityLabel(
                "Code expires in \(Int(remaining.rounded(.up))) seconds"
            )
        }
    }
}

private struct PasswordServerSignInView: View {
    @State private var viewModel: PasswordSignInViewModel

    private let server: MediaServer
    private let onComplete: () -> Void
    private let onUseQuickConnect: (() -> Void)?

    init(
        server: MediaServer,
        appModel: PlozziOSAppModel,
        onComplete: @escaping () -> Void,
        onUseQuickConnect: (() -> Void)? = nil
    ) {
        self.server = server
        self.onComplete = onComplete
        self.onUseQuickConnect = onUseQuickConnect
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

            if let onUseQuickConnect {
                Section("Other options") {
                    Button("Use Quick Connect", systemImage: "qrcode") {
                        onUseQuickConnect()
                    }
                }
            }
        }
        .settingsPageSurface()
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
        .settingsPageSurface()
        .navigationTitle("Plex")
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.startIfNeeded() }
        .onDisappear { viewModel.cancel() }
    }
}
#endif
