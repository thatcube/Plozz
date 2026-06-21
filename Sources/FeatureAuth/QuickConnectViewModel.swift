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
        case awaitingApproval(code: String)
        case success
        case error(String)
    }

    public private(set) var phase: Phase = .idle

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
    public func start() {
        flow?.cancel()
        phase = .requesting
        flow = Task { [weak self] in
            guard let self else { return }
            do {
                let challenge = try await service.begin()
                if Task.isCancelled { return }
                self.phase = .awaitingApproval(code: challenge.userCode)

                let session = try await service.awaitApproval(for: challenge)
                if Task.isCancelled { return }
                self.phase = .success
                self.onAuthenticated(session)
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

    /// Cancels any in-flight polling (Cancel button / view disappears).
    public func cancel() {
        flow?.cancel()
        flow = nil
    }

    public func retry() {
        start()
    }
}
