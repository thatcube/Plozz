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
/// **Read-only by design.** Manual verification must not perturb the pipeline's live
/// serving state, so this deliberately does NOT record its outcome into any shared
/// circuit breaker: tapping "Verify" can neither close a breaker the pipeline
/// legitimately opened (a real rate-limit/outage) nor nudge one toward open. The
/// pipeline itself still trips a bad key's own credential-scoped breaker when it
/// actually uses the key during enrichment; verify is purely diagnostic.
public struct TMDBKeyValidator: Sendable {
    public init() {}

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
        switch outcome {
        case .success, .empty:
            return .valid
        case .unauthorized:
            return .invalid
        case .rateLimited, .transient:
            return .unreachable
        }
    }

    private struct AuthResponse: Decodable, Sendable {
        let success: Bool?
    }
}
