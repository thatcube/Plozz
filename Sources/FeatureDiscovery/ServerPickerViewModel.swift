import Foundation
import Observation
import CoreModels

/// Drives the server picker: runs LAN discovery, validates manual entries, and
/// remembers the last successful server.
@MainActor
@Observable
public final class ServerPickerViewModel {
    public enum Phase: Equatable {
        case idle
        case scanning
        case validating
        case error(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var discoveredServers: [MediaServer] = []
    /// Whether this Apple TV is currently connected to a Tailscale network.
    /// Drives the conditional Tailscale guidance in the picker.
    public private(set) var isOnTailscale: Bool = false
    /// This device's own Tailscale IPv4 address when connected, for display.
    public private(set) var tailscaleIP: String?
    /// Reachability of `lastServer`: `nil` while unknown/checking, then the
    /// result of a live probe (or `true` the moment LAN discovery re-finds it).
    public private(set) var lastServerReachable: Bool?
    public var manualURLText: String = ""

    private let discovery: ServerDiscovering
    private let validator: ServerValidator
    private var store: LastServerStoring
    private var scanTask: Task<Void, Never>?
    private var reachabilityTask: Task<Void, Never>?

    #if canImport(Network)
    public init(
        discovery: ServerDiscovering = UDPServerDiscovery(),
        validator: ServerValidator = ServerValidator(),
        store: LastServerStoring = UserDefaultsLastServerStore()
    ) {
        self.discovery = discovery
        self.validator = validator
        self.store = store
    }
    #else
    public init(
        discovery: ServerDiscovering,
        validator: ServerValidator = ServerValidator(),
        store: LastServerStoring = UserDefaultsLastServerStore()
    ) {
        self.discovery = discovery
        self.validator = validator
        self.store = store
    }
    #endif

    /// The previously-used server, offered as a one-tap reconnect option.
    public var lastServer: MediaServer? { store.lastServer }

    /// Starts a LAN scan, appending servers as they answer. In parallel, probes
    /// the saved server directly so we can tell the user whether it's online
    /// even when broadcast discovery comes back empty.
    public func startScan(timeout: TimeInterval = 6) {
        scanTask?.cancel()
        reachabilityTask?.cancel()
        discoveredServers = []
        phase = .scanning
        refreshTailscaleState()

        if store.lastServer != nil {
            lastServerReachable = nil
            startReachabilityProbe()
        }

        scanTask = Task { [weak self] in
            guard let self else { return }
            for await server in discovery.discover(timeout: timeout) {
                if Task.isCancelled { break }
                self.merge(server)
            }
            if case .scanning = self.phase { self.phase = .idle }
        }
    }

    public func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        reachabilityTask?.cancel()
        reachabilityTask = nil
        if case .scanning = phase { phase = .idle }
    }

    /// Re-evaluates whether this device is on a tailnet by inspecting local
    /// network interfaces. Cheap and synchronous, so it runs on each scan.
    private func refreshTailscaleState() {
        tailscaleIP = TailscaleDetector.localTailscaleIP()
        isOnTailscale = tailscaleIP != nil
    }

    /// Directly hits the saved server's public endpoint to confirm it's online.
    private func startReachabilityProbe() {
        guard let last = store.lastServer else { return }
        reachabilityTask = Task { [weak self] in
            guard let self else { return }
            let reachable = await validator.isReachable(last.baseURL)
            if Task.isCancelled { return }
            // Don't override a positive result already established by discovery.
            if self.lastServerReachable == nil {
                self.lastServerReachable = reachable
            }
        }
    }

    private func merge(_ server: MediaServer) {
        // If the LAN scan re-finds the saved server, surface it as "online"
        // rather than listing it twice (once here, once under "Recently used").
        if isLastServer(server) {
            lastServerReachable = true
            return
        }
        if !discoveredServers.contains(where: { isSameServer($0, server) }) {
            discoveredServers.append(server)
        }
    }

    /// Whether `server` is the same box as the saved last-used server, matched
    /// by Jellyfin server id when available, else by host + port.
    private func isLastServer(_ server: MediaServer) -> Bool {
        guard let last = store.lastServer else { return false }
        return isSameServer(server, last)
    }

    private func isSameServer(_ a: MediaServer, _ b: MediaServer) -> Bool {
        if !a.id.isEmpty, !b.id.isEmpty, a.id == b.id { return true }
        return a.baseURL.host == b.baseURL.host && a.baseURL.port == b.baseURL.port
    }

    /// Validates and selects a manually entered URL. Returns the server on
    /// success; updates `phase` to `.error` on failure.
    @discardableResult
    public func submitManualURL() async -> MediaServer? {
        let text = manualURLText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        phase = .validating
        do {
            let server = try await validator.validate(rawURL: text)
            select(server)
            return server
        } catch let error as AppError {
            phase = .error(error.userMessage)
            return nil
        } catch {
            phase = .error(AppError.serverUnreachable.userMessage)
            return nil
        }
    }

    /// Persists the chosen server as the "last successful" one.
    public func select(_ server: MediaServer) {
        store.lastServer = server
        phase = .idle
    }
}
