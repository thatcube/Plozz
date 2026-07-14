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
    /// nil = "Auto-detect" (manual path); otherwise the chosen transport.
    var selectedTransport: MediaShareTransportKind?
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
    private var trust: WebDAVOnboardingTrust = .system
    private var approvedPin: Data?

    // Outputs
    var onSMBConfigured: (ShareDraft) -> Void = { _ in }
    var onWebDAVConfigured: (WebDAVShareConfiguration) -> Void = { _ in }

    private let discovery: BonjourServiceDiscovery
    private let sweeper = MediaSharePortSweeper()
    private let webDAVProbe: any WebDAVOnboardingProbing
    private let routeDetector = MediaShareRouteDetector()
    private var scanTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?

    init(webDAVProbe: any WebDAVOnboardingProbing = WebDAVOnboardingProbe()) {
        self.webDAVProbe = webDAVProbe
        self.discovery = BonjourServiceDiscovery(mapping: Self.mapping)
    }

    // MARK: - Catalog-derived config

    private static let mapping = BonjourTransportMapping(
        MediaShareTransportCatalog.all.flatMap { descriptor in
            descriptor.bonjourServiceTypes.map {
                (serviceType: $0, transport: descriptor.kind, defaultPort: Optional(descriptor.defaultPort))
            }
        }
    )
    private static let sweepSpecs = MediaShareTransportCatalog.all.map {
        TransportSweepSpec(transport: $0.kind, ports: $0.sweepPorts, defaultPort: $0.defaultPort)
    }

    func descriptor(_ kind: MediaShareTransportKind) -> TransportOnboardingDescriptor? {
        MediaShareTransportCatalog.descriptor(for: kind)
    }

    // MARK: - Discovery

    func startScan() {
        scanTask?.cancel()
        boxes = []
        scanning = true
        scanTask = Task { [discovery] in
            var services: [DiscoveredNetworkService] = []
            for await service in discovery.discover(timeout: 6) {
                if Task.isCancelled { break }
                services.append(service)
                self.boxes = MediaShareBoxGrouping.group(services)
            }
            if !Task.isCancelled { self.scanning = false }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        scanning = false
    }

    // MARK: - Entering the Connect form

    /// Open the Connect form pre-filled from a discovered device. Kicks off a
    /// curated port sweep to reveal non-advertised doors.
    func openConnect(for box: DiscoveredMediaShareBox) {
        stopScan()
        resetForm()
        address = box.host
        detectedDoors = box.doors
        let best = MediaShareTransportCatalog.preferredKind(among: box.doors.map(\.transport))
        applyTransport(best, doors: box.doors)
        step = .connect
        // Channel B: sweep for more doors on this known host.
        let host = box.host
        Task { [sweeper] in
            let found = await sweeper.sweep(host: host, specs: Self.sweepSpecs)
            guard !Task.isCancelled, self.address == host else { return }
            var merged = self.detectedDoors
            for door in found where !merged.contains(where: { $0.transport == door.transport }) {
                merged.append(door)
            }
            self.detectedDoors = merged
        }
    }

    /// Open the Connect form blank for a typed address (Auto-detect).
    func openManualConnect() {
        stopScan()
        resetForm()
        detectedDoors = []
        selectedTransport = nil // Auto-detect
        step = .connect
    }

    private func resetForm() {
        connectError = nil
        username = ""; password = ""; token = ""; manualShare = ""; displayName = ""
        portText = ""
        authMode = .usernamePassword
        locations = []; locationLoad = .idle; currentPath = "/"
        trust = .system; approvedPin = nil
    }

    /// Set the chosen protocol and prefill the port from a detected door (or the
    /// transport default).
    func applyTransport(_ kind: MediaShareTransportKind?, doors: [DiscoveredMediaShareBox.Door]? = nil) {
        selectedTransport = kind
        guard let kind, let descriptor = descriptor(kind) else { portText = ""; return }
        let doorList = doors ?? detectedDoors
        if let door = doorList.first(where: { $0.transport == kind }) {
            portText = door.port.map(String.init) ?? String(descriptor.defaultPort)
        } else {
            portText = String(descriptor.defaultPort)
        }
        // Token mode only exists for WebDAV; reset otherwise.
        if !descriptor.authModes.contains(.token) { authMode = .usernamePassword }
    }

    /// Ports detected for a given transport (drives the port chips).
    func detectedPorts(for kind: MediaShareTransportKind) -> [Int] {
        let descriptor = descriptor(kind)
        return detectedDoors
            .filter { $0.transport == kind }
            .map { $0.port ?? (descriptor?.defaultPort ?? 0) }
    }

    var canConnect: Bool {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let kind = selectedTransport, let descriptor = descriptor(kind) else {
            return true // Auto-detect only needs an address
        }
        if descriptor.authModes.isEmpty { return true } // NFS: no creds
        if !descriptor.allowsBlankGuest, authMode == .usernamePassword {
            return !username.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    /// The plaintext-credential warning to show for the current form, if any.
    var plaintextWarning: String? {
        guard let kind = selectedTransport, let descriptor = descriptor(kind) else { return nil }
        switch descriptor.plaintextCredentialRisk {
        case .never:
            return nil
        case .always:
            return "This transport sends your username and password unencrypted. On a trusted home network that’s usually fine."
        case .whenInsecureScheme:
            let lower = address.lowercased()
            let insecure = lower.hasPrefix("http://") || (!lower.hasPrefix("https://") && portIs(80))
            let hasCredential = authMode == .token ? !token.isEmpty : !username.isEmpty
            return (insecure && hasCredential)
                ? "This uses http://, so your credential is sent unencrypted. Use https:// to encrypt it."
                : nil
        }
    }

    private func portIs(_ p: Int) -> Bool { Int(portText.trimmingCharacters(in: .whitespaces)) == p }

    // MARK: - Connect

    func connect() {
        workTask?.cancel()
        connectError = nil
        let host = normalizedHost(address)
        let port = Int(portText.trimmingCharacters(in: .whitespaces))

        guard let kind = selectedTransport else {
            autoDetectThenConnect(rawAddress: address)
            return
        }
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
            beginWebDAV(host: host, port: port)
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

    private func autoDetectThenConnect(rawAddress: String) {
        detecting = true
        let addressForDetection: String = {
            let raw = rawAddress.trimmingCharacters(in: .whitespaces)
            if let p = Int(portText.trimmingCharacters(in: .whitespaces)),
               !raw.contains("/"), raw.filter({ $0 == ":" }).count == 0 {
                return "\(raw):\(p)"
            }
            return raw
        }()
        workTask = Task { [routeDetector] in
            let result = await routeDetector.detect(address: addressForDetection)
            if Task.isCancelled { return }
            self.detecting = false
            switch result {
            case .success(.smb(let host, let port)):
                self.applyTransport(.smb)
                self.address = host
                if let port { self.portText = String(port) }
                self.selectedTransport = .smb
                self.resolvedHost = host; self.resolvedPort = port
                self.enterSMBLocation()
            case .success(.webDAV(let url, _)):
                self.selectedTransport = .webDAV
                self.address = url.absoluteString
                self.beginWebDAV(url: url)
            case .failure:
                self.connectError = "Couldn’t reach a share there. Check the address, or pick a protocol and try again."
            }
        }
    }

    // MARK: - SMB location (real backend)

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

    private func beginWebDAV(host: String, port: Int?) {
        // Build a base URL. Prefer the exact typed address if it had a scheme;
        // otherwise assume https unless the port is the http default.
        let scheme = (port == 80) ? "http" : "https"
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host.contains(":") ? "[\(host)]" : host
        if let port, port != (scheme == "https" ? 443 : 80) { comps.port = port }
        comps.path = ""
        guard let url = comps.url else {
            connectError = "That doesn’t look like a valid address."
            return
        }
        beginWebDAV(url: url)
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
        selectedTransport = nil
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
