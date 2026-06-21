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
    public var manualURLText: String = ""

    private let discovery: ServerDiscovering
    private let validator: ServerValidator
    private let store: LastServerStoring
    private var scanTask: Task<Void, Never>?

    public init(
        discovery: ServerDiscovering = UDPServerDiscovery(),
        validator: ServerValidator = ServerValidator(),
        store: LastServerStoring = UserDefaultsLastServerStore()
    ) {
        self.discovery = discovery
        self.validator = validator
        self.store = store
    }

    /// The previously-used server, offered as a one-tap reconnect option.
    public var lastServer: MediaServer? { store.lastServer }

    /// Starts a LAN scan, appending servers as they answer.
    public func startScan(timeout: TimeInterval = 5) {
        scanTask?.cancel()
        discoveredServers = []
        phase = .scanning
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
        if case .scanning = phase { phase = .idle }
    }

    private func merge(_ server: MediaServer) {
        if !discoveredServers.contains(where: { $0.id == server.id }) {
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

    /// Persists the chosen server as the "last successful" one.
    public func select(_ server: MediaServer) {
        store.lastServer = server
        phase = .idle
    }
}
