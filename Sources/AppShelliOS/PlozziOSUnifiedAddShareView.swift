#if os(iOS)
import FeatureShareOnboarding
import CoreModels
import CoreUI
import ProviderShare
import SwiftUI

/// iOS/iPadOS "Add a Media Share" — a native port of the tvOS unified flow. Reuses
/// the shared `UnifiedAddShareModel` (all discovery / connect / verify / location
/// logic) and mirrors its five steps with native iOS idioms:
///
///  1. Choose device — "Detected automatically" list + "Enter an address manually"
///  2. Connect — Protocol → Address+Port → credentials → nickname
///  3. Verify — TOFU fingerprint approval (WebDAV self-signed TLS / SFTP host key)
///  4. Pick location — SMB shares, NFS exports, or drillable WebDAV/SFTP/FTP folders
///  5. Coming soon — for transports not yet wired
///
/// Its three output callbacks are wired to the iOS app model's add* handlers.
@MainActor
struct PlozziOSUnifiedAddShareView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    let embedsNavigationStack: Bool
    @State private var viewModel = UnifiedAddShareModel()
    @State private var wired = false
    @State private var saveError: String?

    init(
        appModel: PlozziOSAppModel,
        embedsNavigationStack: Bool = true
    ) {
        self.appModel = appModel
        self.embedsNavigationStack = embedsNavigationStack
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack {
                    content
                }
            } else {
                content
            }
        }
        .onAppear {
            if !wired {
                wired = true
                viewModel.onSMBConfigured = { draft in
                    saveError = nil
                    if appModel.addSMBShare(
                        host: draft.host,
                        port: draft.port,
                        share: draft.share,
                        username: draft.username,
                        password: draft.password,
                        displayName: draft.displayName,
                        subpath: draft.subpath
                    ) {
                        dismiss()
                    } else {
                        saveError = appModel.accountError
                            ?? "Couldn’t save this SMB share."
                    }
                }
                viewModel.onWebDAVConfigured = { config in
                    saveError = nil
                    if appModel.addWebDAVShare(
                        baseURL: config.baseURL,
                        auth: config.auth,
                        trustPin: config.trustPin,
                        displayName: config.displayName
                    ) {
                        dismiss()
                    } else {
                        saveError = appModel.accountError
                            ?? "Couldn’t save this WebDAV share."
                    }
                }
                viewModel.onMediaShareConfigured = { result in
                    saveError = nil
                    let saved: Bool
                    switch result {
                    case let .nfs(c):
                        saved = appModel.addNFSShare(
                            host: c.host,
                            port: c.port,
                            exportPath: c.exportPath,
                            subpath: c.subpath,
                            displayName: c.displayName
                        )
                    case let .sftp(c):
                        saved = appModel.addSFTPShare(
                            host: c.host,
                            port: c.port,
                            path: c.path,
                            username: c.username,
                            password: c.password,
                            hostKeyPin: c.hostKeyPin,
                            displayName: c.displayName
                        )
                    case let .ftp(c):
                        saved = appModel.addFTPShare(
                            baseURL: c.baseURL,
                            auth: c.auth,
                            displayName: c.displayName
                        )
                    }
                    if saved {
                        dismiss()
                    } else {
                        saveError = appModel.accountError
                            ?? "Couldn’t save this network share."
                    }
                }
            }
            viewModel.startScan()
        }
        .onDisappear { viewModel.stopScan() }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch viewModel.step {
            case .chooseDevice: deviceStep
            case .connect: connectStep
            case .verifyTrust(let sha256): verifyStep(sha256)
            case .pickLocation: locationStep
            case .comingSoon(let kind): comingSoonStep(kind)
            }
        }
        .navigationTitle(stepTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(
                    viewModel.step == .chooseDevice ? "Cancel" : "Back",
                    action: back
                )
            }
        }
    }

    private var stepTitle: LocalizedStringResource {
        switch viewModel.step {
        case .chooseDevice: return "Add a Media Share"
        case .connect: return "Connect"
        case .verifyTrust: return viewModel.selectedTransport == .sftp ? "Verify Host Key" : "Verify Certificate"
        case .pickLocation: return locationTitle
        case .comingSoon: return "Coming Soon"
        }
    }

    private func back() {
        switch viewModel.step {
        case .chooseDevice: dismiss()
        case .connect: viewModel.backToDevices()
        case .verifyTrust: viewModel.rejectTrust()
        case .pickLocation: viewModel.backToConnect()
        case .comingSoon: viewModel.backToConnect()
        }
    }

    // MARK: - Step 1: choose device

    private var deviceStep: some View {
        List {
            Section {
                if viewModel.boxes.isEmpty {
                    HStack(spacing: 12) {
                        if viewModel.scanning { ProgressView() }
                        Text(viewModel.scanning ? "Searching…" : "Nothing detected yet.")
                            .foregroundStyle(palette.secondaryText)
                    }
                } else {
                    ForEach(viewModel.boxes) { box in
                        Button { viewModel.openConnect(for: box) } label: {
                            deviceRow(box)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("Detected automatically")
                    if viewModel.scanning && !viewModel.boxes.isEmpty {
                        Spacer(); ProgressView().controlSize(.mini)
                    }
                }
            }

            Section {
                Button { viewModel.openManualConnect() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "keyboard").foregroundStyle(palette.secondaryText)
                        Text("Enter an address manually")
                        Spacer()
                        Image(systemName: "chevron.forward").font(.footnote).foregroundStyle(palette.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { viewModel.startScan() } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func deviceRow(_ box: DiscoveredMediaShareBox) -> some View {
        let protocols = box.doors.map { $0.transport.badgeLabel }.joined(separator: " · ")
        return HStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below.fill")
                .font(.title2).foregroundStyle(palette.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(box.displayName).font(.headline).foregroundStyle(palette.primaryText)
                Text("\(box.host) · \(protocols) detected")
                    .font(.footnote).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.forward").font(.footnote).foregroundStyle(palette.secondaryText)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Step 2: connect

    private var connectStep: some View {
        Form {
            Section {
                Picker(
                    "Protocol",
                    selection: Binding(
                        get: { viewModel.selectedTransport },
                        set: { viewModel.applyTransport($0) }
                    )
                ) {
                    ForEach(MediaShareTransportCatalog.preferenceOrder, id: \.self) { kind in
                        protocolLabel(kind).tag(kind)
                    }
                }
                TextField("Address — e.g. 192.168.1.100 or mynas.local", text: $viewModel.address)
                    .textContentType(.URL).autocorrectionDisabled()
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("Port (optional)", text: $viewModel.portText)
                    .keyboardType(.numberPad)
                if detectedPorts.count > 1 {
                    HStack(spacing: 10) {
                        Text("Detected:").font(.footnote).foregroundStyle(palette.secondaryText)
                        ForEach(detectedPorts, id: \.self) { p in
                            Button(":\(p)") { viewModel.portText = String(p) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }

            credentialSection

            Section("Display") {
                TextField("Nickname — e.g. Living Room NAS", text: $viewModel.displayName)
                    .autocorrectionDisabled()
            }

            if let error = viewModel.connectError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(action: viewModel.connect) {
                    HStack {
                        Spacer()
                        if viewModel.detecting { ProgressView() } else { Text("Connect").bold() }
                        Spacer()
                    }
                }
                .disabled(!viewModel.canConnect || viewModel.detecting)
            }
        }
    }

    @ViewBuilder
    private var credentialSection: some View {
        let kind = viewModel.selectedTransport
        if let descriptor = viewModel.descriptor(kind), !descriptor.authModes.isEmpty {
            Section("Sign in") {
                if descriptor.authModes.contains(.token) {
                    Picker("Method", selection: $viewModel.authMode) {
                        Text("Username & password").tag(UnifiedAddShareModel.AuthMode.usernamePassword)
                        Text("Token").tag(UnifiedAddShareModel.AuthMode.token)
                    }
                    .pickerStyle(.segmented)
                }
                if viewModel.authMode == .token {
                    SecureField("Token", text: $viewModel.token)
                        .autocorrectionDisabled()
                } else {
                    TextField(descriptor.allowsBlankGuest ? "Username (blank for guest)" : "Username",
                              text: $viewModel.username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(descriptor.allowsBlankGuest ? "Password (optional)" : "Password",
                                text: $viewModel.password)
                        .textContentType(.password)
                }
                if let warning = viewModel.plaintextWarning {
                    Label(warning, systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(palette.secondaryText)
                }
            }
        }
    }

    private var detectedPorts: [Int] { viewModel.detectedPorts(for: viewModel.selectedTransport) }

    /// The protocol name itself is a brand (SMB, NFS…) so it stays verbatim; only
    /// the "(detected)" annotation is translatable.
    private func protocolLabel(_ kind: MediaShareTransportKind) -> Text {
        viewModel.detectedDoors.contains { $0.transport == kind }
            ? Text("\(kind.badgeLabel) (detected)") : Text(verbatim: kind.badgeLabel)
    }

    // MARK: - Step 3: verify trust

    private func verifyStep(_ sha256: Data) -> some View {
        let isHostKey = viewModel.selectedTransport == .sftp
        return Form {
            Section(isHostKey ? "SSH Host Key SHA-256" : "Certificate SHA-256") {
                Text(formatFingerprint(sha256))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section {
                Text(isHostKey
                    ? "Only approve if this matches your server’s SSH host key. Approving pins this exact key; a change requires re-approval."
                    : "Only approve if this matches your server. Approving pins this exact certificate; a change requires re-approval.")
                    .font(.footnote).foregroundStyle(palette.secondaryText)
            }
            Section {
                Button("Approve & Continue") { viewModel.approveTrust() }
                Button("Cancel", role: .cancel) { viewModel.rejectTrust() }
            }
        }
    }

    // MARK: - Step 4: pick location

    private var locationTitle: LocalizedStringResource {
        if viewModel.showsCurrentFolder {
            return "Choose a folder"
        }
        switch viewModel.selectedTransport {
        case .nfs: return "Choose an export"
        case .smb: return "Choose a share"
        default: return "Choose a folder"
        }
    }

    @ViewBuilder
    private var locationStep: some View {
        Group {
            switch viewModel.locationLoad {
            case .idle, .loading:
                List { HStack { ProgressView(); Text("Loading…").foregroundStyle(palette.secondaryText) } }
            case .needsAuth, .badCredentials:
                List {
                    Section("Sign in") {
                        Text("This server needs a username and password. Go back and enter them.")
                            .foregroundStyle(palette.secondaryText)
                    }
                    manualShareSection
                }
            case .unreachable:
                List {
                    Section("Can’t connect") {
                        Text("Couldn’t connect. Check the address and network.")
                            .foregroundStyle(palette.secondaryText)
                        Button("Try Again") { retryLocation() }
                    }
                    if viewModel.selectedTransport == .nfs { manualShareSection }
                }
            case .failed(let message):
                List {
                    Section("Something went wrong") {
                        Text(message).foregroundStyle(palette.secondaryText)
                        Button("Try Again") { retryLocation() }
                    }
                    manualShareSection
                }
            case .loaded:
                loadedLocations
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let saveError {
                Label {
                    Text(verbatim: saveError)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            }
        }
    }

    private var loadedLocations: some View {
        List {
            if viewModel.showsCurrentFolder {
                Section {
                    if viewModel.canNavigateUp {
                        Button { viewModel.navigateUp() } label: {
                            Label("Up one level", systemImage: "arrow.up.backward")
                        }
                    }
                    Text(viewModel.currentPath)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(palette.secondaryText)
                    Button("Use This Folder") { viewModel.useCurrentFolder() }
                } header: {
                    Text("Folder")
                }
            }
            Section(viewModel.showsCurrentFolder ? "Or open a subfolder" : "Locations") {
                if viewModel.locations.isEmpty {
                    Text(viewModel.showsCurrentFolder ? "No subfolders here." : "Nothing here.")
                        .foregroundStyle(palette.secondaryText)
                } else {
                    ForEach(viewModel.locations) { item in
                        Button { viewModel.selectLocation(item) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: item.isBrowsable ? "folder.fill" : "externaldrive.fill")
                                    .foregroundStyle(palette.secondaryText)
                                Text(item.name)
                                Spacer()
                                Image(systemName: "chevron.forward").font(.footnote).foregroundStyle(palette.secondaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if viewModel.showsManualRootEntry {
                manualShareSection
            }
        }
    }

    @ViewBuilder
    private var manualShareSection: some View {
        if viewModel.selectedTransport == .nfs {
            Section("Enter export path") {
                TextField("/volume1/Media", text: $viewModel.manualShare).autocorrectionDisabled()
                Button("Browse Export") { viewModel.browseManualLocation() }
                    .disabled(viewModel.manualShare.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Use This Export") { viewModel.chooseNFSManualExport() }
                    .disabled(viewModel.manualShare.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else if viewModel.selectedTransport == .smb {
            Section("Enter share or folder path") {
                TextField("Share/Folder", text: $viewModel.manualShare).autocorrectionDisabled()
                Button("Browse") { viewModel.browseManualLocation() }
                    .disabled(viewModel.manualShare.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Use This Path") { viewModel.chooseSMBShare(viewModel.manualShare) }
                    .disabled(viewModel.manualShare.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func retryLocation() {
        viewModel.retryLocations()
    }

    private func formatFingerprint(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: - Step 5: coming soon

    private func comingSoonStep(_ kind: MediaShareTransportKind) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer.fill").font(.system(size: 48)).foregroundStyle(palette.secondaryText)
            Text("\(kind.badgeLabel) support is coming soon").font(.headline)
            Button("Back") { viewModel.backToConnect() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
#endif
