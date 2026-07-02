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

    /// Live status of a server row, driving its trailing badge.
    public enum ServerStatus: Equatable, Sendable {
        /// Heard from on the local network during this scan.
        case onNetwork
        /// Not on the LAN, but a direct probe confirmed it's reachable
        /// (e.g. a remote or Tailscale server).
        case online
        /// A direct probe failed — likely offline or unreachable right now.
        case offline
        /// Not yet determined (probe still running, or never probed).
        case unknown
    }

    public private(set) var phase: Phase = .idle
    public private(set) var discoveredServers: [MediaServer] = []
    /// Whether this Apple TV is currently connected to a Tailscale network.
    /// Drives the conditional Tailscale guidance in the picker.
    public private(set) var isOnTailscale: Bool = false
    /// This device's own Tailscale IPv4 address when connected. Retained for
    /// detection/telemetry; the picker no longer surfaces it to the user.
    public private(set) var tailscaleIP: String?
    public var manualURLText: String = ""

    /// Per-server reachability from direct probes, keyed by `ServerIdentity.key`.
    private var reachabilityByKey: [String: Bool] = [:]
    /// Servers heard from on the LAN during the current scan, keyed the same way.
    private var lanKeys: Set<String> = []

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

    /// Recently-used servers, most-recent first, offered as one-tap reconnects.
    /// Includes manually-entered and Tailscale servers that LAN discovery can't
    /// re-find on its own.
    public var recentServers: [MediaServer] { store.recentServers }

    /// The single most-recently-used server, if any.
    public var lastServer: MediaServer? { store.lastServer }

    /// Reachability of the most-recent server, derived from its live status.
    /// Kept as a convenience for callers (and tests) that only care about the
    /// primary reconnect target.
    public var lastServerReachable: Bool? {
        guard let last = store.recentServers.first else { return nil }
        switch status(for: last) {
        case .onNetwork, .online: return true
        case .offline: return false
        case .unknown: return nil
        }
    }

    /// The live status for a server row (LAN presence + probe result).
    public func status(for server: MediaServer) -> ServerStatus {
        let key = ServerIdentity.key(for: server)
        if lanKeys.contains(key) { return .onNetwork }
        switch reachabilityByKey[key] {
        case .some(true): return .online
        case .some(false): return .offline
        case .none: return .unknown
        }
    }

    /// Starts a LAN scan, appending servers as they answer. In parallel, probes
    /// every recent server directly so we can tell the user whether each is
    /// online even when broadcast discovery comes back empty.
    public func startScan(timeout: TimeInterval = 6) {
        scanTask?.cancel()
        reachabilityTask?.cancel()
        discoveredServers = []
        lanKeys = []
        reachabilityByKey = [:]
        phase = .scanning
        refreshTailscaleState()

        probeRecents()

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

    /// Directly probes each recent server (most-recent first) to confirm it's
    /// online, so remote/Tailscale entries show a real status without waiting
    /// on LAN discovery. Probing the primary reconnect target first keeps its
    /// status snappy.
    private func probeRecents() {
        let recents = store.recentServers
        guard !recents.isEmpty else { return }
        reachabilityTask = Task { [weak self] in
            guard let self else { return }
            for server in recents {
                if Task.isCancelled { return }
                let key = ServerIdentity.key(for: server)
                // Discovery may already have proven it's on the LAN — that's a
                // stronger signal than a probe, so don't overwrite it.
                if self.lanKeys.contains(key) { continue }
                let reachable = await self.validator.isReachable(server.baseURL)
                if Task.isCancelled { return }
                if self.lanKeys.contains(key) { continue }
                self.reachabilityByKey[key] = reachable
            }
        }
    }

    private func merge(_ server: MediaServer) {
        let key = ServerIdentity.key(for: server)
        // Hearing from a server on the LAN is definitive: mark it present and
        // reachable so its row (recent or discovered) reads "On your network".
        lanKeys.insert(key)
        // A server already in the recents list is shown there — don't also list
        // it under discovered.
        if store.recentServers.contains(where: { ServerIdentity.isSame($0, server) }) { return }
        if !discoveredServers.contains(where: { ServerIdentity.isSame($0, server) }) {
            discoveredServers.append(server)
        }
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

    /// Records the chosen server at the top of the recents list.
    public func select(_ server: MediaServer) {
        store.remember(server)
        phase = .idle
    }
}
