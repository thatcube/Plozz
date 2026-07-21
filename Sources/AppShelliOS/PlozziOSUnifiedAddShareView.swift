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
    @State private var viewModel = UnifiedAddShareModel()
    @State private var wired = false

    var body: some View {
        NavigationStack {
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
                    Button(viewModel.step == .chooseDevice ? "Cancel" : "Back", action: back)
                }
            }
        }
        .onAppear {
            if !wired {
                wired = true
                viewModel.onSMBConfigured = { draft in
                    _ = appModel.addSMBShare(host: draft.host, port: draft.port, share: draft.share,
                                             username: draft.username, password: draft.password,
                                             displayName: draft.displayName)
                    dismiss()
                }
                viewModel.onWebDAVConfigured = { config in
                    _ = appModel.addWebDAVShare(baseURL: config.baseURL, auth: config.auth,
                                                trustPin: config.trustPin, displayName: config.displayName)
                    dismiss()
                }
                viewModel.onMediaShareConfigured = { result in
                    switch result {
                    case let .nfs(c):
                        _ = appModel.addNFSShare(host: c.host, port: c.port,
                                                 exportPath: c.exportPath, displayName: c.displayName)
                    case let .sftp(c):
                        _ = appModel.addSFTPShare(host: c.host, port: c.port, path: c.path,
                                                  username: c.username, password: c.password,
                                                  hostKeyPin: c.hostKeyPin, displayName: c.displayName)
                    case let .ftp(c):
                        _ = appModel.addFTPShare(baseURL: c.baseURL, auth: c.auth, displayName: c.displayName)
                    }
                    dismiss()
                }
            }
            viewModel.startScan()
        }
        .onDisappear { viewModel.stopScan() }
    }

    private var stepTitle: String {
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
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(palette.secondaryText)
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
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(palette.secondaryText)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Step 2: connect

    private var connectStep: some View {
        Form {
            Section {
                Picker("Protocol", selection: $viewModel.selectedTransport) {
                    ForEach(MediaShareTransportCatalog.preferenceOrder, id: \.self) { kind in
                        Text(protocolLabel(kind)).tag(kind)
                    }
                }
                .onChange(of: viewModel.selectedTransport) { _, kind in
                    viewModel.applyTransport(kind)
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

    private func protocolLabel(_ kind: MediaShareTransportKind) -> String {
        viewModel.detectedDoors.contains { $0.transport == kind }
            ? "\(kind.badgeLabel) (detected)" : kind.badgeLabel
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

    private var locationTitle: String {
        switch viewModel.selectedTransport {
        case .nfs: return "Choose an export"
        case .smb: return "Choose a share"
        default: return "Choose a folder"
        }
    }

    @ViewBuilder
    private var locationStep: some View {
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

    private var loadedLocations: some View {
        List {
            if viewModel.isDrillableTransport {
                Section {
                    if viewModel.currentPath != "/" {
                        Button { loadFolders(path: parentPath(of: viewModel.currentPath)) } label: {
                            Label("Up one level", systemImage: "arrow.up.left")
                        }
                    }
                    Text(viewModel.currentPath)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(palette.secondaryText)
                    Button("Use This Folder") { useCurrentFolder() }
                } header: {
                    Text("Folder")
                }
            }
            Section(viewModel.isDrillableTransport ? "Or open a subfolder" : "Locations") {
                if viewModel.locations.isEmpty {
                    Text(viewModel.isDrillableTransport ? "No subfolders here." : "Nothing here.")
                        .foregroundStyle(palette.secondaryText)
                } else {
                    ForEach(viewModel.locations) { item in
                        Button { selectLocation(item) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: item.isBrowsable ? "folder.fill" : "externaldrive.fill")
                                    .foregroundStyle(palette.secondaryText)
                                Text(item.name)
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(palette.secondaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var manualShareSection: some View {
        if viewModel.selectedTransport == .nfs {
            Section("Enter export path") {
                TextField("/volume1/Media", text: $viewModel.manualShare).autocorrectionDisabled()
                Button("Add Share") { viewModel.chooseNFSManualExport() }
                    .disabled(viewModel.manualShare.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
            Section("Enter share name") {
                TextField("Share name", text: $viewModel.manualShare).autocorrectionDisabled()
                Button("Add Share") { viewModel.chooseSMBShare(viewModel.manualShare) }
                    .disabled(viewModel.manualShare.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func selectLocation(_ item: UnifiedAddShareModel.LocationItem) {
        if item.isBrowsable {
            loadFolders(path: item.path)
        } else if viewModel.selectedTransport == .nfs {
            viewModel.chooseNFSExport(item.path)
        } else {
            viewModel.chooseSMBShare(item.path)
        }
    }

    private func useCurrentFolder() {
        switch viewModel.selectedTransport {
        case .sftp, .ftp: viewModel.chooseFilesystemRoot()
        default: viewModel.chooseWebDAVFolder(viewModel.currentPath)
        }
    }

    private func loadFolders(path: String) {
        switch viewModel.selectedTransport {
        case .sftp: Task { await viewModel.loadSFTPFolders(path: path) }
        case .ftp: Task { await viewModel.loadFTPFolders(path: path) }
        default: Task { await viewModel.loadWebDAVFolders(path: path) }
        }
    }

    private func retryLocation() {
        switch viewModel.selectedTransport {
        case .nfs: Task { await viewModel.loadNFSExports() }
        case .sftp: Task { await viewModel.loadSFTPFolders(path: "/") }
        case .ftp: Task { await viewModel.loadFTPFolders(path: "/") }
        case .webDAV: Task { await viewModel.loadWebDAVFolders(path: "/") }
        case .smb: viewModel.loadSMBShares()
        }
    }

    private func parentPath(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let idx = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<idx])
        return parent.isEmpty ? "/" : parent
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
