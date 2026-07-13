#if canImport(SwiftUI)
import CoreModels
import FeatureAuth
import Foundation
import MediaTransportHTTP
import Observation

/// Which credential the user is adding a WebDAV share with.
enum WebDAVAuthMode: String, CaseIterable, Sendable {
    case anonymous
    case usernamePassword
    case bearer
}

/// The finished configuration handed back to `AppState.didConfigureWebDAVShare`.
struct WebDAVShareConfiguration: Equatable {
    let baseURL: URL
    let auth: AppState.WebDAVShareAuth
    let trustPin: SHA256Fingerprint?
    let displayName: String
}

/// Drives the "Add a WebDAV share" flow: enter address + credentials, preflight
/// TLS (with explicit trust-on-first-use approval for a self-signed cert over
/// HTTPS), browse folders via PROPFIND, and confirm. All network work goes
/// through an injected ``WebDAVOnboardingProbing`` so the state machine is
/// unit-testable offline; the real probe is validated on-device.
@MainActor
@Observable
final class AddWebDAVShareViewModel {
    enum Step: Equatable {
        case enterAddress
        case confirmTrust(sha256: Data)
        case browsing
        case done(WebDAVShareConfiguration)
    }

    // Inputs
    var address = ""
    var authMode: WebDAVAuthMode = .anonymous
    var username = ""
    var password = ""
    var bearerToken = ""
    var displayName = ""

    // State
    private(set) var step: Step = .enterAddress
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var folders: [WebDAVOnboardingFolder] = []
    private(set) var currentPath = "/"

    /// The finished config, published when the user confirms a folder.
    private(set) var configuration: WebDAVShareConfiguration?

    private let probe: any WebDAVOnboardingProbing
    /// The approved trust decision for the active attempt.
    private var trust: WebDAVOnboardingTrust = .system
    /// Approved leaf pin, if any (carried into the final configuration).
    private var approvedPin: Data?

    /// An immutable snapshot of the inputs for one connection attempt. Captured
    /// when the user taps Connect so that editing the address/credentials while
    /// an async preflight/validate is in flight can never send the new
    /// credential to the old origin (or vice versa).
    private struct Attempt {
        let base: URL
        let origin: TransportOrigin
        let originURL: URL
        /// Percent-encoded path the user entered (browse starts here).
        let enteredPath: String
        let credential: WebDAVCredential
        let shareAuth: AppState.WebDAVShareAuth
    }
    private var attempt: Attempt?
    /// Bumped on every user-initiated step (connect / approve / navigate) so a
    /// late-arriving response from a superseded request is ignored.
    private var generation = 0

    init(probe: any WebDAVOnboardingProbing = WebDAVOnboardingProbe()) {
        self.probe = probe
    }

    var canConnect: Bool {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch authMode {
        case .anonymous: return true
        case .usernamePassword:
            return !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        case .bearer:
            return !bearerToken.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Parsed base URL + normalized origin, or nil if the address is invalid.
    /// Rejects userinfo/query/fragment up front (defense-in-depth; AppState
    /// re-checks at persistence).
    private func parseAddress() -> (base: URL, origin: TransportOrigin)? {
        var raw = address.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        // Default to https when no scheme is typed.
        if !raw.lowercased().hasPrefix("http://"), !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }
        guard let url = URL(string: raw),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let origin = TransportOrigin(url: url) else {
            return nil
        }
        return (url, origin)
    }

    private var credential: WebDAVCredential {
        switch authMode {
        case .anonymous:
            return .anonymous
        case .usernamePassword:
            return .password(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password,
                policy: .automatic
            )
        case .bearer:
            return .bearerToken(bearerToken.trimmingCharacters(in: .whitespaces))
        }
    }

    private var shareAuth: AppState.WebDAVShareAuth {
        switch authMode {
        case .anonymous: return .anonymous
        case .usernamePassword:
            return .password(username: username.trimmingCharacters(in: .whitespaces), password: password)
        case .bearer:
            return .bearer(token: bearerToken.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Snapshots the current inputs into an immutable attempt (or nil if the
    /// address is invalid).
    private func makeAttempt() -> Attempt? {
        guard let (base, origin) = parseAddress(), let originURL = origin.originURL else { return nil }
        let basePath = URLComponents(url: base, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return Attempt(
            base: base,
            origin: origin,
            originURL: originURL,
            enteredPath: basePath.isEmpty ? "/" : basePath,
            credential: credential,
            shareAuth: shareAuth
        )
    }

    private var isAnonymous: Bool {
        if case .anonymous = authMode { return true }
        return false
    }

    // MARK: - Flow

    func connect() async {
        errorMessage = nil
        guard let attempt = makeAttempt() else {
            errorMessage = Self.message(for: .invalidURL)
            return
        }
        // A reusable credential requires HTTPS — fail closed before any request.
        if !attempt.origin.isSecure, !isAnonymous {
            errorMessage = Self.message(for: .notSecure)
            return
        }
        self.attempt = attempt
        generation += 1
        let gen = generation

        isWorking = true
        defer { if gen == generation { isWorking = false } }

        // HTTPS: preflight trust first so a self-signed cert is approved before
        // any credential is sent.
        if attempt.origin.isSecure {
            let result = await probe.preflightTrust(url: attempt.base)
            guard gen == generation else { return } // superseded
            switch result {
            case .systemTrusted:
                trust = .system
                approvedPin = nil
            case .needsApproval(let sha256):
                step = .confirmTrust(sha256: sha256)
                return
            case .unreachable:
                errorMessage = Self.message(for: .unreachable)
                return
            }
        } else {
            trust = .system
            approvedPin = nil
        }

        await validateAndBrowse(attempt: attempt, generation: gen)
    }

    /// User approved the captured certificate fingerprint (trust-on-first-use).
    func approveTrust() async {
        guard case .confirmTrust(let sha256) = step, let attempt else { return }
        trust = .pinnedLeaf(sha256: sha256)
        approvedPin = sha256
        generation += 1
        let gen = generation
        isWorking = true
        defer { if gen == generation { isWorking = false } }
        await validateAndBrowse(attempt: attempt, generation: gen)
    }

    func rejectTrust() {
        trust = .system
        approvedPin = nil
        generation += 1 // supersede any in-flight request
        step = .enterAddress
    }

    private func validateAndBrowse(attempt: Attempt, generation gen: Int) async {
        guard let validateURL = url(origin: attempt.originURL, encodedPath: attempt.enteredPath) else {
            errorMessage = Self.message(for: .invalidURL)
            step = .enterAddress
            return
        }
        let result = await probe.validate(url: validateURL, credential: attempt.credential, trust: trust)
        guard gen == generation else { return } // superseded
        switch result {
        case .success:
            break
        case .failure(let error):
            errorMessage = Self.message(for: error)
            step = .enterAddress
            return
        }
        await loadFolders(attempt: attempt, path: attempt.enteredPath, generation: gen)
        if errorMessage == nil, gen == generation {
            step = .browsing
        }
    }

    /// Navigates the folder picker to `path`. Supersedes any in-flight browse so
    /// an out-of-order response can't overwrite a newer selection.
    func loadFolders(at path: String) async {
        guard let attempt else { return }
        generation += 1
        await loadFolders(attempt: attempt, path: path, generation: generation)
    }

    private func loadFolders(attempt: Attempt, path: String, generation gen: Int) async {
        errorMessage = nil
        isWorking = true
        defer { if gen == generation { isWorking = false } }
        let result = await probe.listFolders(
            url: attempt.originURL,
            path: path,
            credential: attempt.credential,
            trust: trust
        )
        guard gen == generation else { return } // superseded
        switch result {
        case .success(let folders):
            self.folders = folders
            self.currentPath = path
        case .failure(let error):
            errorMessage = Self.message(for: error)
        }
    }

    /// Builds a URL at `encodedPath` on `origin`. `encodedPath` is a
    /// percent-encoded path (safe to assign to `percentEncodedPath`).
    private func url(origin: URL, encodedPath: String) -> URL? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.percentEncodedPath = encodedPath == "/" ? "" : encodedPath
        return components.url
    }

    /// Confirms the current folder as the share root, producing the final config.
    func useCurrentFolder() {
        guard let attempt, let baseURL = url(origin: attempt.originURL, encodedPath: currentPath) else {
            errorMessage = Self.message(for: .invalidURL)
            return
        }
        let pin: SHA256Fingerprint?
        if let approvedPin {
            pin = try? SHA256Fingerprint(bytes: approvedPin)
        } else {
            pin = nil
        }
        let config = WebDAVShareConfiguration(
            baseURL: baseURL,
            auth: attempt.shareAuth,
            trustPin: pin,
            displayName: displayName.trimmingCharacters(in: .whitespaces)
        )
        configuration = config
        step = .done(config)
    }

    static func message(for error: WebDAVOnboardingError) -> String {
        switch error {
        case .invalidURL:
            return "That doesn’t look like a valid web address. Try something like https://nas.local/dav."
        case .notSecure:
            return "A username, password, or token requires a secure (https://) address."
        case .unreachable:
            return "Couldn’t reach that server. Check the address and that it’s on the same network, then try again."
        case .untrusted:
            return "Couldn’t verify this server’s certificate. If it’s self-signed, approve its fingerprint to continue."
        case .authenticationFailed:
            return "That username, password, or token was rejected. Please check it and try again."
        case .notWebDAV:
            return "That server didn’t respond as a WebDAV share. Check the address (some servers need a /dav path)."
        case .forbidden:
            return "This account doesn’t have permission to browse that location."
        case .serverError:
            return "The server had a problem. Please try again in a moment."
        case .cancelled:
            return "The request was cancelled."
        }
    }
}

private extension TransportOrigin {
    /// The scheme://host[:port] URL with no path, for folder-browse requests.
    var originURL: URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80
        if port != defaultPort {
            components.port = port
        }
        components.path = ""
        return components.url
    }
}
#endif
