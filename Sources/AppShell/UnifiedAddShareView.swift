#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import ProviderShare

/// The one unified "Add a Media Share" screen for every transport, replacing the
/// SMB-only `AddShareView` and the separate `AddWebDAVShareView`. Presents:
/// a box-grouped, multi-transport "Detected automatically" list + "Enter an
/// address"; the single Connect form (Protocol → Address+Port → credentials); a
/// generic Verify screen; and the location picker. All logic is in
/// `UnifiedAddShareModel`; SMB/WebDAV use real backends, NFS/SFTP show a
/// coming-soon step.
struct UnifiedAddShareView: View {
    let isPageReady: Bool
    let onBack: () -> Void
    let onSMBConfigured: (ShareDraft) -> Void
    let onWebDAVConfigured: (WebDAVShareConfiguration) -> Void
    var onMediaShareConfigured: (MediaShareOnboardingResult) -> Void = { _ in }

    @State private var viewModel = UnifiedAddShareModel()
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case back, rescan
        case device(String), enterAddress
        case proto, address, port, portChip(Int)
        case authToggle, username, password, token, connect
        case approve, reject
        case location(String), manualShare, displayName, useFolder
        case comingSoonBack
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    switch viewModel.step {
                    case .chooseDevice: deviceStep
                    case .connect: connectStep
                    case .verifyTrust(let sha256): verifyStep(sha256)
                    case .pickLocation: locationStep
                    case .comingSoon(let kind): comingSoonStep(kind)
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 48)
                .padding(.vertical, 32)
                .padding(.top, proxy.safeAreaInsets.top)
                .padding(.bottom, proxy.safeAreaInsets.bottom)
            }
            .scrollClipDisabled()
            .ignoresSafeArea(.container, edges: .vertical)
        }
        .onExitCommand(perform: handleExit)
        .onAppear {
            viewModel.onSMBConfigured = onSMBConfigured
            viewModel.onWebDAVConfigured = onWebDAVConfigured
            viewModel.onMediaShareConfigured = onMediaShareConfigured
            if isPageReady { viewModel.startScan() }
            focus = .back
        }
        .onChange(of: isPageReady) { _, ready in
            if ready { viewModel.startScan() } else { viewModel.stopScan() }
        }
        .onChange(of: viewModel.step) { _, _ in focus = defaultFocus() }
        .onDisappear { viewModel.stopScan() }
    }

    private func handleExit() {
        switch viewModel.step {
        case .chooseDevice: onBack()
        case .connect: viewModel.backToDevices()
        case .verifyTrust: viewModel.rejectTrust()
        case .pickLocation: viewModel.backToConnect()
        case .comingSoon: viewModel.backToConnect()
        }
    }

    private func defaultFocus() -> Field {
        switch viewModel.step {
        case .chooseDevice: return .back
        case .connect: return .proto
        case .verifyTrust: return .approve
        case .pickLocation: return .useFolder
        case .comingSoon: return .comingSoonBack
        }
    }

    // MARK: - Step 1: choose device

    private var deviceStep: some View {
        Group {
            headerRow(title: "Add a Media Share", back: onBack) {
                Button { viewModel.startScan() } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .focused($focus, equals: .rescan)
            }

            Panel(title: "Detected automatically", accessory: {
                if viewModel.scanning { ProgressView() }
            }) {
                VStack(spacing: 14) {
                    if viewModel.boxes.isEmpty {
                        placeholder(viewModel.scanning ? "Searching…" : "Nothing detected yet.")
                    } else {
                        ForEach(viewModel.boxes) { box in
                            Button { viewModel.openConnect(for: box) } label: {
                                deviceRow(box)
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
                            .focused($focus, equals: .device(box.id))
                        }
                    }
                }
            }

            manualEntryCard
        }
    }

    private var manualEntryCard: some View {
        Button { viewModel.openManualConnect() } label: {
            HStack(spacing: 20) {
                Image(systemName: "keyboard")
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.secondary)
                Text("Enter an address manually").font(.headline)
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
        .focused($focus, equals: .enterAddress)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func deviceRow(_ box: DiscoveredMediaShareBox) -> some View {
        let protocols = box.doors.map { $0.transport.badgeLabel }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 20) {
            Image(systemName: "externaldrive.connected.to.line.below.fill")
                .font(.system(size: 32)).frame(width: 44, height: 44).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(box.displayName).font(.headline)
                Text("\(box.host) · \(protocols) detected").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14).padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    // MARK: - Step 2: connect form

    private var connectStep: some View {
        Group {
            headerRow(
                title: "",
                showsTitle: false,
                back: { viewModel.backToDevices() }
            ) { EmptyView() }

            Panel(title: "Protocol") {
                Menu {
                    ForEach(MediaShareTransportCatalog.preferenceOrder, id: \.self) { kind in
                        Button {
                            viewModel.applyTransport(kind)
                        } label: {
                            if kind == viewModel.selectedTransport {
                                Label(protocolLabel(kind), systemImage: "checkmark")
                            } else {
                                Text(protocolLabel(kind))
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(protocolLabel(viewModel.selectedTransport))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focused($focus, equals: .proto)
            }

            Panel(title: "Address") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("e.g. 192.168.1.100 or mynas.local", text: $viewModel.address)
                                .textContentType(.URL).autocorrectionDisabled().keyboardType(.URL)
                                .focused($focus, equals: .address)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Port", text: $viewModel.portText)
                                .keyboardType(.numberPad)
                                .frame(width: 200)
                                .focused($focus, equals: .port)
                        }
                    }
                    portChips
                }
            }

            credentialPanel

            if let error = viewModel.connectError {
                InlineErrorMessage(LocalizedStringKey(error), systemImage: "exclamationmark.triangle")
            }
            Button {
                viewModel.connect()
            } label: {
                if viewModel.detecting { ProgressView() } else { Text("Connect") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canConnect || viewModel.detecting)
            .focused($focus, equals: .connect)
        }
    }

    @ViewBuilder
    private var portChips: some View {
        let kind = viewModel.selectedTransport
        let ports = viewModel.detectedPorts(for: kind)
        if ports.count > 1 {
            HStack(spacing: 10) {
                Text("Detected:").font(.footnote).foregroundStyle(.secondary)
                ForEach(ports, id: \.self) { p in
                    Button {
                        viewModel.portText = String(p)
                    } label: {
                        Text(verbatim: ":\(p)")
                    }
                        .buttonStyle(.bordered)
                        .focused($focus, equals: .portChip(p))
                }
            }
        }
    }

    @ViewBuilder
    private var credentialPanel: some View {
        let kind = viewModel.selectedTransport
        if let descriptor = viewModel.descriptor(kind) {
            if descriptor.authModes.isEmpty {
                EmptyView() // NFS: no sign-in
            } else {
                Panel(title: "Sign in") {
                    VStack(alignment: .leading, spacing: 18) {
                        if descriptor.authModes.contains(.token) {
                            Picker("Method", selection: $viewModel.authMode) {
                                Text("Username & password").tag(UnifiedAddShareModel.AuthMode.usernamePassword)
                                Text("Token").tag(UnifiedAddShareModel.AuthMode.token)
                            }
                            .pickerStyle(.segmented)
                            .focused($focus, equals: .authToggle)
                        }
                        if viewModel.authMode == .token {
                            SecureField("Token", text: $viewModel.token)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .token)
                        } else {
                            TextField(descriptor.allowsBlankGuest ? "Username (optional)" : "Username", text: $viewModel.username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .username)
                            SecureField(descriptor.allowsBlankGuest ? "Password (optional)" : "Password", text: $viewModel.password)
                                .textContentType(.password)
                                .focused($focus, equals: .password)
                        }
                        if let warning = viewModel.plaintextWarning {
                            Label(
                                warning,
                                systemImage: "info.circle"
                            )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
                    }
                }
            }
        }
    }

    private func protocolLabel(_ kind: MediaShareTransportKind) -> String {
        let detected = viewModel.detectedDoors.contains { $0.transport == kind }
        return detected ? "\(kind.badgeLabel) (detected)" : kind.badgeLabel
    }

    // MARK: - Step 3: verify trust

    private func verifyStep(_ sha256: Data) -> some View {
        let isHostKey = viewModel.selectedTransport == .sftp
        return Group {
            headerRow(
                title: isHostKey ? "Verify Host Key" : "Verify Certificate",
                back: { viewModel.rejectTrust() }
            ) { EmptyView() }
            Panel(title: isHostKey ? "SSH Host Key SHA-256" : "Certificate SHA-256") {
                Text(formatFingerprint(sha256))
                    .font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(isHostKey
                ? "Only approve if this matches your server’s SSH host key. Approving pins this exact key; a change requires re-approval."
                : "Only approve if this matches your server. Approving pins this exact certificate; a change requires re-approval.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Button("Approve & Continue") { viewModel.approveTrust() }
                    .buttonStyle(.borderedProminent)
                    .focused($focus, equals: .approve)
                Button("Cancel") { viewModel.rejectTrust() }
                    .buttonStyle(.bordered)
                    .focused($focus, equals: .reject)
            }
        }
    }

    // MARK: - Step 4: pick location

    private var locationStep: some View {
        Group {
            headerRow(title: LocalizedStringKey(locationTitle), back: { viewModel.backToConnect() }) { EmptyView() }
            switch viewModel.locationLoad {
            case .idle, .loading:
                Panel(title: "Locations") { placeholder("Loading…") }
            case .needsAuth, .badCredentials:
                Panel(title: "Sign in") {
                    Text("This server needs a username and password. Go back and enter them.")
                        .foregroundStyle(.secondary)
                }
                manualSharePanel
            case .unreachable:
                Panel(title: "Can’t connect") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Couldn’t connect. Check the address and network.").foregroundStyle(.secondary)
                        Button("Try again") { retryLocation() }.buttonStyle(.borderedProminent)
                    }
                }
            case .failed(let message):
                Panel(title: "Something went wrong") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(LocalizedStringKey(message)).foregroundStyle(.secondary)
                        Button("Try again") { retryLocation() }.buttonStyle(.borderedProminent)
                    }
                }
                manualSharePanel
            case .loaded:
                loadedLocations
            }
        }
    }

    private var locationTitle: String {
        guard let d = viewModel.descriptor(viewModel.selectedTransport) else { return "Choose" }
        return d.listsSharesNotFolders ? "Choose a share" : "Choose a folder"
    }

    @ViewBuilder
    private var loadedLocations: some View {
        if viewModel.isPathEntryTransport {
            pathEntryConfirm
        } else {
            browsableLocations
        }
    }

    /// The confirm-and-name panel for NFS/SFTP/FTP: the typed root path is shown
    /// for review (no live folder list), then named and saved.
    @ViewBuilder
    private var pathEntryConfirm: some View {
        Panel(title: "Folder") {
            HStack(spacing: 16) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(viewModel.confirmedPath).font(.headline)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        Text("Plozz will scan this folder for media. You can type a deeper path in the address to narrow it.")
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Panel(title: "Display name (optional)") {
            TextField("Display name", text: $viewModel.displayName)
                .autocorrectionDisabled().focused($focus, equals: .displayName)
        }
        Button("Add Share") { viewModel.chooseFilesystemRoot() }
            .buttonStyle(.borderedProminent)
            .focused($focus, equals: .useFolder)
    }

    @ViewBuilder
    private var browsableLocations: some View {
        let isWebDAV = viewModel.selectedTransport == .webDAV
        if isWebDAV && viewModel.currentPath != "/" {
            Button {
                Task { await viewModel.loadWebDAVFolders(path: parentPath(of: viewModel.currentPath)) }
            } label: { Label("Up one level", systemImage: "arrow.up.left") }
            .buttonStyle(.bordered)
        }
        Panel(title: "Locations") {
            if viewModel.locations.isEmpty {
                placeholder("Nothing here.")
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.locations) { item in
                        Button { selectLocation(item) } label: {
                            HStack(spacing: 16) {
                                Image(systemName: item.isBrowsable ? "folder.fill" : "externaldrive.fill")
                                    .foregroundStyle(.secondary)
                                Text(item.name).font(.headline)
                                Spacer(minLength: 12)
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle()).padding(.vertical, 10).padding(.horizontal, 12)
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
                        .focused($focus, equals: .location(item.path))
                    }
                }
            }
        }
        if isWebDAV {
            Panel(title: "Display name (optional)") {
                TextField("Display name", text: $viewModel.displayName)
                    .autocorrectionDisabled().focused($focus, equals: .displayName)
            }
            Button("Use This Folder") { viewModel.chooseWebDAVFolder(viewModel.currentPath) }
                .buttonStyle(.borderedProminent)
                .focused($focus, equals: .useFolder)
        } else {
            Panel(title: "Display name (optional)") {
                TextField("Display name", text: $viewModel.displayName)
                    .autocorrectionDisabled().focused($focus, equals: .displayName)
            }
        }
    }

    private var manualSharePanel: some View {
        Panel(title: "Enter share name") {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Share name", text: $viewModel.manualShare)
                    .autocorrectionDisabled().focused($focus, equals: .manualShare)
                Button("Add Share") { viewModel.chooseSMBShare(viewModel.manualShare) }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.manualShare.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func selectLocation(_ item: UnifiedAddShareModel.LocationItem) {
        if item.isBrowsable {
            Task { await viewModel.loadWebDAVFolders(path: item.path) }
        } else {
            viewModel.chooseSMBShare(item.path)
        }
    }

    private func retryLocation() {
        if viewModel.selectedTransport == .webDAV {
            Task { await viewModel.loadWebDAVFolders(path: viewModel.currentPath) }
        } else {
            viewModel.loadSMBShares()
        }
    }

    // MARK: - Coming soon (dummy transports)

    private func comingSoonStep(_ kind: MediaShareTransportKind) -> some View {
        Group {
            headerRow(title: LocalizedStringKey("\(kind.badgeLabel) coming soon"), back: { viewModel.backToConnect() }) { EmptyView() }
            Panel(title: kind.badgeLabel) {
                Text("\(kind.badgeLabel) support is on the way. This device was detected, but Plozz can’t connect over \(kind.badgeLabel) just yet.")
                    .foregroundStyle(.secondary)
            }
            Button("Back") { viewModel.backToConnect() }
                .buttonStyle(.bordered)
                .focused($focus, equals: .comingSoonBack)
        }
    }

    // MARK: - Shared pieces

    private func headerRow<Trailing: View>(
        title: LocalizedStringKey,
        showsTitle: Bool = true,
        back: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.backward") }
                    .buttonStyle(.bordered)
                    .focused($focus, equals: .back)
                Spacer(minLength: 24)
                trailing()
            }
            if showsTitle {
                OnboardingHeader(title, subtitle: "").frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 24)
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8).padding(.horizontal, 12)
    }

    private func parentPath(of path: String) -> String {
        var trimmed = path
        if trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/"), slash != trimmed.startIndex else { return "/" }
        return String(trimmed[..<slash])
    }

    private func formatFingerprint(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// A titled `.ultraThinMaterial` card matching the onboarding style.
private struct Panel<Content: View, Accessory: View>: View {
    var title: String
    var accessory: () -> Accessory
    var content: () -> Content

    init(
        title: String,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).textCase(.uppercase)
                    .tracking(1.0).foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
#endif
