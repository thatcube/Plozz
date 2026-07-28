#if canImport(SwiftUI)
import SwiftUI
import FeatureShareOnboarding
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
            headerRow(title: Text("Add a Media Share"), back: onBack) {
                Button { viewModel.startScan() } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .focused($focus, equals: .rescan)
            }

            Panel(title: Text("Detected automatically"), accessory: {
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
                    .plozzForeground(.secondary)
                Text("Enter an address manually").font(.headline)
                Spacer(minLength: 12)
                Image(systemName: "chevron.forward").plozzForeground(.tertiary)
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
                .font(.system(size: 32)).frame(width: 44, height: 44).plozzForeground(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(box.displayName).font(.headline)
                Text("\(box.host) · \(protocols) detected").font(.subheadline).plozzForeground(.secondary)
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
                title: Text(verbatim: ""),
                showsTitle: false,
                back: { viewModel.backToDevices() }
            ) { EmptyView() }
            .focusSection()

            Panel(title: nil) {
                VStack(alignment: .leading, spacing: 18) {
                    LabeledFormRow("Protocol") {
                        Menu {
                            ForEach(MediaShareTransportCatalog.preferenceOrder, id: \.self) { kind in
                                Button {
                                    viewModel.applyTransport(kind)
                                } label: {
                                    if kind == viewModel.selectedTransport {
                                        Label { protocolLabel(kind) } icon: { Image(systemName: "checkmark") }
                                    } else {
                                        protocolLabel(kind)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                protocolLabel(viewModel.selectedTransport)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.footnote).plozzForeground(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .focused($focus, equals: .proto)
                    }
                    LabeledFormRow("Address") {
                        HStack(alignment: .center, spacing: 16) {
                            TextField("e.g. 192.168.1.100 or mynas.local", text: $viewModel.address)
                                .textContentType(.URL).autocorrectionDisabled().keyboardType(.URL)
                                .focused($focus, equals: .address)
                            TextField("Port", text: $viewModel.portText)
                                .keyboardType(.numberPad)
                                .frame(width: 200)
                                .focused($focus, equals: .port)
                        }
                    }
                    portChips
                }
            }
            .focusSection()

            credentialPanel

            Panel(title: nil) {
                LabeledFormRow("Nickname") {
                    TextField("e.g. Living Room NAS", text: $viewModel.displayName)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .displayName)
                }
            }
            .focusSection()

            if let error = viewModel.connectError {
                InlineErrorMessage(Text(error), systemImage: "exclamationmark.triangle")
            }
            Button {
                viewModel.connect()
            } label: {
                if viewModel.detecting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Connect").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canConnect || viewModel.detecting)
            .focused($focus, equals: .connect)
            .focusSection()
            .padding(.top, 8)
        }
    }

    /// The Sign-in card — its own section because it's the dynamic part of the
    /// form (NFS shows nothing, WebDAV adds a username/token method toggle, the
    /// rest are username/password). The method toggle spans the full card width;
    /// the credential fields use the same left-label rows as the rest of the form.
    @ViewBuilder
    private var credentialPanel: some View {
        let kind = viewModel.selectedTransport
        if let descriptor = viewModel.descriptor(kind), !descriptor.authModes.isEmpty {
            Panel(title: nil) {
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
                        LabeledFormRow("Token") {
                            SecureField("Token", text: $viewModel.token)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .token)
                        }
                    } else {
                        LabeledFormRow("Username") {
                            TextField(descriptor.allowsBlankGuest ? "optional — blank for guest" : "required", text: $viewModel.username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .username)
                        }
                        LabeledFormRow("Password") {
                            SecureField(descriptor.allowsBlankGuest ? "optional" : "required", text: $viewModel.password)
                                .textContentType(.password)
                                .focused($focus, equals: .password)
                        }
                    }
                    if let warning = viewModel.plaintextWarning {
                        Label(warning, systemImage: "info.circle")
                            .font(.footnote)
                            .plozzForeground(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .focusSection()
        }
    }

    @ViewBuilder
    private var portChips: some View {
        let kind = viewModel.selectedTransport
        let ports = viewModel.detectedPorts(for: kind)
        if ports.count > 1 {
            HStack(spacing: 10) {
                Text("Detected:").font(.footnote).plozzForeground(.secondary)
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

    private func protocolLabel(_ kind: MediaShareTransportKind) -> Text {
        let detected = viewModel.detectedDoors.contains { $0.transport == kind }
        // The protocol name is a technical identifier; only the "(detected)"
        // suffix is copy, so it is interpolated into a translatable sentence.
        return detected ? Text("\(kind.badgeLabel) (detected)") : Text(verbatim: kind.badgeLabel)
    }

    // MARK: - Step 3: verify trust

    private func verifyStep(_ sha256: Data) -> some View {
        let isHostKey = viewModel.selectedTransport == .sftp
        return Group {
            headerRow(
                title: isHostKey ? Text("Verify Host Key") : Text("Verify Certificate"),
                back: { viewModel.rejectTrust() }
            ) { EmptyView() }
            Panel(title: isHostKey ? Text("SSH Host Key SHA-256") : Text("Certificate SHA-256")) {
                Text(formatFingerprint(sha256))
                    .font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(isHostKey
                ? "Only approve if this matches your server’s SSH host key. Approving pins this exact key; a change requires re-approval."
                : "Only approve if this matches your server. Approving pins this exact certificate; a change requires re-approval.")
                .font(.footnote).plozzForeground(.secondary)
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
            headerRow(title: Text(locationTitle), back: { viewModel.backToConnect() }) { EmptyView() }
            switch viewModel.locationLoad {
            case .idle, .loading:
                Panel(title: Text("Locations")) { placeholder("Loading…") }
            case .needsAuth, .badCredentials:
                Panel(title: Text("Sign in")) {
                    Text("This server needs a username and password. Go back and enter them.")
                        .plozzForeground(.secondary)
                }
                manualSharePanel
            case .unreachable:
                Panel(title: Text("Can’t connect")) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Couldn’t connect. Check the address and network.").plozzForeground(.secondary)
                        Button("Try again") { retryLocation() }.buttonStyle(.borderedProminent)
                    }
                }
                if viewModel.selectedTransport == .nfs { manualSharePanel }
            case .failed(let message):
                Panel(title: Text("Something went wrong")) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(message).plozzForeground(.secondary)
                        Button("Try again") { retryLocation() }.buttonStyle(.borderedProminent)
                    }
                }
                manualSharePanel
            case .loaded:
                loadedLocations
            }
        }
    }

    private var locationTitle: LocalizedStringResource {
        switch viewModel.selectedTransport {
        case .nfs: return "Choose an export"
        case .smb: return "Choose a share"
        default: return "Choose a folder"
        }
    }

    @ViewBuilder
    private var loadedLocations: some View {
        browsableLocations
    }

    @ViewBuilder
    private var browsableLocations: some View {
        let isDrillable = viewModel.isDrillableTransport
        if isDrillable {
            if viewModel.currentPath != "/" {
                Button {
                    loadFolders(path: parentPath(of: viewModel.currentPath))
                } label: { Label("Up one level", systemImage: "arrow.up.backward") }
                .buttonStyle(.bordered)
            }
            // Primary action pinned ABOVE the (bounded, scrollable) list, so
            // confirming the folder you're looking inside never requires scrolling
            // past its contents. The path gets its own full-width line and wraps
            // rather than truncating — a deep path stays fully readable.
            Panel(title: Text("Folder")) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(viewModel.currentPath)
                        .font(.system(.body, design: .monospaced))
                        .plozzForeground(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Use This Folder") { useCurrentFolder() }
                        .buttonStyle(.borderedProminent)
                        .focused($focus, equals: .useFolder)
                }
            }
        }
        Panel(title: isDrillable ? Text("Or open a subfolder") : Text("Locations")) {
            if viewModel.locations.isEmpty {
                placeholder(isDrillable ? "No subfolders here." : "Nothing here.")
            } else {
                FadingScrollView(maxHeight: 620) {
                    VStack(spacing: 12) {
                        ForEach(viewModel.locations) { item in
                            Button { selectLocation(item) } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: item.isBrowsable ? "folder.fill" : "externaldrive.fill")
                                        .plozzForeground(.secondary)
                                    Text(item.name).font(.headline)
                                    Spacer(minLength: 12)
                                    Image(systemName: "chevron.forward").plozzForeground(.tertiary)
                                }
                                .contentShape(Rectangle()).padding(.vertical, 10).padding(.horizontal, 12)
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
                            .focused($focus, equals: .location(item.path))
                        }
                    }
                }
            }
        }
    }

    private func loadFolders(path: String) {
        switch viewModel.selectedTransport {
        case .sftp:
            Task { await viewModel.loadSFTPFolders(path: path) }
        case .ftp:
            Task { await viewModel.loadFTPFolders(path: path) }
        default:
            Task { await viewModel.loadWebDAVFolders(path: path) }
        }
    }

    private func useCurrentFolder() {
        switch viewModel.selectedTransport {
        case .sftp, .ftp:
            viewModel.chooseFilesystemRoot()
        default:
            viewModel.chooseWebDAVFolder(viewModel.currentPath)
        }
    }

    private var manualSharePanel: some View {
        Group {
            if viewModel.selectedTransport == .nfs {
                Panel(title: Text("Enter export path")) {
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("/volume1/Media", text: $viewModel.manualShare)
                            .autocorrectionDisabled().focused($focus, equals: .manualShare)
                        Button("Add Share") { viewModel.chooseNFSManualExport() }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.manualShare.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } else {
                Panel(title: Text("Enter share name")) {
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("Share name", text: $viewModel.manualShare)
                            .autocorrectionDisabled().focused($focus, equals: .manualShare)
                        Button("Add Share") { viewModel.chooseSMBShare(viewModel.manualShare) }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.manualShare.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func selectLocation(_ item: UnifiedAddShareModel.LocationItem) {
        if item.isBrowsable {
            loadFolders(path: item.path)
        } else {
            switch viewModel.selectedTransport {
            case .nfs:
                viewModel.chooseNFSExport(item.path)
            default:
                viewModel.chooseSMBShare(item.path)
            }
        }
    }

    private func retryLocation() {
        switch viewModel.selectedTransport {
        case .webDAV:
            Task { await viewModel.loadWebDAVFolders(path: viewModel.currentPath) }
        case .sftp:
            Task { await viewModel.loadSFTPFolders(path: viewModel.currentPath) }
        case .ftp:
            Task { await viewModel.loadFTPFolders(path: viewModel.currentPath) }
        case .nfs:
            Task { await viewModel.loadNFSExports() }
        default:
            viewModel.loadSMBShares()
        }
    }

    // MARK: - Coming soon (dummy transports)

    private func comingSoonStep(_ kind: MediaShareTransportKind) -> some View {
        Group {
            headerRow(title: Text("\(kind.badgeLabel) coming soon"), back: { viewModel.backToConnect() }) { EmptyView() }
            Panel(title: Text(verbatim: kind.badgeLabel)) {
                Text("\(kind.badgeLabel) support is on the way. This device was detected, but Plozz can’t connect over \(kind.badgeLabel) just yet.")
                    .plozzForeground(.secondary)
            }
            Button("Back") { viewModel.backToConnect() }
                .buttonStyle(.bordered)
                .focused($focus, equals: .comingSoonBack)
        }
    }

    // MARK: - Shared pieces

    private func headerRow<Trailing: View>(
        title: Text,
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
                OnboardingHeader(title).frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 24)
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text).plozzForeground(.secondary)
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
    /// `nil` renders no header (previously spelled as an empty string).
    var title: Text?
    var accessory: () -> Accessory
    var content: () -> Content

    init(
        title: Text?,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                HStack {
                    title.font(.subheadline.weight(.semibold)).textCase(.uppercase)
                        .tracking(1.0).plozzForeground(.secondary)
                    Spacer()
                    accessory()
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// A compact form row: a fixed-width label on the left and its control filling the
/// rest of the width. Keeps the connect form short (label + control share a line)
/// while the control still stretches to the container's right edge, so tvOS
/// up-focus from the first control can still reach the header's Back button.
private struct LabeledFormRow<Control: View>: View {
    let label: LocalizedStringResource
    let control: () -> Control

    init(_ label: LocalizedStringResource, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            // The width is fixed so every row's control lines up, so a longer
            // translation has to degrade INSIDE it rather than reflow the column.
            // Without these it wrapped a word into a stack of syllables, which is
            // what Spanish did to the settings switch's "Activado".
            Text(label)
                .plozzForeground(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(width: 150, alignment: .leading)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
