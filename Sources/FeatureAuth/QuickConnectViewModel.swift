import Foundation
import Observation
import CoreModels

/// View model for the Quick Connect screen.
///
/// Owns the challenge lifecycle and exposes a simple `phase` the view renders.
/// On success it hands back a `UserSession` via `onAuthenticated` so the parent
/// coordinator can persist it and advance the session state machine.
@MainActor
@Observable
public final class QuickConnectViewModel {
    public enum Phase: Equatable {
        case idle
        case requesting
        case awaitingApproval(code: String, expiresAt: Date)
        case success
        case error(String)
    }

    public private(set) var phase: Phase = .idle

    /// How long each issued code stays valid; drives the on-screen countdown.
    public var codeLifetime: TimeInterval { service.timeout }

    private let service: QuickConnectService
    private let onAuthenticated: (UserSession) -> Void
    private var flow: Task<Void, Never>?

    public init(
        service: QuickConnectService,
        onAuthenticated: @escaping (UserSession) -> Void
    ) {
        self.service = service
        self.onAuthenticated = onAuthenticated
    }

    /// Starts (or restarts) the whole Quick Connect flow.
    ///
    /// Keeps a live code on screen indefinitely: as soon as one lapses without
    /// approval it requests a fresh one, so the user never has to hit "retry".
    public func start() {
        flow?.cancel()
        phase = .requesting
        flow = Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    try Task.checkCancellation()
                    let challenge = try await service.begin()
                    try Task.checkCancellation()
                    let expiresAt = Date().addingTimeInterval(service.timeout)
                    self.phase = .awaitingApproval(code: challenge.userCode, expiresAt: expiresAt)

                    switch try await Self.awaitApprovalOrExpiry(service: service, challenge: challenge, expiresAt: expiresAt) {
                    case let .approved(session):
                        self.phase = .success
                        self.onAuthenticated(session)
                        return
                    case .expired:
                        continue // Transparently issue a fresh code.
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

    private enum ApprovalOutcome {
        case approved(UserSession)
        case expired
    }

    /// Races the approval poll against a wall-clock expiry watchdog. The
    /// watchdog guarantees we regenerate at the deadline even if a poll request
    /// stalls, so the screen can never get stranded on an expired code.
    private static func awaitApprovalOrExpiry(
        service: QuickConnectService,
        challenge: QuickConnectChallenge,
        expiresAt: Date
    ) async throws -> ApprovalOutcome {
        try await withThrowingTaskGroup(of: ApprovalOutcome.self) { group in
            group.addTask {
                do {
                    return .approved(try await service.awaitApproval(for: challenge))
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

    /// Cancels any in-flight polling (Cancel button / view disappears).
    public func cancel() {
        flow?.cancel()
        flow = nil
    }

    public func retry() {
        start()
    }
}
