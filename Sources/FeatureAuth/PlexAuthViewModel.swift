import Foundation
import Observation
import CoreModels
import ProviderPlex

/// View model for the Plex PIN-link screen.
///
/// Owns the link lifecycle and exposes a simple `phase` the view renders. On
/// success it hands back a `UserSession` via `onAuthenticated` so the parent
/// coordinator can persist it and advance the session state machine.
@MainActor
@Observable
public final class PlexAuthViewModel {
    public enum Phase: Equatable {
        case idle
        case requesting
        case awaitingLink(code: String, expiresAt: Date)
        case loadingServers
        case selectingServer([PlexServerCandidate])
        case success
        case error(String)
    }

    public private(set) var phase: Phase = .idle

    /// How long an issued code stays valid; drives the on-screen countdown.
    public var codeLifetime: TimeInterval { service.timeout }

    private let service: PlexAuthService
    private let onAuthenticated: (UserSession) -> Void
    private var flow: Task<Void, Never>?
    private var authToken: String?

    public init(
        service: PlexAuthService,
        onAuthenticated: @escaping (UserSession) -> Void
    ) {
        self.service = service
        self.onAuthenticated = onAuthenticated
    }

    /// Starts (or restarts) the whole PIN-link flow.
    ///
    /// Keeps a live code (and QR) on screen indefinitely: as soon as one lapses
    /// without being linked it requests a fresh one, so the user never has to
    /// hit "retry" — mirroring the Jellyfin Quick Connect screen.
    public func start() {
        flow?.cancel()
        phase = .requesting
        flow = Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    try Task.checkCancellation()
                    let pin = try await service.begin()
                    try Task.checkCancellation()
                    let expiresAt = Date().addingTimeInterval(service.timeout)
                    self.phase = .awaitingLink(code: pin.code, expiresAt: expiresAt)

                    switch try await Self.awaitLinkOrExpiry(service: service, pin: pin, expiresAt: expiresAt) {
                    case let .linked(token):
                        try Task.checkCancellation()
                        self.authToken = token
                        self.phase = .loadingServers

                        let servers = try await service.servers(authToken: token)
                        try Task.checkCancellation()
                        switch servers.count {
                        case 0:
                            self.phase = .error("No Plex servers are available on this account.")
                        case 1:
                            try await self.finish(with: servers[0], token: token)
                        default:
                            self.phase = .selectingServer(servers)
                        }
                        return
                    case .expired:
                        continue // Transparently issue a fresh code + QR.
                    }
                }
            } catch is CancellationError {
                // Cancelled by the user; leave phase as-is (view is dismissing).
            } catch let error as AppError {
                if error == .cancelled { return }
                self.phase = .error(error.userMessage)
            } catch {
                self.phase = .error(AppError.unknown("").userMessage)
            }
        }
    }

    private enum LinkOutcome {
        case linked(String)
        case expired
    }

    /// Races the link poll against a wall-clock expiry watchdog. The watchdog
    /// guarantees we regenerate at the deadline even if a poll request stalls,
    /// so the screen can never get stranded on an expired code.
    private static func awaitLinkOrExpiry(
        service: PlexAuthService,
        pin: PlexPinChallenge,
        expiresAt: Date
    ) async throws -> LinkOutcome {
        try await withThrowingTaskGroup(of: LinkOutcome.self) { group in
            group.addTask {
                do {
                    return .linked(try await service.awaitLink(for: pin))
                } catch let error as AppError where error == .quickConnectExpired {
                    return .expired
                }
            }
            group.addTask {
                let remaining = expiresAt.timeIntervalSinceNow
                if remaining > 0 {
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                return .expired
            }
            let outcome = try await group.next()!
            group.cancelAll()
            return outcome
        }
    }

    /// Completes sign-in for a server the user picked from the list.
    public func selectServer(_ candidate: PlexServerCandidate) {
        guard let token = authToken else { return }
        flow?.cancel()
        phase = .loadingServers
        flow = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.finish(with: candidate, token: token)
            } catch is CancellationError {
                // Dismissing.
            } catch let error as AppError {
                self.phase = .error(error.userMessage)
            } catch {
                self.phase = .error(AppError.unknown("").userMessage)
            }
        }
    }

    private func finish(with candidate: PlexServerCandidate, token: String) async throws {
        let session = try await service.makeSession(for: candidate, authToken: token)
        try Task.checkCancellation()
        phase = .success
        onAuthenticated(session)
    }

    /// Cancels any in-flight work (Cancel button / view disappears).
    public func cancel() {
        flow?.cancel()
        flow = nil
    }

    public func retry() {
        start()
    }
}
