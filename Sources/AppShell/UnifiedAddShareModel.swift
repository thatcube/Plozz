#if canImport(SwiftUI)
import Foundation
import Observation
import CoreModels
import FeatureAuth
import ProviderShare
import MediaTransportHTTP
import MediaTransportSFTP
import MediaTransportFTP
import MediaTransportNFS

/// The finished configuration for an NFS export, handed back to
/// `AppState.didConfigureNFSShare`. NFS is credential-free; the export path is the
/// share root.
struct NFSShareConfiguration: Equatable {
    let host: String
    let port: Int?
    let exportPath: String
    let displayName: String
}

/// The finished configuration for an SFTP share, handed back to
/// `AppState.didConfigureSFTPShare`. Carries the host key captured (and pinned)
/// during onboarding — the vault mandates it.
struct SFTPShareConfiguration: Equatable {
    let host: String
    let port: Int?
    let path: String
    let username: String
    let password: String
    let hostKeyPin: SHA256Fingerprint
    let displayName: String
}

/// The finished configuration for an FTP/FTPS share, handed back to
/// `AppState.didConfigureFTPShare`. `baseURL` carries the real scheme (`ftp` /
/// `ftps`).
struct FTPShareConfiguration: Equatable {
    let baseURL: URL
    let auth: AppState.FTPShareAuth
    let trustPin: SHA256Fingerprint?
    let displayName: String
}

/// A completed add-a-share result for the credential-envelope transports the
/// unified flow drives through one callback (NFS/SFTP/FTP), keeping SMB and
/// WebDAV on their existing dedicated callbacks.
enum MediaShareOnboardingResult: Equatable {
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
///  4. **Pick location** — SMB shares or WebDAV folders (two `listChildren` impls
///     behind one step).
///  5. **Save** — hands back the existing `ShareDraft` / `WebDAVShareConfiguration`
///     so `AppState` persistence is unchanged.
///
/// SMB + WebDAV are wired to their real, on-device-validated backends
/// (`SMBShareEnumerator`, `WebDAVOnboardingProbe`); NFS + SFTP are present in the
/// catalog and discovery but dummy-wired (a "coming soon" step) until their
/// transport branches merge.
@MainActor
@Observable
final class UnifiedAddShareModel {

    enum Step: Equatable {
        case chooseDevice
        case connect
        case verifyTrust(sha256: Data)
        case pickLocation
        case comingSoon(MediaShareTransportKind)
    }

    /// A credential control mode on the Connect form.
    enum AuthMode: Equatable { case usernamePassword, token }

    /// One selectable location at the pick-location step (an SMB share or a
    /// WebDAV folder). `path` drills for WebDAV; SMB shares are leaves.
    struct LocationItem: Identifiable, Equatable {
        let name: String
        let path: String        // SMB: share name; WebDAV: server-rooted folder path
        let isBrowsable: Bool    // WebDAV folders can be drilled into
        var id: String { path }
    }

    enum LocationLoad: Equatable {
        case idle, loading, loaded
        case needsAuth, badCredentials, unreachable
        case failed(String)
    }

    // MARK: Discovery
    private(set) var boxes: [DiscoveredMediaShareBox] = []
    private(set) var scanning = false

    // MARK: Step
    private(set) var step: Step = .chooseDevice

    // MARK: Connect form
    /// The chosen transport on the Connect form. Always a concrete protocol —
    /// there is no "auto-detect". Defaults to a sensible protocol and is set to
    /// the best detected door when a device is opened.
    var selectedTransport: MediaShareTransportKind = .smb
    var address = ""
    var portText = ""
    var username = ""
    var password = ""
    var token = ""
    var authMode: AuthMode = .usernamePassword
    private(set) var detecting = false
    private(set) var connectError: String?
    /// Doors detected for the box currently being connected (for the Protocol
    /// dropdown's "Detected" group and per-door port prefill).
    private(set) var detectedDoors: [DiscoveredMediaShareBox.Door] = []

    // MARK: Location
    private(set) var locations: [LocationItem] = []
    private(set) var locationLoad: LocationLoad = .idle
    private(set) var currentPath = "/"
    var manualShare = ""
    var displayName = ""

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
    var onSMBConfigured: (ShareDraft) -> Void = { _ in }
    var onWebDAVConfigured: (WebDAVShareConfiguration) -> Void = { _ in }
    /// The credential-envelope transports (NFS/SFTP/FTP) report through one
    /// callback; SMB/WebDAV keep their dedicated ones above.
    var onMediaShareConfigured: (MediaShareOnboardingResult) -> Void = { _ in }

    private let discovery: BonjourServiceDiscovery
    private let sweeper = MediaSharePortSweeper()
    private let serviceProbe: any MediaShareServiceProbing
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

    /// The confirmed root path for a path-entry transport (NFS/SFTP/FTP), shown
    /// at the pick-location step for review before saving.
    private(set) var confirmedPath = "/"
    /// The SFTP host key captured during the connect probe, awaiting the user's
    /// approval on the verify step.
    private var pendingSFTPHostKey: Data?
    /// The SFTP host key the user approved, pinned into the saved account.
    private var approvedHostKeyPin: Data?

    init(
        webDAVProbe: any WebDAVOnboardingProbing = WebDAVOnboardingProbe(),
        serviceProbe: any MediaShareServiceProbing = ProtocolServiceProbe(),
        sftpProbe: any SFTPOnboardingProbing = SFTPOnboardingProbe(),
        ftpProbe: any FTPOnboardingProbing = FTPOnboardingProbe(),
        nfsProbe: any NFSOnboardingProbing = NFSOnboardingProbe()
    ) {
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

    func descriptor(_ kind: MediaShareTransportKind) -> TransportOnboardingDescriptor? {
        MediaShareTransportCatalog.descriptor(for: kind)
    }

    // MARK: - Discovery

    func startScan() {
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

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        scanning = false
    }

    // MARK: - Entering the Connect form

    /// Open the Connect form pre-filled from a discovered device. Its doors were
    /// already gathered during discovery (Bonjour + the curated sweep), so the
    /// best one is pre-selected and its port prefilled.
    func openConnect(for box: DiscoveredMediaShareBox) {
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
    func openManualConnect() {
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
        pendingSFTPHostKey = nil
        approvedHostKeyPin = nil
    }

    /// Whether the selected transport drills into nested folders at the
    /// pick-location step (WebDAV, SFTP, FTP), as opposed to a flat list (SMB
    /// shares, NFS exports).
    var isDrillableTransport: Bool {
        switch selectedTransport {
        case .webDAV, .sftp, .ftp: return true
        case .smb, .nfs: return false
        }
    }

    /// Set the chosen protocol and prefill the port from what we DETECTED for that
    /// protocol. When a device answered on a specific (non-default) port — e.g.
    /// WebDAV on :8384 — we use that exact port, because it's the one the user
    /// configured. We never discard a detected port in favour of the default.
    func applyTransport(_ kind: MediaShareTransportKind, doors: [DiscoveredMediaShareBox.Door]? = nil) {
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
    func detectedPorts(for kind: MediaShareTransportKind) -> [Int] {
        let descriptor = descriptor(kind)
        let ports = detectedDoors
            .filter { $0.transport == kind }
            .map { $0.port ?? (descriptor?.defaultPort ?? 0) }
        return Array(Set(ports)).sorted()
    }

    var canConnect: Bool {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let descriptor = descriptor(selectedTransport) else { return true }
        if descriptor.authModes.isEmpty { return true } // NFS: no creds
        if !descriptor.allowsBlankGuest, authMode == .usernamePassword {
            return !username.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    /// The plaintext-credential warning to show for the current form, if any.
    var plaintextWarning: String? {
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
        inlinePort(from: address)
            ?? Int(portText.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Connect

    func connect() {
        workTask?.cancel()
        connectError = nil
        let host = normalizedHost(address)
        // Port comes from the Port field; if the user pasted host:port into the
        // address, honour that inline port too.
        let port = inlinePort(from: address) ?? Int(portText.trimmingCharacters(in: .whitespaces))

        let kind = selectedTransport
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
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        // Strip an inline :port (not IPv6).
        if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
            s = String(s[..<colon])
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func inlinePort(from raw: String) -> Int? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        guard s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") else { return nil }
        return Int(s[s.index(after: colon)...])
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
        return components.percentEncodedPath.isEmpty
            ? "/"
            : components.percentEncodedPath
    }

    private func enterSMBLocation() {
        step = .pickLocation
        loadSMBShares()
    }

    // MARK: - NFS / SFTP / FTP (path-entry transports)

    /// Extracts the literal, decoded root path a user typed in the address
    /// (`host/movies`, `nfs://host/export`, `sftp://host:22/media`). Unlike the
    /// WebDAV path helper this keeps the path literal (filesystem transports
    /// address by decoded names), defaulting to `/` when none is given.
    private func filesystemPath(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        guard let slash = s.firstIndex(of: "/") else { return "/" }
        let path = String(s[slash...])
        return path.isEmpty ? "/" : path
    }

    /// SFTP first-connect: capture the server's host key (and confirm the
    /// credentials authenticate) in one `.captureTrustOnFirstUse` connect, then
    /// route to the verify step for explicit approval before pinning + saving.
    private func beginSFTP(host: String, port: Int) {
        workTask?.cancel()
        detecting = true
        let user = username.trimmingCharacters(in: .whitespaces)
        let pass = password
        workTask = Task { [sftpProbe] in
            defer { self.detecting = false }
            let result = await sftpProbe.captureHostKey(
                host: host,
                port: port,
                username: user,
                password: pass
            )
            if Task.isCancelled { return }
            switch result {
            case .success(let sha256):
                self.pendingSFTPHostKey = sha256
                self.step = .verifyTrust(sha256: sha256)
            case .authenticationFailed:
                self.connectError = "That username or password was rejected."
            case .unreachable:
                self.connectError = "Couldn’t reach that server. Check the address and network."
            case .failed(let message):
                self.connectError = message
            case .cancelled:
                break
            }
        }
    }

    /// Lists the child directories of the current SFTP path so the user can drill
    /// into a subfolder before saving. Reuses the captured + approved host key and
    /// the form credentials; reconnects per call (onboarding is low-frequency).
    func loadSFTPFolders(path: String) async {
        guard let pin = approvedHostKeyPin else { return }
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
            currentPath = path
            confirmedPath = path
            locations = dirs.map { LocationItem(name: $0.name, path: $0.path, isBrowsable: true) }
            locationLoad = .loaded
        case .authenticationFailed:
            locationLoad = .badCredentials
        case .unreachable:
            locationLoad = .unreachable
        case .failed(let message):
            locationLoad = .failed(message)
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
        workTask = Task { await self.loadNFSExports() }
    }

    func loadNFSExports() async {
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
                locations = exports.map { LocationItem(name: $0.name, path: $0.path, isBrowsable: false) }
                locationLoad = .loaded
            }
        case .unreachable:
            locationLoad = .unreachable
        case .permissionDenied:
            locationLoad = .failed("This server didn’t allow listing exports. Enter the export path, e.g. /volume1/Media.")
        case .failed(let message):
            locationLoad = .failed(message)
        }
    }

    /// Save a chosen NFS export (from the advertised list) as the share root.
    func chooseNFSExport(_ path: String) {
        confirmedPath = path.hasPrefix("/") ? path : "/" + path
        chooseFilesystemRoot()
    }

    /// Save a manually-typed NFS export path (fallback when EXPORT is blocked).
    func chooseNFSManualExport() {
        let trimmed = manualShare.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        confirmedPath = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        chooseFilesystemRoot()
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
                self.connectError = message
            case .cancelled:
                break
            }
        }
    }

    /// Lists the child directories of the current FTP path. Reconnects per call
    /// (onboarding is low-frequency), mirroring the WebDAV/SFTP browsers. Used for
    /// drilling AFTER the first connect already validated credentials.
    func loadFTPFolders(path: String) async {
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
            currentPath = path
            confirmedPath = path
            locations = dirs.map { LocationItem(name: $0.name, path: $0.path, isBrowsable: true) }
            locationLoad = .loaded
        case .authenticationFailed:
            locationLoad = .badCredentials
        case .unreachable:
            locationLoad = .unreachable
        case .failed(let message):
            locationLoad = .failed(message)
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
    func chooseFilesystemRoot() {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let path = confirmedPath
        switch selectedTransport {
        case .nfs:
            onMediaShareConfigured(.nfs(NFSShareConfiguration(
                host: resolvedHost,
                port: resolvedPort,
                exportPath: path,
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
            let auth: AppState.FTPShareAuth = (user.isEmpty && password.isEmpty)
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

    func loadSMBShares() {
        workTask?.cancel()
        locationLoad = .loading
        locations = []
        let host = resolvedHost, port = resolvedPort
        let user = username, pass = password
        workTask = Task {
            do {
                let names = try await SMBShareEnumerator.listShares(host: host, port: port, username: user, password: pass)
                if Task.isCancelled { return }
                self.locations = names.map { LocationItem(name: $0, path: $0, isBrowsable: false) }
                self.locationLoad = .loaded
            } catch SMBShareEnumerator.ListError.authenticationRequired {
                if !Task.isCancelled { self.locationLoad = .needsAuth }
            } catch SMBShareEnumerator.ListError.credentialsRejected {
                if !Task.isCancelled { self.locationLoad = .badCredentials }
            } catch SMBShareEnumerator.ListError.unreachable, SMBShareEnumerator.ListError.timedOut {
                if !Task.isCancelled { self.locationLoad = .unreachable }
            } catch {
                if !Task.isCancelled { self.locationLoad = .failed("Something went wrong talking to this server.") }
            }
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
                switch await self.webDAVProbe.preflightTrust(url: url) {
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

    func approveTrust() {
        guard case .verifyTrust(let sha256) = step else { return }
        // SFTP: the fingerprint is an SSH host key already captured by the connect
        // probe. Approving pins it and opens a folder browser rooted at the typed
        // path (or `/`), so the user can drill into a subfolder to use as the share
        // root. The credentials were already validated during capture.
        if let hostKey = pendingSFTPHostKey {
            pendingSFTPHostKey = nil
            approvedHostKeyPin = hostKey
            step = .pickLocation
            let start = filesystemPath(from: address)
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

    func rejectTrust() {
        trust = .system; approvedPin = nil
        pendingWebDAVURL = nil
        pendingSFTPHostKey = nil
        approvedHostKeyPin = nil
        step = .connect
    }

    private func validateAndBrowseWebDAV(url: URL) async {
        let credential = webDAVCredential()
        switch await webDAVProbe.validate(url: url, credential: credential, trust: trust) {
        case .success:
            break
        case .failure(let error):
            self.connectError = Self.webDAVMessage(error)
            self.step = .connect
            return
        }
        webDAVOriginURL = originURL(of: url)
        await loadWebDAVFolders(path: "/")
        if connectError == nil { step = .pickLocation }
    }

    private var webDAVOriginURL: URL?

    func loadWebDAVFolders(path: String) async {
        guard let origin = webDAVOriginURL else { return }
        locationLoad = .loading
        switch await webDAVProbe.listFolders(url: origin, path: path, credential: webDAVCredential(), trust: trust) {
        case .success(let folders):
            currentPath = path
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

    private var webDAVShareAuth: AppState.WebDAVShareAuth {
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

    /// Confirm an SMB share by name (from the list or typed).
    func chooseSMBShare(_ share: String) {
        let trimmed = share.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let name = displayName.trimmingCharacters(in: .whitespaces)
        onSMBConfigured(ShareDraft(
            host: resolvedHost,
            port: resolvedPort,
            share: trimmed,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            displayName: name.isEmpty ? (trimmed.isEmpty ? resolvedHost : trimmed) : name
        ))
    }

    /// Confirm the current WebDAV folder as the share root.
    func chooseWebDAVFolder(_ path: String) {
        guard let origin = webDAVOriginURL,
              var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return }
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

    // MARK: - Back navigation

    func backToDevices() {
        workTask?.cancel()
        step = .chooseDevice
        resetForm()
        selectedTransport = .smb
        detectedDoors = []
        startScan()
    }

    func backToConnect() {
        workTask?.cancel()
        step = .connect
        locations = []; locationLoad = .idle
    }

    // MARK: - Copy

    private static func webDAVMessage(_ error: WebDAVOnboardingError) -> String {
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
#endif
