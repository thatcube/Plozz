#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import ProviderShare

/// The values collected when adding a local media share. Passed back to
/// `AppState.didConfigureShare` which mints the account.
struct ShareDraft: Equatable {
    var host: String
    var port: Int?
    var share: String
    var username: String
    var password: String
    var displayName: String
}

/// Discovery-first "Add a Media Share" screen, modeled on the Jellyfin server
/// picker but simpler. Step one lists SMB servers found on the network (with a
/// plain address field as a fallback); step two lists that server's real shares
/// so the user taps one instead of typing its name. A media share is a
/// second-class backend, so this stays lightweight — no reachability probes,
/// recents, or credential management, just enough to point Plozz at a folder.
struct AddShareView: View {
    let isPageReady: Bool
    let onBack: () -> Void
    let onConfigured: (ShareDraft) -> Void
    /// Called when the typed manual address auto-detects as WebDAV, so the host
    /// can switch to the WebDAV flow (pre-seeded with the resolved URL).
    var onWebDAVDetected: (URL) -> Void = { _ in }

    @State private var viewModel = AddShareViewModel()
    @State private var displayName = ""
    @FocusState private var focusedField: Field?
    private enum Field: Hashable {
        case back
        case rescan
        case server(String)
        case host
        case port
        case connect
        case username
        case password
        case share
        case shareOption(String)
        case name
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    switch viewModel.step {
                    case .chooseServer: serverStep
                    case .chooseShare: shareStep
                    }
                }
                .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, 32)
                .padding(.top, proxy.safeAreaInsets.top)
                .padding(.bottom, proxy.safeAreaInsets.bottom)
            }
            .scrollClipDisabled()
            .ignoresSafeArea(.container, edges: .vertical)
        }
        .defaultFocus($focusedField, .back)
        .onExitCommand {
            if viewModel.step == .chooseShare { viewModel.backToServers() } else { onBack() }
        }
        .onAppear {
            focusedField = .back
            if isPageReady { viewModel.startScan() }
        }
        .onChange(of: viewModel.step) { _, _ in focusedField = .back }
        .onChange(of: viewModel.detectedWebDAV) { _, detected in
            if let detected { onWebDAVDetected(detected.url) }
        }
        .onChange(of: isPageReady) { _, ready in
            if ready {
                viewModel.startScan()
            } else {
                viewModel.stopScan()
            }
        }
        .onDisappear { viewModel.stopScan() }
    }

    // MARK: - Step 1: choose a server

    private var serverStep: some View {
        // Discovery starts after the parent transition; keep later result
        // insertions instant so the list never introduces competing motion.
        Group {
            headerRow(
                title: "Add a Media Share",
                subtitle: "Pick a server found on your network, or enter its address.",
                back: onBack,
                trailing: {
                    Button { viewModel.startScan() } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedField, equals: .rescan)
                }
            )

            SharePanel(title: "On your network", titleAccessory: {
                if viewModel.scanning { ProgressView() }
            }) {
                Group {
                    if viewModel.discovered.isEmpty {
                        placeholder(
                            viewModel.scanning
                                ? "Searching for servers…"
                                : "No servers found yet. Make sure the server is on and that Plozz is allowed Local Network access, then rescan — or enter an address below.",
                            systemImage: viewModel.scanning ? "antenna.radiowaves.left.and.right" : "magnifyingglass"
                        )
                    } else {
                        VStack(spacing: 16) {
                            ForEach(viewModel.discovered) { server in
                                Button { viewModel.selectDiscovered(server) } label: {
                                    serverRowLabel(name: server.name, host: server.host)
                                }
                                .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
                                .focused($focusedField, equals: .server(server.id))
                            }
                        }
                    }
                }
                .transaction { $0.animation = nil }
            }

            SharePanel(
                title: "Enter address",
                footer: "Enter your server’s address — an IP or name like 192.168.1.10 or mynas.local, or a full web address for a WebDAV server like nas.local/dav. Plozz detects the rest."
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Server address", text: $viewModel.manualHost)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .host)
                        .onSubmit { focusedField = .port }
                    TextField("Port (optional)", text: $viewModel.manualPortText)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .port)
                        .onSubmit { viewModel.connectManualHost() }
                    Button {
                        viewModel.connectManualHost()
                    } label: {
                        if viewModel.detecting { ProgressView() } else { Text("Connect") }
                    }
                    .disabled(!viewModel.canConnectManualHost || viewModel.detecting)
                    .focused($focusedField, equals: .connect)
                }
            }
        }
    }

    // MARK: - Step 2: choose a share

    private var shareStep: some View {
        Group {
            headerRow(
                title: LocalizedStringKey(viewModel.serverLabel),
                subtitle: "Choose a share to add.",
                back: { viewModel.backToServers() },
                trailing: { EmptyView() }
            )

            switch viewModel.shareLoad {
            case .idle, .loading:
                SharePanel(title: "Shares") {
                    placeholder("Finding shares…", systemImage: "externaldrive.connected.to.line.below")
                }
            case .needsAuth:
                VStack(alignment: .leading, spacing: 28) {
                    credentialsPanel(
                        title: "Sign in",
                        message: "This server requires a username and password.",
                        button: "Connect"
                    )
                    manualSharePanel
                }
            case .badCredentials:
                VStack(alignment: .leading, spacing: 28) {
                    credentialsPanel(
                        title: "Sign in",
                        error: "That username or password was incorrect. Please try again.",
                        button: "Try again"
                    )
                    manualSharePanel
                }
            case .unreachable:
                messagePanel(
                    title: "Can't connect",
                    message: "Couldn't connect to the server. Check the address and that it's on the same network, then try again.",
                    systemImage: "wifi.exclamationmark",
                    retry: { viewModel.loadShares() }
                )
            case .failed(let message):
                VStack(alignment: .leading, spacing: 28) {
                    messagePanel(
                        title: "Something went wrong",
                        message: LocalizedStringKey(message),
                        systemImage: "exclamationmark.triangle",
                        retry: { viewModel.loadShares() }
                    )
                    credentialsPanel(
                        title: "Sign in",
                        message: "If this share needs a different account, enter a username and password and try again.",
                        button: "Try again"
                    )
                    manualSharePanel
                }
            case .loaded:
                loadedSharesPanels
            }
        }
    }

    @ViewBuilder
    private var loadedSharesPanels: some View {
        if viewModel.shares.isEmpty {
            VStack(alignment: .leading, spacing: 28) {
                SharePanel(title: "Shares") {
                    placeholder("No shares found on this server.", systemImage: "externaldrive.badge.questionmark")
                }
                manualSharePanel
            }
        } else {
            VStack(alignment: .leading, spacing: 28) {
                SharePanel(title: "Shares") {
                    VStack(spacing: 16) {
                        ForEach(viewModel.shares, id: \.self) { share in
                            Button { addShare(share) } label: {
                                serverRowLabel(name: share, host: nil, icon: "folder")
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
                            .focused($focusedField, equals: .shareOption(share))
                        }
                    }
                }
                displayNamePanel
            }
        }
    }

    private var displayNamePanel: some View {
        SharePanel(
            title: "Display name (optional)",
            footer: "What to call this share on the Home screen. Defaults to the share name."
        ) {
            TextField("Display name", text: $displayName)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .name)
        }
    }

    /// A neutral message card (not the "Shares" box) used for connection/other
    /// failures, with an optional Retry button. Deliberately avoids implying a
    /// share list ever loaded.
    private func messagePanel(
        title: String,
        message: LocalizedStringKey,
        systemImage: String,
        retry: (() -> Void)? = nil
    ) -> some View {
        SharePanel(title: title) {
            VStack(alignment: .leading, spacing: 18) {
                InlineErrorMessage(message, systemImage: systemImage)
                if let retry {
                    Button("Try again", action: retry)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var manualSharePanel: some View {
        SharePanel(
            title: "Enter share name",
            footer: "If you know the share name, type it here (e.g. Media)."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Share name", text: $viewModel.manualShare)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focusedField, equals: .share)
                    .onSubmit { if viewModel.canUseManualShare { addShare(viewModel.manualShare) } }
                Button("Add Share") { addShare(viewModel.manualShare) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canUseManualShare)
            }
        }
    }

    private func credentialsPanel(
        title: String,
        message: LocalizedStringKey? = nil,
        error: LocalizedStringKey? = nil,
        button: LocalizedStringKey
    ) -> some View {
        SharePanel(title: title, footer: message) {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Username", text: $viewModel.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { viewModel.loadShares() }
                Button(button) { viewModel.loadShares() }
                    .buttonStyle(.borderedProminent)
                if let error {
                    InlineErrorMessage(error)
                }
            }
        }
    }

    // MARK: - Actions

    private func addShare(_ share: String) {
        let trimmed = share.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onConfigured(viewModel.draft(forShare: trimmed, displayName: displayName))
    }

    // MARK: - Shared pieces

    private func headerRow<Trailing: View>(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        back: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button(action: back) {
                    Label("Back", systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
                .focused($focusedField, equals: .back)
                Spacer(minLength: 24)
                trailing()
            }
            OnboardingHeader(title, subtitle: subtitle)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, PlozzTheme.Spacing.large)
    }

    private func serverRowLabel(name: String, host: String?, icon: String = "externaldrive.connected.to.line.below.fill") -> some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .frame(width: 44, height: 44)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.headline)
                if let host, host != name {
                    Text(host).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    private func placeholder(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
    }
}

/// A titled `.ultraThinMaterial` card matching the Settings pages and the
/// Jellyfin server picker (uppercase secondary header, optional trailing
/// accessory + footer). Kept local to the add-share screen.
private struct SharePanel<Content: View, Accessory: View>: View {
    var title: String? = nil
    var footer: LocalizedStringKey? = nil
    var titleAccessory: () -> Accessory
    var content: () -> Content

    init(
        title: String? = nil,
        footer: LocalizedStringKey? = nil,
        @ViewBuilder titleAccessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.titleAccessory = titleAccessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1.0)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    titleAccessory()
                }
            }
            content()
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

#endif
