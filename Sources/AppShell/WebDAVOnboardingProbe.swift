#if canImport(SwiftUI)
import CoreModels
import Foundation
import MediaTransportCore
import MediaTransportHTTP
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A folder discovered while browsing a WebDAV server during onboarding.
struct WebDAVOnboardingFolder: Equatable, Sendable, Identifiable {
    /// Absolute, server-rooted path (percent-decoded, normalized). Also the id.
    let path: String
    /// Display name (the last path segment).
    let name: String
    var id: String { path }
}

/// Typed onboarding failures, mapped to friendly copy by the view model.
enum WebDAVOnboardingError: Error, Equatable, Sendable {
    case invalidURL
    case notSecure           // a reusable credential over plain http
    case unreachable         // couldn't connect at all
    case untrusted           // TLS trust failed and no pin was approved
    case authenticationFailed
    case notWebDAV           // reachable HTTP server but not a WebDAV share
    case forbidden
    case serverError
    case cancelled
}

/// The outcome of a TLS preflight against an `https` origin.
enum WebDAVTrustPreflight: Equatable, Sendable {
    /// The system already trusts this server's certificate chain — no pin needed.
    case systemTrusted
    /// The certificate isn't system-trusted (e.g. self-signed). The captured
    /// leaf SHA-256 is offered for explicit user approval (trust-on-first-use).
    case needsApproval(sha256: Data)
    /// Couldn't reach the server to evaluate trust.
    case unreachable
}

/// The trust decision to use for a WebDAV request during onboarding.
enum WebDAVOnboardingTrust: Equatable, Sendable {
    case system
    case pinnedLeaf(sha256: Data)

    func policy(revision: UUID) -> TrustPolicy {
        switch self {
        case .system: return .system
        case .pinnedLeaf(let sha256): return .pinnedLeaf(sha256: sha256, revision: revision)
        }
    }
}

/// Network operations the WebDAV onboarding flow needs, behind a protocol so the
/// view model is unit-testable with a stub (the real implementation is validated
/// end-to-end on a physical device against a real server).
protocol WebDAVOnboardingProbing: Sendable {
    /// Preflight TLS for an `https` URL, capturing an untrusted leaf's SHA-256
    /// for approval. Never transfers data over an unverified channel.
    func preflightTrust(url: URL) async -> WebDAVTrustPreflight
    /// `OPTIONS` + `DAV` header check under the chosen credential/trust.
    func validate(
        url: URL,
        credential: WebDAVCredential,
        trust: WebDAVOnboardingTrust
    ) async -> Result<Void, WebDAVOnboardingError>
    /// `PROPFIND` Depth:1 → the child collections (folders) at `path`.
    func listFolders(
        url: URL,
        path: String,
        credential: WebDAVCredential,
        trust: WebDAVOnboardingTrust
    ) async -> Result<[WebDAVOnboardingFolder], WebDAVOnboardingError>
}

/// Real probe backed by the `MediaTransportHTTP` primitives. Uses a fresh
/// ephemeral registry per call (onboarding has no account/vault yet), and a
/// dedicated capturing delegate for the trust-on-first-use preflight.
struct WebDAVOnboardingProbe: WebDAVOnboardingProbing {
    // A fixed, arbitrary trust revision for onboarding sessions: onboarding
    // builds a throwaway registry per call, so the revision only needs to be
    // internally consistent between the key and the pinned policy.
    private static let onboardingTrustRevision = UUID(
        uuid: (1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1)
    )

    func preflightTrust(url: URL) async -> WebDAVTrustPreflight {
        #if canImport(Security)
        guard let origin = TransportOrigin(url: url), origin.isSecure else {
            return .unreachable
        }
        return await withCheckedContinuation { continuation in
            let delegate = LeafCapturingDelegate(host: origin.host) { result in
                continuation.resume(returning: result)
            }
            let configuration = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.httpMethod = "OPTIONS"
            request.timeoutInterval = 15
            let task = session.dataTask(with: request)
            task.resume()
        }
        #else
        return .unreachable
        #endif
    }

    func validate(
        url: URL,
        credential: WebDAVCredential,
        trust: WebDAVOnboardingTrust
    ) async -> Result<Void, WebDAVOnboardingError> {
        guard let origin = TransportOrigin(url: url) else { return .failure(.invalidURL) }
        guard let key = try? makeKey(origin: origin) else { return .failure(.invalidURL) }
        let client = WebDAVClient(registry: TransportSessionRegistry())
        do {
            let headers = try await client.capabilities(
                url: url,
                sessionKey: key,
                credential: credential,
                trustPolicy: trust.policy(revision: Self.onboardingTrustRevision)
            )
            guard headers["dav"] != nil else { return .failure(.notWebDAV) }
            return .success(())
        } catch {
            return .failure(Self.mapError(error))
        }
    }

    func listFolders(
        url: URL,
        path: String,
        credential: WebDAVCredential,
        trust: WebDAVOnboardingTrust
    ) async -> Result<[WebDAVOnboardingFolder], WebDAVOnboardingError> {
        guard let origin = TransportOrigin(url: url) else { return .failure(.invalidURL) }
        guard let root = WebDAVRoot(origin: origin, rawPath: path) else { return .failure(.invalidURL) }
        guard let key = try? makeKey(origin: origin) else { return .failure(.invalidURL) }
        let client = WebDAVClient(registry: TransportSessionRegistry())
        do {
            let entries = try await client.listChildren(
                root: root,
                path: root.path,
                depth: .one,
                sessionKey: key,
                credential: credential,
                trustPolicy: trust.policy(revision: Self.onboardingTrustRevision)
            )
            let folders = entries
                .filter { $0.isCollection }
                .map { entry -> WebDAVOnboardingFolder in
                    let trimmed = entry.resolvedPath.hasSuffix("/") && entry.resolvedPath.count > 1
                        ? String(entry.resolvedPath.dropLast())
                        : entry.resolvedPath
                    let name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
                    return WebDAVOnboardingFolder(path: trimmed, name: name)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return .success(folders)
        } catch {
            return .failure(Self.mapError(error))
        }
    }

    private func makeKey(origin: TransportOrigin) throws -> TransportSessionKey {
        try TransportSessionKey(
            accountID: "onboarding",
            credentialRevision: UUID(),
            origin: origin,
            trustRevision: Self.onboardingTrustRevision,
            role: .metadata
        )
    }

    private static func mapError(_ error: Error) -> WebDAVOnboardingError {
        guard let transportError = error as? TransportError else { return .unreachable }
        switch transportError {
        case .authenticationFailed, .authenticationSchemeNotPermitted:
            return .authenticationFailed
        case .cleartextCredentialRejected:
            return .notSecure
        case .trustEvaluationFailed, .trustPinMismatch:
            return .untrusted
        case .cancelled:
            return .cancelled
        case .protocolError(let status, _):
            switch status {
            case 401: return .authenticationFailed
            case 403: return .forbidden
            case 500...599: return .serverError
            default: return .notWebDAV
            }
        case .transport:
            return .unreachable
        default:
            return .notWebDAV
        }
    }
}

#if canImport(Security)
/// A one-shot URLSession delegate for the trust preflight: on the server-trust
/// challenge it evaluates system trust, and if that fails it captures the leaf
/// certificate's SHA-256 and **cancels** the connection (no data is ever
/// transferred over an unverified channel — the fingerprint is surfaced for
/// explicit out-of-band user approval).
private final class LeafCapturingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let host: String
    private let completion: @Sendable (WebDAVTrustPreflight) -> Void
    private let lock = NSLock()
    private var finished = false

    init(host: String, completion: @escaping @Sendable (WebDAVTrustPreflight) -> Void) {
        self.host = host
        self.completion = completion
    }

    private func finish(_ result: WebDAVTrustPreflight) {
        let shouldCall = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if shouldCall { completion(result) }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if SystemTrustEvaluator.evaluateSystemTrust(trust, host: host) == nil {
            finish(.systemTrusted)
            completionHandler(.cancelAuthenticationChallenge, nil)
            session.invalidateAndCancel()
            return
        }
        if let leafDER = SystemTrustEvaluator.leafCertificateDER(from: trust) {
            finish(.needsApproval(sha256: LeafCertificateTrust.sha256(ofLeafCertificateDER: leafDER)))
        } else {
            finish(.unreachable)
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // If no trust challenge fired (e.g. connection refused), report unreachable.
        finish(.unreachable)
        session.invalidateAndCancel()
    }
}
#endif
#endif
