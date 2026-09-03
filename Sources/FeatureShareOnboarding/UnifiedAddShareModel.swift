import Foundation
import Observation
import AppRuntime
import CoreModels
import CoreNetworking
import FeatureAuthCore
import ProviderShare
import MediaTransportHTTP
import MediaTransportWebDAV
import MediaTransportSFTP
import MediaTransportFTP
import MediaTransportNFS

/// The finished configuration for an NFS export, handed back to
/// `AppState.didConfigureNFSShare`. The export remains the mount boundary while
/// `subpath` scopes the library below it.
public struct NFSShareConfiguration: Equatable {
    public let host: String
    public let port: Int?
    public let exportPath: String
    public let subpath: String
    public let displayName: String
}

/// The finished configuration for an SFTP share, handed back to
/// `AppState.didConfigureSFTPShare`. Carries the host key captured (and pinned)
/// during onboarding — the vault mandates it.
public struct SFTPShareConfiguration: Equatable {
    public let host: String
    public let port: Int?
    public let path: String
    public let username: String
    public let password: String
    public let hostKeyPin: SHA256Fingerprint
    public let displayName: String
}

/// The finished configuration for an FTP/FTPS share, handed back to
/// `AppState.didConfigureFTPShare`. `baseURL` carries the real scheme (`ftp` /
/// `ftps`).
public struct FTPShareConfiguration: Equatable {
    public let baseURL: URL
    public let auth: MediaShareFTPAuth
    public let trustPin: SHA256Fingerprint?
    public let displayName: String
}

/// A completed add-a-share result for the credential-envelope transports the
/// unified flow drives through one callback (NFS/SFTP/FTP), keeping SMB and
/// WebDAV on their existing dedicated callbacks.
public enum MediaShareOnboardingResult: Equatable {
    case nfs(NFSShareConfiguration)
    case sftp(SFTPShareConfiguration)
    case ftp(FTPShareConfiguration)
}


/// Drives the ONE unified "Add a Media Share" flow for every transport, as
/// approved in `docs/discovery-ux-proposal.md`:
///
///  1. **Choose device** — devices discovered on the LAN (all transports, grouped
///     per box, with a curated port sweep filling in non-advertised doors), plus
///     an "enter an address" path.
///  2. **Connect** — one form: Protocol → Address + Port → Username/Password
///     (blank = guest where allowed; WebDAV also offers a Token toggle). Driven by
///     the `TransportOnboardingDescriptor`.
///  3. **Verify** — a generic TOFU fingerprint screen when the descriptor needs a
///     pin (WebDAV self-signed TLS today).
///  4. **Pick location** — choose an SMB share or NFS export, then browse folders
///     below it; WebDAV/SFTP/FTP browse directly from their entered root.
///  5. **Save** — hands back the existing `ShareDraft` / `WebDAVShareConfiguration`
///     so `AppState` persistence is unchanged.
///
/// Every implemented transport uses its production transport semantics through
/// an injectable onboarding probe, so both platform shells share one state machine.
@MainActor
@Observable
public final class UnifiedAddShareModel {

    public enum Step: Equatable {
        case chooseDevice
        case connect
        case verifyTrust(sha256: Data)
        case pickLocation
        case comingSoon(MediaShareTransportKind)
    }

    /// A credential control mode on the Connect form.
    public enum AuthMode: Equatable { case usernamePassword, token }

    /// One selectable root or folder at the pick-location step.
    public struct LocationItem: Identifiable, Equatable {
        public let name: String
        public let path: String
        public let isBrowsable: Bool
        public var id: String { path }
    }

    public enum LocationLoad: Equatable {
        case idle, loading, loaded
        case needsAuth, badCredentials, unreachable
        case failed(LocalizedStringResource)
    }

    // MARK: Discovery
    public private(set) var boxes: [DiscoveredMediaShareBox] = []
    public private(set) var scanning = false

    // MARK: Step
    public private(set) var step: Step = .chooseDevice

    // MARK: Connect form
    /// The chosen transport on the Connect form. Always a concrete protocol —
    /// there is no "auto-detect". Defaults to a sensible protocol and is set to
    /// the best detected door when a device is opened.
    public var selectedTransport: MediaShareTransportKind = .smb
    public var address = ""
    public var portText = ""
    public var username = ""
    public var password = ""
    public var token = ""
    public var authMode: AuthMode = .usernamePassword
    public private(set) var detecting = false
    public private(set) var connectError: LocalizedStringResource?
    /// Doors detected for the box currently being connected (for the Protocol
    /// dropdown's "Detected" group and per-door port prefill).
    public private(set) var detectedDoors: [DiscoveredMediaShareBox.Door] = []

    // MARK: Location
    public private(set) var locations: [LocationItem] = []
    public private(set) var locationLoad: LocationLoad = .idle
    public private(set) var currentPath = "/"
    public var manualShare = ""
    public var displayName = ""

    // Resolved connection for the active attempt.
    private var resolvedHost = ""
    private var resolvedPort: Int?
    /// Known WebDAV scheme from Bonjour, the protocol-confirming sweep, an
    /// explicit manual URL, or scheme probing.
    private(set) var webDAVScheme: String?
    private var webDAVSchemePort: Int?
    private var trust: WebDAVOnboardingTrust = .system
    private var approvedPin: Data?

    // Outputs
    public var onSMBConfigured: (ShareDraft) -> Void = { _ in }
    public var onWebDAVConfigured: (WebDAVShareConfiguration) -> Void = { _ in }
    /// The credential-envelope transports (NFS/SFTP/FTP) report through one
    /// callback; SMB/WebDAV keep their dedicated ones above.
    public var onMediaShareConfigured: (MediaShareOnboardingResult) -> Void = { _ in }

    private let discovery: BonjourServiceDiscovery
    private let sweeper = MediaSharePortSweeper()
    private let serviceProbe: any MediaShareServiceProbing
    private let smbProbe: any SMBOnboardingProbing
    private let webDAVProbe: any WebDAVOnboardingProbing
    private let sftpProbe: any SFTPOnboardingProbing
    private let ftpProbe: any FTPOnboardingProbing
    private let nfsProbe: any NFSOnboardingProbing
    private var scanTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var sweptHosts = Set<String>()
    /// Every detected door per host, keeping ALL ports (advertised + swept) so a
    /// specific configured port like WebDAV :8384 is never lost to de-duplication.
    private var fullDoorsByHost: [String: [DiscoveredMediaShareBox.Door]] = [:]

    private struct BrowseContext: Equatable {
        var confirmedPath = "/"
        var selectedSMBShare: String?
        var selectedNFSExport: String?
        var minimumPath = "/"
        var canReturnToRootList = false
    }

    private var browseContext = BrowseContext()
    private(set) var confirmedPath: String {
        get { browseContext.confirmedPath }
        set { browseContext.confirmedPath = newValue }
    }
    private var selectedSMBShare: String? {
        get { browseContext.selectedSMBShare }
        set { browseContext.selectedSMBShare = newValue }
    }
    private var selectedNFSExport: String? {
        get { browseContext.selectedNFSExport }
        set { browseContext.selectedNFSExport = newValue }
    }
    /// The shallowest folder the user may navigate above. A manually-entered path
    /// is a boundary, not permission to browse the rest of the server.
    private var minimumBrowsePath: String {
        get { browseContext.minimumPath }
        set { browseContext.minimumPath = newValue }
    }
    private var canReturnToRootList: Bool {
        get { browseContext.canReturnToRootList }
        set { browseContext.canReturnToRootList = newValue }
    }
    /// The SFTP host key captured during the connect probe, awaiting the user's
    /// approval on the verify step.
    private var pendingSFTPHostKey: Data?
    /// The SFTP host key the user approved, pinned into the saved account.
    private var approvedHostKeyPin: Data?

    public init(
        smbProbe: any SMBOnboardingProbing = SMBOnboardingProbe(),
        webDAVProbe: any WebDAVOnboardingProbing = WebDAVOnboardingProbe(),
        serviceProbe: any MediaShareServiceProbing = ProtocolServiceProbe(),
        sftpProbe: any SFTPOnboardingProbing = SFTPOnboardingProbe(),
        ftpProbe: any FTPOnboardingProbing = FTPOnboardingProbe(),
        nfsProbe: any NFSOnboardingProbing = NFSOnboardingProbe()
    ) {
        self.smbProbe = smbProbe
        self.webDAVProbe = webDAVProbe
        self.serviceProbe = serviceProbe
        self.sftpProbe = sftpProbe
        self.ftpProbe = ftpProbe
        self.nfsProbe = nfsProbe
        self.discovery = BonjourServiceDiscovery(mapping: Self.mapping)
    }

    // MARK: - Catalog-derived config

    private static let mapping = BonjourTransportMapping(
        MediaShareTransportCatalog.all.flatMap { descriptor in
            descriptor.bonjourServiceTypes.map { serviceType in
                let scheme: String?
                switch serviceType {
                case "_webdav._tcp": scheme = "http"
                case "_webdavs._tcp": scheme = "https"
                default: scheme = nil
                }
                return (
                    serviceType: serviceType,
                    transport: descriptor.kind,
                    defaultPort: Optional(descriptor.defaultPort),
                    scheme: scheme
                )
            }
        }
    )
    private static let sweepSpecs = MediaShareTransportCatalog.all.map {
        TransportSweepSpec(
            transport: $0.kind,
            targets: $0.sweepTargets,
            defaultPort: $0.defaultPort
        )
    }

    public func descriptor(_ kind: MediaShareTransportKind) -> TransportOnboardingDescriptor? {
        MediaShareTransportCatalog.descriptor(for: kind)
    }

    // MARK: - Discovery

    public func startScan() {
        scanTask?.cancel()
        boxes = []
        scanning = true
        sweptHosts = []
        fullDoorsByHost = [:]
        scanTask = Task { [discovery] in
            var services: [DiscoveredNetworkService] = []
            for await service in discovery.discover(timeout: 6) {
                if Task.isCancelled { break }
                services.append(service)
                // Record the advertised door (Bonjour carries the REAL port).
                self.recordDoors(host: service.host, [
                    DiscoveredMediaShareBox.Door(
                        transport: service.transport,
                        port: service.port,
                        scheme: service.scheme
                    )
                ])
                self.boxes = MediaShareBoxGrouping.group(services).map { box in
                    box.mergingDoors(
                        self.fullDoorsByHost[box.host.lowercased()] ?? []
                    )
                }
                // Curated Channel-B sweep on each newly-seen host, DURING discovery,
                // so non-advertised doors (e.g. WebDAV on :8384) show on the device
                // row and prefill the form — not only after the box is opened.
                if self.sweptHosts.insert(service.host.lowercased()).inserted {
                    self.sweepAndMerge(host: service.host)
                }
            }
            if !Task.isCancelled { self.scanning = false }
        }
    }

    /// Records detected doors for a host, keeping EVERY port we found (a NAS can
    /// expose one transport on several ports — we never throw a detected port
    /// away). The per-box row label only needs the distinct transports, but the
    /// Connect form needs the exact ports so it can prefill and offer chips.
    private func recordDoors(host: String, _ doors: [DiscoveredMediaShareBox.Door]) {
        let key = host.lowercased()
        var list = fullDoorsByHost[key] ?? []
        for door in doors where !list.contains(door) { list.append(door) }
        fullDoorsByHost[key] = list
    }

    private func sweepAndMerge(host: String) {
        Task { [sweeper] in
            let found = await sweeper.sweep(host: host, specs: Self.sweepSpecs)
            if Task.isCancelled || found.isEmpty { return }
            self.recordDoors(host: host, found)
            guard let idx = self.boxes.firstIndex(where: { $0.host.lowercased() == host.lowercased() }) else { return }
            self.boxes[idx] = self.boxes[idx].mergingDoors(found)
            // If the user is already on this box's Connect form, reflect the new
            // doors there too.
            if self.address.lowercased() == host.lowercased() {
                self.detectedDoors = self.fullDoorsByHost[host.lowercased()] ?? self.boxes[idx].doors
                self.applyTransport(self.selectedTransport)
            }
        }
    }

    public func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        scanning = false
    }

    // MARK: - Entering the Connect form

    /// Open the Connect form pre-filled from a discovered device. Its doors were
    /// already gathered during discovery (Bonjour + the curated sweep), so the
    /// best one is pre-selected and its port prefilled.
    public func openConnect(for box: DiscoveredMediaShareBox) {
        stopScan()
        resetForm()
        address = box.host
        // Use the FULL detected-door set (all ports), not the row's deduped list.
        detectedDoors = fullDoorsByHost[box.host.lowercased()] ?? box.doors
        let best = MediaShareTransportCatalog.preferredKind(among: detectedDoors.map(\.transport)) ?? .smb
        applyTransport(best)
        step = .connect
    }

    /// Open the Connect form blank for a typed address. No auto-detect — the user
    /// picks a protocol explicitly; it defaults to the most common (SMB).
    public func openManualConnect() {
        stopScan()
        resetForm()
        detectedDoors = []
        applyTransport(.smb)
        step = .connect
    }

    private func resetForm() {
        connectError = nil
        username = ""; password = ""; token = ""; manualShare = ""; displayName = ""
        address = ""
        portText = ""
        authMode = .usernamePassword
        locations = []; locationLoad = .idle; currentPath = "/"
        webDAVScheme = nil
        webDAVSchemePort = nil
        trust = .system; approvedPin = nil
        confirmedPath = "/"
        selectedSMBShare = nil
        selectedNFSExport = nil
        minimumBrowsePath = "/"
        canReturnToRootList = false
        pendingSFTPHostKey = nil
        approvedHostKeyPin = nil
    }

    /// Whether a protocol root has been chosen and the current directory can be
    /// saved. SMB and NFS first show their share/export lists, so they do not show
    /// folder controls until one of those roots is open.
    public var showsCurrentFolder: Bool {
        switch selectedTransport {
        case .smb:
            return selectedSMBShare != nil
        case .nfs:
            return selectedNFSExport != nil
        case .webDAV, .sftp, .ftp:
            return true
        }
    }

    public var canNavigateUp: Bool {
        switch selectedTransport {
        case .smb:
            return selectedSMBShare != nil
                && (currentPath != minimumBrowsePath || canReturnToRootList)
        case .nfs:
            return selectedNFSExport != nil
                && (currentPath != minimumBrowsePath || canReturnToRootList)
        case .webDAV, .sftp, .ftp:
            return currentPath != minimumBrowsePath
        }
    }

    public var showsManualRootEntry: Bool {
        !showsCurrentFolder
            && (selectedTransport == .smb || selectedTransport == .nfs)
    }

    /// Set the chosen protocol and prefill the port from what we DETECTED for that
    /// protocol. When a device answered on a specific (non-default) port — e.g.
    /// WebDAV on :8384 — we use that exact port, because it's the one the user
    /// configured. We never discard a detected port in favour of the default.
    public func applyTransport(_ kind: MediaShareTransportKind, doors: [DiscoveredMediaShareBox.Door]? = nil) {
        if selectedTransport != kind {
            workTask?.cancel()
            workTask = nil
            detecting = false
            connectError = nil
            locations = []
            locationLoad = .idle
        }
        selectedTransport = kind
        guard let descriptor = descriptor(kind) else { portText = ""; return }
        if let door = bestDetectedDoor(for: kind, descriptor: descriptor) {
            let port = door.port ?? descriptor.defaultPort
            portText = String(port)
            webDAVScheme = kind == .webDAV ? door.scheme : nil
            webDAVSchemePort = kind == .webDAV ? port : nil
        } else {
            portText = String(descriptor.defaultPort)
            webDAVScheme = nil
            webDAVSchemePort = nil
        }
        // Token mode only exists for WebDAV; reset otherwise.
        if !descriptor.authModes.contains(.token) { authMode = .usernamePassword }
    }

    /// The port to prefill for a transport, from the detected doors: prefer a
    /// specific (non-default) port the device answered on — that's the meaningful
    /// find — and take the highest one if several. Returns nil when the only
    /// detection is on the default port (then the default is used implicitly).
    private func bestDetectedDoor(
        for kind: MediaShareTransportKind,
        descriptor: TransportOnboardingDescriptor
    ) -> DiscoveredMediaShareBox.Door? {
        let doors = detectedDoors.filter { $0.transport == kind }
        guard !doors.isEmpty else { return nil }
        return doors.max {
            let lhs = $0.port ?? descriptor.defaultPort
            let rhs = $1.port ?? descriptor.defaultPort
            let lhsSpecific = lhs != descriptor.defaultPort
            let rhsSpecific = rhs != descriptor.defaultPort
            if lhsSpecific != rhsSpecific { return !lhsSpecific }
            return lhs < rhs
        }
    }

    /// All distinct ports detected for a transport (drives the port chips).
    public func detectedPorts(for kind: MediaShareTransportKind) -> [Int] {
        let descriptor = descriptor(kind)
        let ports = detectedDoors
            .filter { $0.transport == kind }
            .map { $0.port ?? (descriptor?.defaultPort ?? 0) }
        return Array(Set(ports)).sorted()
    }

    public var canConnect: Bool {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if let inlinePort = inlinePortComponent(from: address) {
            guard let port = Int(inlinePort), (1...65_535).contains(port) else {
                return false
            }
        }
        let trimmedPort = portText.trimmingCharacters(in: .whitespaces)
        if !trimmedPort.isEmpty {
            guard let port = Int(trimmedPort), (1...65_535).contains(port) else {
                return false
            }
        }
        guard let descriptor = descriptor(selectedTransport) else { return true }
        if descriptor.authModes.isEmpty { return true } // NFS: no creds
        if !descriptor.allowsBlankGuest, authMode == .usernamePassword {
            return !username.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    /// The plaintext-credential warning to show for the current form, if any.
    public var plaintextWarning: LocalizedStringResource? {
        guard let descriptor = descriptor(selectedTransport) else { return nil }
        switch descriptor.plaintextCredentialRisk {
        case .never:
            return nil
        case .always:
            return hasEnteredCredential
                ? "Credentials will be sent without encryption."
                : nil
        case .whenInsecureScheme:
            let explicit = explicitScheme(from: address)
            let scheme = explicit
                ?? ((webDAVSchemePort == currentPort) ? webDAVScheme : nil)
                ?? (portIs(80) ? "http" : nil)
            let insecure = scheme == "http"
            return insecure && hasEnteredCredential
                ? "Credentials will be sent over HTTP."
                : nil
        }
    }

    private func portIs(_ p: Int) -> Bool { Int(portText.trimmingCharacters(in: .whitespaces)) == p }
    private var currentPort: Int? {
        effectivePort(for: selectedTransport, rawAddress: address)
    }

    // MARK: - Connect

    public func connect() {
        workTask?.cancel()
        connectError = nil
        let host = normalizedHost(address)
        let kind = selectedTransport
        // Port comes from the Port field; if the user pasted host:port into the
        // address, honour that inline port too.
        let port = effectivePort(for: kind, rawAddress: address)

        guard let descriptor = descriptor(kind) else { return }
        guard descriptor.isImplemented else {
            step = .comingSoon(kind)
            return
        }
        resolvedHost = host
        resolvedPort = port
        switch kind {
        case .smb:
            enterSMBLocation()
        case .webDAV:
            beginWebDAV(rawAddress: address, host: host, port: port)
        case .nfs:
            beginNFSBrowse()
        case .ftp:
            beginFTPBrowse()
        case .sftp:
            beginSFTP(host: host, port: port ?? descriptor.defaultPort)
        }
    }

    private func normalizedHost(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://")
            ? trimmed
            : "smb://\(trimmed)"
        if let host = URLComponents(string: candidate)?.host {
            return unbracketedHost(host)
        }
        return unbracketedHost(trimmed)
    }

    private func inlinePort(from raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://")
            ? trimmed
            : "smb://\(trimmed)"
        return URLComponents(string: candidate)?.port
    }

    private func inlinePortComponent(from raw: String) -> String? {
        var authority = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = authority.range(of: "://") {
            authority = String(authority[range.upperBound...])
        }
        if let slash = authority.firstIndex(of: "/") {
            authority = String(authority[..<slash])
        }
        if authority.hasPrefix("["),
           let close = authority.firstIndex(of: "]") {
            let suffix = authority[authority.index(after: close)...]
            guard suffix.first == ":" else { return nil }
            return String(suffix.dropFirst())
        }
        guard authority.filter({ $0 == ":" }).count == 1,
              let colon = authority.firstIndex(of: ":") else {
            return nil
        }
        return String(authority[authority.index(after: colon)...])
    }

    private func unbracketedHost(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }

    private func effectivePort(
        for kind: MediaShareTransportKind,
        rawAddress: String
    ) -> Int? {
        if let inline = inlinePort(from: rawAddress) {
            return (1...65_535).contains(inline) ? inline : nil
        }
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let entered = Int(trimmed),
              (1...65_535).contains(entered) else {
            return nil
        }
        guard entered == descriptor(kind)?.defaultPort else { return entered }
        let scheme = rawAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        switch kind {
        case .webDAV where scheme.hasPrefix("http://"):
            return 80
        case .webDAV where scheme.hasPrefix("https://"):
            return 443
        case .ftp where scheme.hasPrefix("ftps://"):
            return 990
        case .ftp where scheme.hasPrefix("ftp://"):
            return 21
        default:
            return entered
        }
    }

    private func explicitScheme(from raw: String) -> String? {
        let lower = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasPrefix("http://") { return "http" }
        if lower.hasPrefix("https://") { return "https" }
        return nil
    }

    private func enteredPath(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(
            string: candidate
        ) else {
            return "/"
        }
        return normalizedWebDAVPath(components.percentEncodedPath)
    }

    private func enterSMBLocation() {
        step = .pickLocation
        let entered = filesystemPath(from: address)
        let components = entered.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard let share = components.first else {
            loadSMBShares()
            return
        }
        let subpath = components.dropFirst().joined(separator: "/")
        selectedSMBShare = share
        minimumBrowsePath = joinedSMBPath(share: share, subpath: subpath)
        canReturnToRootList = false
        workTask = Task {
            await self.loadSMBFolders(path: self.minimumBrowsePath)
        }
    }

    // MARK: - NFS / SFTP / FTP (path-entry transports)

    /// Extracts the literal, decoded root path a user typed in the address
    /// (`host/movies`, `nfs://host/export`, `sftp://host:22/media`). Unlike the
    /// WebDAV path helper this keeps the path literal (filesystem transports
    /// address by decoded names), defaulting to `/` when none is given.
    private func filesystemPath(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.contains("://") ? trimmed : "file://\(trimmed)"
        if let components = URLComponents(string: candidate),
           !components.path.isEmpty {
            return normalizedAbsolutePath(components.path)
        }
        guard let slash = trimmed.firstIndex(of: "/") else { return "/" }
        return normalizedAbsolutePath(String(trimmed[slash...]))
    }

    /// SFTP first-connect: capture the server's host key with no user credential,
    /// then route to explicit approval. Real authentication happens only on the
    /// pinned reconnect after approval.
    private func beginSFTP(host: String, port: Int) {
        workTask?.cancel()
        detecting = true
        workTask = Task { [sftpProbe] in
            defer { self.detecting = false }
            let result = await sftpProbe.captureHostKey(
                host: host,
                port: port
            )
            if Task.isCancelled { return }
            switch result {
            case .success(let sha256):
                self.pendingSFTPHostKey = sha256
                self.step = .verifyTrust(sha256: sha256)
            case .authenticationFailed:
                self.connectError = "Couldn’t capture this server’s host key."
            case .unreachable:
                self.connectError = "Couldn’t reach that server. Check the address and network."
            case .failed(let message):
                PlozzLog.networking.error("SFTP host-key capture failed: \(message)")
                self.connectError = "Couldn’t connect to this SFTP server."
            case .cancelled:
                break
            }
        }
    }

    /// Lists the child directories of the current SFTP path so the user can drill
    /// into a subfolder before saving. Reuses the captured + approved host key and
    /// the form credentials; reconnects per call (onboarding is low-frequency).
    public func loadSFTPFolders(path: String) async {
        guard let pin = approvedHostKeyPin else { return }
        let path = normalizedAbsolutePath(path)
        guard isSameOrDescendant(path, of: minimumBrowsePath) else { return }
        currentPath = path
        confirmedPath = path
        locationLoad = .loading
        let host = resolvedHost
        let port = resolvedPort ?? (descriptor(.sftp)?.defaultPort ?? 22)
        let user = username.trimmingCharacters(in: .whitespaces)
        let pass = password
        let result = await sftpProbe.listDirectories(
            host: host,
            port: port,
            username: user,
            password: pass,
            hostKeySHA256: pin,
            path: path
        )
        if Task.isCancelled { return }
        switch result {
        case .success(let dirs):
            locations = dirs.map { LocationItem(name: $0.name, path: $0.path, isBrowsable: true) }
            locationLoad = .loaded
        case .authenticationFailed:
            locationLoad = .badCredentials
        case .unreachable:
            locationLoad = .unreachable
        case .failed(let message):
            PlozzLog.networking.error("SFTP folder listing failed: \(message)")
            locationLoad = .failed("Couldn’t connect to this SFTP server.")
        case .cancelled:
            break
        }
    }

    /// NFS first-connect: try to list the server's advertised exports so the user
    /// can pick a real export path. Falls back to a manual export-path field when
    /// the server blocks `showmount`/EXPORT (common) — surfaced via a failed load.
    private func beginNFSBrowse() {
        step = .pickLocation
        workTask?.cancel()
        let entered = filesystemPath(from: address)
        if entered == "/" {
            workTask = Task { await self.loadNFSExports() }
        } else {
            selectedNFSExport = entered
            minimumBrowsePath = entered
            canReturnToRootList = false
            workTask = Task { await self.loadNFSFolders(path: entered) }
        }
    }

    public func loadNFSExports() async {
        locationLoad = .loading
        locations = []
        let host = resolvedHost
        let port = resolvedPort
        let result = await nfsProbe.listExports(host: host, port: port)
        if Task.isCancelled { return }
        switch result {
        case .success(let exports):
            if exports.isEmpty {
                locationLoad = .failed("This server didn’t advertise any exports. Enter the export path, e.g. /volume1/Media.")
            } else {
                selectedNFSExport = nil
                currentPath = "/"
                minimumBrowsePath = "/"
                canReturnToRootList = false
                locations = exports.map {
                    LocationItem(
                        name: $0.name,
                        path: normalizedAbsolutePath($0.path),
                        isBrowsable: true
                    )
                }
                locationLoad = .loaded
            }
        case .unreachable:
            locationLoad = .unreachable
        case .permissionDenied:
            locationLoad = .failed("This server didn’t allow listing exports. Enter the export path, e.g. /volume1/Media.")
        case .failed(let message):
            locationLoad = .failed("Couldn’t load locations: \(message)")
        }
    }

    /// Open a chosen NFS export so the user can select the export itself or drill
    /// into a subfolder without assuming the server permits subtree mounts.
    public func chooseNFSExport(_ path: String) {
        guard hasValidPathComponents(path) else { return }
        let normalized = normalizedAbsolutePath(path)
        selectedNFSExport = normalized
        minimumBrowsePath = normalized
        canReturnToRootList = true
        workTask?.cancel()
        workTask = Task { await self.loadNFSFolders(path: normalized) }
    }

    /// Save a manually-typed NFS export path when browsing is unavailable.
    public func chooseNFSManualExport() {
        let trimmed = manualShare.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, hasValidPathComponents(trimmed) else { return }
        selectedNFSExport = normalizedAbsolutePath(trimmed)
        confirmedPath = selectedNFSExport ?? "/"
        chooseFilesystemRoot()
    }

    public func loadNFSFolders(path: String) async {
        guard let exportPath = selectedNFSExport else { return }
        let normalizedPath = normalizedAbsolutePath(path)
        guard let relativePath = relativePath(
            normalizedPath,
            below: exportPath
        ) else { return }
        currentPath = normalizedPath
        confirmedPath = normalizedPath
        locationLoad = .loading
        let result = await nfsProbe.listDirectories(
            host: resolvedHost,
            port: resolvedPort,
            exportPath: exportPath,
            relativePath: relativePath
        )
        if Task.isCancelled { return }
        switch result {
        case .success(let directories):
            locations = directories.map {
                LocationItem(
                    name: $0.name,
                    path: normalizedAbsolutePath($0.path),
                    isBrowsable: true
                )
            }
            locationLoad = .loaded
        case .unreachable:
            locationLoad = .unreachable
        case .permissionDenied:
            locationLoad = .failed("This account can’t browse that NFS folder.")
        case .failed(let message):
            PlozzLog.networking.error("NFS folder listing failed: \(message)")
            locationLoad = .failed("Couldn’t browse this NFS folder.")
        }
    }

    /// FTP first-connect: attempt the initial listing WHILE STILL ON THE CONNECT
    /// PAGE (with a spinner). Only advance to the folder browser on success; a
    /// rejected login stays on Connect with a clear credential error, instead of
    /// jumping ahead and reporting "needs a username and password" on the next
    /// screen (which looks like the credentials were never entered).
    private func beginFTPBrowse() {
        workTask?.cancel()
        detecting = true
        let start = filesystemPath(from: address)
        let host = resolvedHost
        let scheme = ftpScheme(from: address, port: resolvedPort)
        let user = username.trimmingCharacters(in: .whitespaces)
        let pass = password
        workTask = Task { [ftpProbe] in
            defer { self.detecting = false }
            let result = await ftpProbe.listDirectories(
                host: host,
                port: self.resolvedPort,
                isImplicitTLS: scheme == "ftps",
                username: user,
                password: pass,
                trustPinSHA256: nil,
                path: start
            )
            if Task.isCancelled { return }
            switch result {
            case .success(let dirs):
                self.minimumBrowsePath = start
                self.currentPath = start
                self.confirmedPath = start
                self.locations = dirs.map { LocationItem(name: $0.name, path: $0.path, isBrowsable: true) }
                self.locationLoad = .loaded
                self.step = .pickLocation
            case .authenticationFailed:
                self.connectError = "That username or password was rejected."
            case .unreachable:
                self.connectError = "Couldn’t reach that server. Check the address and network."
            case .failed(let message):
                PlozzLog.networking.error("FTP folder browse failed: \(message)")
                self.connectError = "Couldn’t connect to this FTP server."
            case .cancelled:
                break
            }
        }
    }

    /// Lists the child directories of the current FTP path. Reconnects per call
    /// (onboarding is low-frequency), mirroring the WebDAV/SFTP browsers. Used for
    /// drilling AFTER the first connect already validated credentials.
    public func loadFTPFolders(path: String) async {
        let path = normalizedAbsolutePath(path)
        guard isSameOrDescendant(path, of: minimumBrowsePath) else { return }
        currentPath = path
        confirmedPath = path
        locationLoad = .loading
        let host = resolvedHost
        let scheme = ftpScheme(from: address, port: resolvedPort)
        let user = username.trimmingCharacters(in: .whitespaces)
        let pass = password
        let result = await ftpProbe.listDirectories(
            host: host,
            port: resolvedPort,
            isImplicitTLS: scheme == "ftps",
            username: user,
            password: pass,
            trustPinSHA256: nil,
            path: path
        )
        if Task.isCancelled { return }
        switch result {
        case .success(let dirs):
            locations = dirs.map { LocationItem(name: $0.name, path: $0.path, isBrowsable: true) }
            locationLoad = .loaded
        case .authenticationFailed:
            locationLoad = .badCredentials
        case .unreachable:
            locationLoad = .unreachable
        case .failed(let message):
            PlozzLog.networking.error("FTP folder listing failed: \(message)")
            locationLoad = .failed("Couldn’t connect to this FTP server.")
        case .cancelled:
            break
        }
    }

    private func makeFTPURL(scheme: String, path: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = resolvedHost.contains(":") ? "[\(resolvedHost)]" : resolvedHost
        let defaultPort = scheme == "ftps" ? 990 : 21
        if let port = resolvedPort, port != defaultPort { comps.port = port }
        comps.path = path == "/" ? "" : path
        return comps.url
    }

    private func ftpScheme(from raw: String, port: Int?) -> String {
        let lower = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasPrefix("ftps://") { return "ftps" }
        if lower.hasPrefix("ftp://") { return "ftp" }
        // Implicit-FTPS default control port; otherwise plain FTP.
        return port == 990 ? "ftps" : "ftp"
    }

    /// Confirms the reviewed root and hands the completed configuration back for
    /// persistence. NFS/FTP build here; SFTP reuses the captured + approved pin.
    public func chooseFilesystemRoot() {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let path = confirmedPath
        switch selectedTransport {
        case .nfs:
            guard let exportPath = selectedNFSExport,
                  let subpath = relativePath(path, below: exportPath) else {
                return
            }
            onMediaShareConfigured(.nfs(NFSShareConfiguration(
                host: resolvedHost,
                port: resolvedPort,
                exportPath: exportPath,
                subpath: subpath,
                displayName: name
            )))
        case .sftp:
            let user = username.trimmingCharacters(in: .whitespaces)
            guard !user.isEmpty,
                  let pinData = approvedHostKeyPin,
                  let pin = try? SHA256Fingerprint(bytes: pinData) else { return }
            onMediaShareConfigured(.sftp(SFTPShareConfiguration(
                host: resolvedHost,
                port: resolvedPort,
                path: path,
                username: user,
                password: password,
                hostKeyPin: pin,
                displayName: name
            )))
        case .ftp:
            let scheme = ftpScheme(from: address, port: resolvedPort)
            guard let url = makeFTPURL(scheme: scheme, path: path) else {
                connectError = "That doesn’t look like a valid address."
                return
            }
            let user = username.trimmingCharacters(in: .whitespaces)
            let auth: MediaShareFTPAuth = (user.isEmpty && password.isEmpty)
                ? .anonymous
                : .password(username: user, password: password)
            onMediaShareConfigured(.ftp(FTPShareConfiguration(
                baseURL: url,
                auth: auth,
                trustPin: nil,
                displayName: name
            )))
        case .smb, .webDAV:
            break
        }
    }

    public func loadSMBShares() {
        workTask?.cancel()
        locationLoad = .loading
        locations = []
        selectedSMBShare = nil
        currentPath = "/"
        minimumBrowsePath = "/"
        canReturnToRootList = false
        let host = resolvedHost, port = resolvedPort
        let user = username, pass = password
        workTask = Task { [smbProbe] in
            let result = await smbProbe.listShares(
                host: host,
                port: port,
                username: user,
                password: pass
            )
            if Task.isCancelled { return }
            switch result {
            case .success(let shares):
                self.locations = shares.map {
                    LocationItem(
                        name: $0.name,
                        path: $0.path,
                        isBrowsable: true
                    )
                }
                self.locationLoad = .loaded
            case .authenticationRequired:
                self.locationLoad = .needsAuth
            case .credentialsRejected:
                self.locationLoad = .badCredentials
            case .unreachable:
                self.locationLoad = .unreachable
            case .failed(let reason):
                PlozzLog.networking.error("SMB share listing failed: \(reason)")
                self.locationLoad = .failed(
                    "Something went wrong talking to this server."
                )
            case .cancelled:
                break
            }
        }
    }

    public func loadSMBFolders(path: String) async {
        let normalizedPath = normalizedRelativePath(path)
        let components = normalizedPath.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard let share = components.first else { return }
        if selectedSMBShare == nil {
            selectedSMBShare = share
            minimumBrowsePath = share
        }
        guard selectedSMBShare == share,
              isSameOrDescendant(
                normalizedPath,
                of: minimumBrowsePath,
                separator: "/"
              ) else { return }
        let relativePath = components.dropFirst().joined(separator: "/")
        currentPath = normalizedPath
        confirmedPath = normalizedPath
        locationLoad = .loading
        let result = await smbProbe.listDirectories(
            host: resolvedHost,
            port: resolvedPort,
            share: share,
            username: username,
            password: password,
            relativePath: relativePath
        )
        if Task.isCancelled { return }
        switch result {
        case .success(let directories):
            locations = directories.map {
                LocationItem(
                    name: $0.name,
                    path: joinedSMBPath(share: share, subpath: $0.path),
                    isBrowsable: true
                )
            }
            locationLoad = .loaded
        case .authenticationRequired:
            locationLoad = .needsAuth
        case .credentialsRejected:
            locationLoad = .badCredentials
        case .unreachable:
            locationLoad = .unreachable
        case .failed(let reason):
            PlozzLog.networking.error("SMB folder listing failed: \(reason)")
            locationLoad = .failed("Couldn’t browse this SMB folder.")
        case .cancelled:
            break
        }
    }

    // MARK: - WebDAV (real backend)

    private func beginWebDAV(
        rawAddress: String,
        host: String,
        port: Int?
    ) {
        let path = enteredPath(from: rawAddress)
        if let scheme = explicitScheme(from: rawAddress) {
            webDAVScheme = scheme
            webDAVSchemePort = port
            guard let url = makeWebDAVURL(
                scheme: scheme,
                host: host,
                port: port,
                path: path
            ) else {
                connectError = "That doesn’t look like a valid address."
                return
            }
            beginWebDAV(url: url)
            return
        }

        if webDAVSchemePort == port, let scheme = webDAVScheme {
            guard let url = makeWebDAVURL(
                scheme: scheme,
                host: host,
                port: port,
                path: path
            ) else {
                connectError = "That doesn’t look like a valid address."
                return
            }
            beginWebDAV(url: url)
            return
        }

        detectWebDAVScheme(host: host, port: port, path: path)
    }

    private func makeWebDAVURL(
        scheme: String,
        host: String,
        port: Int?,
        path: String
    ) -> URL? {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host.contains(":") ? "[\(host)]" : host
        if let port, port != (scheme == "https" ? 443 : 80) { comps.port = port }
        comps.percentEncodedPath = path == "/" ? "" : path
        return comps.url
    }

    /// Manual WebDAV entry without a scheme: confirm HTTPS first, then HTTP.
    /// The probe is credential-free. If an insecure HTTP endpoint is found while
    /// credentials are already filled, stop on the form so the warning is visible
    /// before any credential is sent.
    private func detectWebDAVScheme(
        host: String,
        port: Int?,
        path: String
    ) {
        guard let port else {
            connectError = "Enter a port for this WebDAV server."
            return
        }
        detecting = true
        workTask = Task { [serviceProbe] in
            defer { self.detecting = false }
            let candidates: [(String, MediaShareServiceProbeKind)] = [
                ("https", .webDAVHTTPS),
                ("http", .webDAVHTTP),
            ]
            for (scheme, probeKind) in candidates {
                let confirmed = await serviceProbe.confirms(
                    host: host,
                    target: TransportSweepTarget(
                        port: port,
                        probe: probeKind
                    ),
                    timeout: 2.5
                )
                if Task.isCancelled { return }
                guard confirmed else { continue }

                self.webDAVScheme = scheme
                self.webDAVSchemePort = port
                if scheme == "http", self.hasEnteredCredential {
                    self.connectError =
                        "This WebDAV server uses HTTP. Review the security warning, then Connect again."
                    return
                }
                guard let url = self.makeWebDAVURL(
                    scheme: scheme,
                    host: host,
                    port: port,
                    path: path
                ) else {
                    self.connectError =
                        "That doesn’t look like a valid address."
                    return
                }
                self.beginWebDAV(url: url)
                return
            }
            self.connectError =
                "Couldn’t determine whether this WebDAV server uses HTTP or HTTPS."
        }
    }

    private var hasEnteredCredential: Bool {
        switch authMode {
        case .token:
            return !token.trimmingCharacters(in: .whitespaces).isEmpty
        case .usernamePassword:
            return !username.trimmingCharacters(in: .whitespaces).isEmpty
                || !password.isEmpty
        }
    }

    private func beginWebDAV(url: URL) {
        workTask?.cancel()
        detecting = true
        workTask = Task {
            defer { self.detecting = false }
            // Preflight TLS on https so a self-signed cert is approved first.
            if url.scheme?.lowercased() == "https" {
                let preflight = await self.webDAVProbe.preflightTrust(url: url)
                if Task.isCancelled { return }
                switch preflight {
                case .systemTrusted:
                    self.trust = .system; self.approvedPin = nil
                case .needsApproval(let sha256):
                    self.pendingWebDAVURL = url
                    self.step = .verifyTrust(sha256: sha256)
                    return
                case .unreachable:
                    self.connectError = "Couldn’t reach that server. Check the address and network."
                    return
                }
            } else {
                self.trust = .system; self.approvedPin = nil
            }
            await self.validateAndBrowseWebDAV(url: url)
        }
    }

    private var pendingWebDAVURL: URL?

    public func approveTrust() {
        guard case .verifyTrust(let sha256) = step else { return }
        // SFTP: the fingerprint is an SSH host key already captured by the connect
        // probe. Approving pins it and opens a folder browser rooted at the typed
        // path (or `/`), so the user can drill into a subfolder to use as the share
        // root. That pinned reconnect is the first time real credentials are sent.
        if let hostKey = pendingSFTPHostKey {
            pendingSFTPHostKey = nil
            approvedHostKeyPin = hostKey
            step = .pickLocation
            let start = filesystemPath(from: address)
            minimumBrowsePath = start
            workTask?.cancel()
            workTask = Task { await self.loadSFTPFolders(path: start) }
            return
        }
        // WebDAV: the fingerprint is a TLS leaf cert; pin it and browse.
        guard let url = pendingWebDAVURL else { return }
        trust = .pinnedLeaf(sha256: sha256)
        approvedPin = sha256
        workTask?.cancel()
        workTask = Task {
            await self.validateAndBrowseWebDAV(url: url)
        }
    }

    public func rejectTrust() {
        trust = .system; approvedPin = nil
        pendingWebDAVURL = nil
        pendingSFTPHostKey = nil
        approvedHostKeyPin = nil
        step = .connect
    }

    private func validateAndBrowseWebDAV(url: URL) async {
        let credential = webDAVCredential()
        let validation = await webDAVProbe.validate(
            url: url,
            credential: credential,
            trust: trust
        )
        if Task.isCancelled { return }
        switch validation {
        case .success:
            break
        case .failure(let error):
            self.connectError = Self.webDAVMessage(error)
            self.step = .connect
            return
        }
        webDAVOriginURL = originURL(of: url)
        let start = enteredPath(from: url.absoluteString)
        minimumBrowsePath = start
        await loadWebDAVFolders(path: start)
        if connectError == nil { step = .pickLocation }
    }

    private var webDAVOriginURL: URL?

    public func loadWebDAVFolders(path: String) async {
        guard let origin = webDAVOriginURL else { return }
        let path = normalizedWebDAVPath(path)
        guard isSameOrDescendant(path, of: minimumBrowsePath) else { return }
        currentPath = path
        confirmedPath = path
        locationLoad = .loading
        let result = await webDAVProbe.listFolders(
            url: origin,
            path: path,
            credential: webDAVCredential(),
            trust: trust
        )
        if Task.isCancelled { return }
        switch result {
        case .success(let folders):
            locations = folders.map { LocationItem(name: $0.name, path: $0.path, isBrowsable: true) }
            locationLoad = .loaded
        case .failure(let error):
            locationLoad = .failed(Self.webDAVMessage(error))
        }
    }

    private func webDAVCredential() -> WebDAVCredential {
        switch authMode {
        case .token:
            return token.isEmpty ? .anonymous : .bearerToken(token.trimmingCharacters(in: .whitespaces))
        case .usernamePassword:
            if username.isEmpty && password.isEmpty { return .anonymous }
            return .password(username: username.trimmingCharacters(in: .whitespaces), password: password, policy: .automatic)
        }
    }

    private var webDAVShareAuth: MediaShareWebDAVAuth {
        switch authMode {
        case .token:
            return token.isEmpty ? .anonymous : .bearer(token: token.trimmingCharacters(in: .whitespaces))
        case .usernamePassword:
            if username.isEmpty && password.isEmpty { return .anonymous }
            return .password(username: username.trimmingCharacters(in: .whitespaces), password: password)
        }
    }

    private func originURL(of url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = ""; comps.query = nil; comps.fragment = nil
        return comps.url
    }

    // MARK: - Saving

    /// Confirm an SMB share or nested path. The first component is the SMB tree;
    /// the remaining exact-case components scope the library below it.
    public func chooseSMBShare(_ path: String) {
        guard hasValidPathComponents(path) else { return }
        let normalized = normalizedRelativePath(path)
        let components = normalized.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard let share = components.first else { return }
        let subpath = components.dropFirst().joined(separator: "/")
        let name = displayName.trimmingCharacters(in: .whitespaces)
        onSMBConfigured(ShareDraft(
            host: resolvedHost,
            port: resolvedPort,
            share: share,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            displayName: name.isEmpty
                ? (components.last ?? resolvedHost)
                : name,
            subpath: subpath
        ))
    }

    /// Confirm the current WebDAV folder as the share root.
    public func chooseWebDAVFolder(_ path: String) {
        guard let origin = webDAVOriginURL,
              var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return }
        let path = normalizedWebDAVPath(path)
        comps.percentEncodedPath = path == "/" ? "" : path
        guard let baseURL = comps.url else { return }
        let pin = approvedPin.flatMap { try? SHA256Fingerprint(bytes: $0) }
        let name = displayName.trimmingCharacters(in: .whitespaces)
        onWebDAVConfigured(WebDAVShareConfiguration(
            baseURL: baseURL,
            auth: webDAVShareAuth,
            trustPin: pin,
            displayName: name
        ))
    }

    public func selectLocation(_ item: LocationItem) {
        guard item.isBrowsable else { return }
        workTask?.cancel()
        switch selectedTransport {
        case .smb:
            if selectedSMBShare == nil {
                selectedSMBShare = item.path
                minimumBrowsePath = item.path
                canReturnToRootList = true
            }
            workTask = Task { await self.loadSMBFolders(path: item.path) }
        case .nfs:
            if selectedNFSExport == nil {
                selectedNFSExport = normalizedAbsolutePath(item.path)
                minimumBrowsePath = selectedNFSExport ?? "/"
                canReturnToRootList = true
            }
            workTask = Task { await self.loadNFSFolders(path: item.path) }
        case .webDAV:
            workTask = Task { await self.loadWebDAVFolders(path: item.path) }
        case .sftp:
            workTask = Task { await self.loadSFTPFolders(path: item.path) }
        case .ftp:
            workTask = Task { await self.loadFTPFolders(path: item.path) }
        }
    }

    public func browseManualLocation() {
        let entered = manualShare.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty, hasValidPathComponents(entered) else { return }
        workTask?.cancel()
        switch selectedTransport {
        case .smb:
            let path = normalizedRelativePath(entered)
            guard let share = path.split(
                separator: "/",
                omittingEmptySubsequences: true
            ).first.map(String.init) else { return }
            selectedSMBShare = share
            minimumBrowsePath = path
            canReturnToRootList = false
            workTask = Task { await self.loadSMBFolders(path: path) }
        case .nfs:
            let path = normalizedAbsolutePath(entered)
            selectedNFSExport = path
            minimumBrowsePath = path
            canReturnToRootList = false
            workTask = Task { await self.loadNFSFolders(path: path) }
        case .webDAV, .sftp, .ftp:
            break
        }
    }

    public func useCurrentFolder() {
        switch selectedTransport {
        case .smb:
            chooseSMBShare(currentPath)
        case .nfs, .sftp, .ftp:
            chooseFilesystemRoot()
        case .webDAV:
            chooseWebDAVFolder(currentPath)
        }
    }

    public func navigateUp() {
        guard canNavigateUp else { return }
        workTask?.cancel()
        switch selectedTransport {
        case .smb:
            if currentPath == minimumBrowsePath {
                loadSMBShares()
            } else {
                let parent = parentPath(currentPath, absolute: false)
                workTask = Task {
                    await self.loadSMBFolders(path: parent)
                }
            }
        case .nfs:
            if currentPath == minimumBrowsePath {
                selectedNFSExport = nil
                workTask = Task { await self.loadNFSExports() }
            } else {
                let parent = parentPath(currentPath, absolute: true)
                workTask = Task {
                    await self.loadNFSFolders(path: parent)
                }
            }
        case .webDAV:
            workTask = Task {
                await self.loadWebDAVFolders(
                    path: parentPath(currentPath, absolute: true)
                )
            }
        case .sftp:
            workTask = Task {
                await self.loadSFTPFolders(
                    path: parentPath(currentPath, absolute: true)
                )
            }
        case .ftp:
            workTask = Task {
                await self.loadFTPFolders(
                    path: parentPath(currentPath, absolute: true)
                )
            }
        }
    }

    public func retryLocations() {
        workTask?.cancel()
        switch selectedTransport {
        case .smb:
            if selectedSMBShare == nil {
                loadSMBShares()
            } else {
                workTask = Task {
                    await self.loadSMBFolders(path: currentPath)
                }
            }
        case .nfs:
            if selectedNFSExport == nil {
                workTask = Task { await self.loadNFSExports() }
            } else {
                workTask = Task {
                    await self.loadNFSFolders(path: currentPath)
                }
            }
        case .webDAV:
            workTask = Task {
                await self.loadWebDAVFolders(path: currentPath)
            }
        case .sftp:
            workTask = Task {
                await self.loadSFTPFolders(path: currentPath)
            }
        case .ftp:
            workTask = Task {
                await self.loadFTPFolders(path: currentPath)
            }
        }
    }

    // MARK: - Back navigation

    public func backToDevices() {
        workTask?.cancel()
        step = .chooseDevice
        resetForm()
        selectedTransport = .smb
        detectedDoors = []
        startScan()
    }

    public func backToConnect() {
        workTask?.cancel()
        step = .connect
        locations = []; locationLoad = .idle
        currentPath = "/"
        confirmedPath = "/"
        selectedSMBShare = nil
        selectedNFSExport = nil
        minimumBrowsePath = "/"
        canReturnToRootList = false
    }

    private func normalizedAbsolutePath(_ path: String) -> String {
        let normalized = normalizedRelativePath(path)
        return normalized.isEmpty ? "/" : "/\(normalized)"
    }

    private static let webDAVPathSegmentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private func normalizedWebDAVPath(_ path: String) -> String {
        let encodedSegments = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .map { segment in
                let decoded = segment.removingPercentEncoding ?? segment
                return decoded.addingPercentEncoding(
                    withAllowedCharacters: Self.webDAVPathSegmentAllowed
                ) ?? segment
            }
        return encodedSegments.isEmpty
            ? "/"
            : "/" + encodedSegments.joined(separator: "/")
    }

    private func normalizedRelativePath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
    }

    private func hasValidPathComponents(_ path: String) -> Bool {
        guard !path.contains("\0") else { return false }
        return path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .allSatisfy { $0 != "." && $0 != ".." }
    }

    private func joinedSMBPath(share: String, subpath: String) -> String {
        let normalizedSubpath = normalizedRelativePath(subpath)
        return normalizedSubpath.isEmpty
            ? normalizedRelativePath(share)
            : "\(normalizedRelativePath(share))/\(normalizedSubpath)"
    }

    private func relativePath(_ path: String, below root: String) -> String? {
        let path = normalizedAbsolutePath(path)
        let root = normalizedAbsolutePath(root)
        guard isSameOrDescendant(path, of: root) else { return nil }
        guard path != root else { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        return String(path.dropFirst(prefix.count))
    }

    private func isSameOrDescendant(
        _ path: String,
        of root: String,
        separator: Character = "/"
    ) -> Bool {
        guard path != root else { return true }
        let prefix = root == String(separator)
            ? String(separator)
            : root + String(separator)
        return path.hasPrefix(prefix)
    }

    private func parentPath(_ path: String, absolute: Bool) -> String {
        let normalized = absolute
            ? normalizedAbsolutePath(path)
            : normalizedRelativePath(path)
        guard let separator = normalized.lastIndex(of: "/") else {
            return absolute ? "/" : normalized
        }
        let parent = String(normalized[..<separator])
        return parent.isEmpty && absolute ? "/" : parent
    }

    // MARK: - Copy

    private static func webDAVMessage(_ error: WebDAVOnboardingError) -> LocalizedStringResource {
        switch error {
        case .invalidURL: return "That doesn’t look like a valid web address."
        case .notSecure: return "A credential requires a secure (https://) address."
        case .unreachable: return "Couldn’t reach that server. Check the address and network."
        case .untrusted: return "Couldn’t verify this server’s certificate."
        case .authenticationFailed: return "That username, password, or token was rejected."
        case .notWebDAV: return "That server didn’t respond as a WebDAV share (some need a /dav path)."
        case .forbidden: return "This account can’t browse that location."
        case .serverError: return "The server had a problem. Try again in a moment."
        case .cancelled: return "The request was cancelled."
        }
    }
}
