import CoreModels
import Foundation

public struct WatchlistRetryDecision: Equatable, Sendable {
    public let classification: WatchlistMutationFailureClass
    public let retryDelay: TimeInterval?
}

public struct WatchlistRetryPolicy: Sendable {
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var jitterFraction: Double

    public init(
        initialDelay: TimeInterval = 2,
        maximumDelay: TimeInterval = 15 * 60,
        jitterFraction: Double = 0.2
    ) {
        self.initialDelay = max(0, initialDelay)
        self.maximumDelay = max(initialDelay, maximumDelay)
        self.jitterFraction = min(max(jitterFraction, 0), 1)
    }

    public func decision(
        for error: Error,
        attempt: Int,
        jitterUnit: Double = Double.random(in: 0...1)
    ) -> WatchlistRetryDecision {
        if let error = error as? WatchlistDestinationError {
            switch error {
            case .authenticationRequired:
                return .init(classification: .authentication, retryDelay: nil)
            case .unsupportedIdentity:
                return .init(classification: .unsupportedIdentity, retryDelay: nil)
            case .permanent:
                return .init(classification: .permanent, retryDelay: nil)
            case .rateLimited(let retryAfter):
                return .init(
                    classification: .transient,
                    retryDelay: retryAfter ?? delay(attempt: attempt, jitterUnit: jitterUnit)
                )
            case .transient:
                return .init(
                    classification: .transient,
                    retryDelay: delay(attempt: attempt, jitterUnit: jitterUnit)
                )
            }
        }
        if let error = error as? AppError {
            switch error {
            case .unauthorized, .invalidCredentials:
                return .init(classification: .authentication, retryDelay: nil)
            case .notFound:
                return .init(classification: .unsupportedIdentity, retryDelay: nil)
            case .rateLimited(let retryAfter):
                // Honour what the server asked for; falling through to the
                // generic backoff would keep pushing on a throttled service.
                return .init(
                    classification: .transient,
                    retryDelay: retryAfter
                        ?? delay(attempt: attempt, jitterUnit: jitterUnit)
                )
            case .serverUnreachable, .cancelled, .invalidResponse, .conflict,
                 .quickConnectUnavailable, .quickConnectExpired, .decoding,
                 .unknown:
                return .init(
                    classification: .transient,
                    retryDelay: delay(attempt: attempt, jitterUnit: jitterUnit)
                )
            }
        }
        return .init(
            classification: .transient,
            retryDelay: delay(attempt: attempt, jitterUnit: jitterUnit)
        )
    }

    public func delay(attempt: Int, jitterUnit: Double) -> TimeInterval {
        let exponent = min(max(attempt, 0), 20)
        let base = min(maximumDelay, initialDelay * pow(2, Double(exponent)))
        let centered = min(max(jitterUnit, 0), 1) * 2 - 1
        return max(0, base * (1 + centered * jitterFraction))
    }
}
