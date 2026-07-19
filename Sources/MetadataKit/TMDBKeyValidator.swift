import Foundation
import CoreModels

/// Verifies a user's bring-your-own-key TMDB token (Step 9) with a single lightweight,
/// authenticated call over the same resilient HTTP path the providers use.
///
/// The check hits TMDb's `/3/authentication` endpoint with the token as a v4 bearer and
/// classifies the transport outcome: a `2xx` means the key authenticates (valid); a
/// `401/403` means TMDb rejected it (invalid); anything else — offline, timeout, 429,
/// 5xx — is inconclusive (unreachable), never a verdict against the key.
///
/// When a shared ``MetadataProviderRuntime`` is supplied, the outcome is recorded into
/// **that key's** circuit breaker (keyed by its credential identity), so a bad key opens
/// only its own breaker — never the built-in path's or another key's — exactly as the
/// pipeline would. Removing/replacing the key clears that state via
/// ``MetadataProviderRuntime/invalidateCredential(_:)``.
public struct TMDBKeyValidator: Sendable {
    private let runtime: MetadataProviderRuntime?

    public init(runtime: MetadataProviderRuntime? = nil) {
        self.runtime = runtime
    }

    public func validate(_ token: String) async -> TMDBKeyValidationResult {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: "https://api.themoviedb.org/3/authentication") else {
            return .invalid
        }
        let outcome = await MetadataHTTP.getOutcome(
            AuthResponse.self,
            url: url,
            headers: ["Authorization": "Bearer \(trimmed)"]
        )

        if let runtime {
            let credentialID = TMDbAccess.credentialID(forToken: trimmed)
            let breaker = runtime.breakerRegistry.breaker(
                for: ProviderBreakerKey(source: .tmdb, credentialID: credentialID)
            )
            await breaker.record(Self.health(for: outcome))
        }

        switch outcome {
        case .success, .empty:
            return .valid
        case .unauthorized:
            return .invalid
        case .rateLimited, .transient:
            return .unreachable
        }
    }

    private static func health<T>(for outcome: MetadataHTTP.Outcome<T>) -> ProviderHealth {
        switch outcome {
        case .success, .empty: return .ok
        case .unauthorized: return .failure(.unauthorized)
        case .rateLimited(let retryAfter): return .failure(.rateLimited(retryAfter: retryAfter))
        case .transient: return .failure(.transient)
        }
    }

    private struct AuthResponse: Decodable, Sendable {
        let success: Bool?
    }
}
