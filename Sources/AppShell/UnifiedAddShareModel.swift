#if canImport(SwiftUI)
import Foundation
import Observation
import CoreModels
import FeatureAuth
import ProviderShare
import MediaTransportHTTP

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

    private let discovery: BonjourServiceDiscovery
    private let sweeper = MediaSharePortSweeper()
    private let serviceProbe: any MediaShareServiceProbing
    private let webDAVProbe: any WebDAVOnboardingProbing
    private var scanTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var sweptHosts = Set<String>()
    /// Every detected door per host, keeping ALL ports (advertised + swept) so a
    /// specific configured port like WebDAV :8384 is never lost to de-duplication.
    private var fullDoorsByHost: [String: [DiscoveredMediaShareBox.Door]] = [:]

    init(
        webDAVProbe: any WebDAVOnboardingProbing = WebDAVOnboardingProbe(),
        serviceProbe: any MediaShareServiceProbing = ProtocolServiceProbe()
    ) {
        self.webDAVProbe = webDAVProbe
        self.serviceProbe = serviceProbe
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
            return "This connection is not encrypted."
        case .whenInsecureScheme:
            let explicit = explicitScheme(from: address)
            let scheme = explicit
                ?? ((webDAVSchemePort == currentPort) ? webDAVScheme : nil)
                ?? (portIs(80) ? "http" : nil)
            let insecure = scheme == "http"
            return insecure
                ? "HTTP connection is not encrypted."
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
        default:
            step = .comingSoon(kind)
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
        guard case .verifyTrust(let sha256) = step, let url = pendingWebDAVURL else { return }
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
