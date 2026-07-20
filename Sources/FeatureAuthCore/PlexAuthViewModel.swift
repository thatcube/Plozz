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
        case awaitingLink(code: String, authorizationURL: URL, expiresAt: Date)
        case loadingServers
        case selectingServer([PlexServerCandidate])
        case error(String)
    }

    public private(set) var phase: Phase = .idle

    /// How long an issued code stays valid; drives the on-screen countdown.
    public var codeLifetime: TimeInterval { service.timeout }

    private let service: PlexAuthService
    private let onAuthenticated: (UserSession) -> Void
    private let onAuthenticatedMany: ([UserSession]) -> Void
    private var flow: Task<Void, Never>?
    private var authToken: String?

    public init(
        service: PlexAuthService,
        onAuthenticated: @escaping (UserSession) -> Void,
        onAuthenticatedMany: @escaping ([UserSession]) -> Void = { _ in }
    ) {
        self.service = service
        self.onAuthenticated = onAuthenticated
        self.onAuthenticatedMany = onAuthenticatedMany
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
                    async let manualPinRequest = service.begin()
                    async let hostedPinRequest = service.begin(strong: true)
                    let (manualPin, hostedPin) = try await (manualPinRequest, hostedPinRequest)
                    try Task.checkCancellation()
                    let expiresAt = Date().addingTimeInterval(service.timeout)
                    self.phase = .awaitingLink(
                        code: manualPin.code,
                        authorizationURL: service.authorizationURL(for: hostedPin),
                        expiresAt: expiresAt
                    )

                    switch try await Self.awaitLinkOrExpiry(
                        service: service,
                        pins: [manualPin, hostedPin],
                        expiresAt: expiresAt
                    ) {
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
            } catch let error as PlexPinError {
                self.phase = .error(error.userMessage)
            } catch let error as AppError {
                if error == .cancelled { return }
                self.phase = .error(error.userMessage)
            } catch {
                self.phase = .error(AppError.unknown("").userMessage)
            }
        }
    }

    /// Starts the flow when a host has not already begun preloading it.
    public func startIfNeeded() {
        guard flow == nil else { return }
        start()
    }

    enum LinkOutcome: Equatable, Sendable {
        case linked(String)
        case expired
    }

    /// Races the link poll against a wall-clock expiry watchdog. The watchdog
    /// guarantees we regenerate at the deadline even if a poll request stalls,
    /// so the screen can never get stranded on an expired code.
    nonisolated static func awaitLinkOrExpiry(
        service: PlexAuthService,
        pins: [PlexPinChallenge],
        expiresAt: Date
    ) async throws -> LinkOutcome {
        try await withThrowingTaskGroup(of: LinkOutcome.self) { group in
            for (index, pin) in pins.enumerated() {
                group.addTask {
                    do {
                        let initialDelay = index == 0 ? 0 : service.pollInterval / 2
                        return .linked(try await service.awaitLink(
                            for: pin,
                            initialDelay: initialDelay
                        ))
                    } catch let error as AppError where error == .quickConnectExpired {
                        return .expired
                    }
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
        selectServers([candidate])
    }

    /// Completes sign-in for every server the user checked, adding one account
    /// per server. Hands them all back at once so onboarding continues a single
    /// time after all accounts are persisted.
    public func selectServers(_ candidates: [PlexServerCandidate]) {
        guard let token = authToken, !candidates.isEmpty else { return }
        flow?.cancel()
        phase = .loadingServers
        flow = Task { [weak self] in
            guard let self else { return }
            do {
                var sessions: [UserSession] = []
                for candidate in candidates {
                    try Task.checkCancellation()
                    sessions.append(try await self.service.makeSession(for: candidate, authToken: token))
                }
                try Task.checkCancellation()
                if sessions.count == 1 {
                    self.onAuthenticated(sessions[0])
                } else {
                    self.onAuthenticatedMany(sessions)
                }
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
