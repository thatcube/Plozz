import Foundation
import Observation
import CoreModels

/// View model for the username/password sign-in screen.
///
/// Mirrors `QuickConnectViewModel`'s shape (a single `phase` the view renders,
/// success handed back via `onAuthenticated`) so the two auth paths stay
/// interchangeable for the parent coordinator.
@MainActor
@Observable
public final class PasswordSignInViewModel {
    public enum Phase: Equatable {
        case idle
        case submitting
        case success
        case error(String)
    }

    public var username: String = ""
    public var password: String = ""
    public private(set) var phase: Phase = .idle

    private let service: PasswordSignInService
    private let onAuthenticated: (UserSession) -> Void
    private var task: Task<Void, Never>?

    public init(
        service: PasswordSignInService,
        onAuthenticated: @escaping (UserSession) -> Void
    ) {
        self.service = service
        self.onAuthenticated = onAuthenticated
    }

    /// A username is required; the submit button is disabled mid-request.
    public var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .submitting
    }

    /// Attempts sign-in with the current credentials.
    public func submit() {
        guard canSubmit else { return }
        task?.cancel()
        phase = .submitting
        let username = self.username
        let password = self.password
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await service.signIn(username: username, password: password)
                if Task.isCancelled { return }
                self.phase = .success
                self.onAuthenticated(session)
            } catch is CancellationError {
                // Cancelled (view dismissed); leave phase untouched.
            } catch let error as AppError {
                if error == .cancelled { return }
                self.phase = .error(error.userMessage)
            } catch {
                self.phase = .error(AppError.unknown("").userMessage)
            }
        }
    }

    /// Cancels any in-flight request (Back button / view disappears).
    public func cancel() {
        task?.cancel()
        task = nil
    }
}
