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
    /// The origin URL (scheme://host[:port]) without a path, resolved from
    /// `address` once validated. Folder browsing builds paths against it.
    private var originURL: URL?
    /// The approved trust decision for this session.
    private var trust: WebDAVOnboardingTrust = .system
    /// Approved leaf pin, if any (carried into the final configuration).
    private var approvedPin: Data?

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

    // MARK: - Flow

    func connect() async {
        errorMessage = nil
        guard let (base, origin) = parseAddress() else {
            errorMessage = Self.message(for: .invalidURL)
            return
        }
        // A reusable credential requires HTTPS — fail closed before any request.
        if !origin.isSecure, authMode != .anonymous {
            errorMessage = Self.message(for: .notSecure)
            return
        }
        originURL = origin.originURL

        isWorking = true
        defer { isWorking = false }

        // HTTPS: preflight trust first so a self-signed cert is approved before
        // any credential is sent.
        if origin.isSecure {
            switch await probe.preflightTrust(url: base) {
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

        await validateAndBrowse(base: base)
    }

    /// User approved the captured certificate fingerprint (trust-on-first-use).
    func approveTrust() async {
        guard case .confirmTrust(let sha256) = step, let base = originURL else { return }
        trust = .pinnedLeaf(sha256: sha256)
        approvedPin = sha256
        isWorking = true
        defer { isWorking = false }
        await validateAndBrowse(base: base)
    }

    func rejectTrust() {
        trust = .system
        approvedPin = nil
        step = .enterAddress
    }

    private func validateAndBrowse(base: URL) async {
        switch await probe.validate(url: base, credential: credential, trust: trust) {
        case .success:
            break
        case .failure(let error):
            errorMessage = Self.message(for: error)
            step = .enterAddress
            return
        }
        currentPath = "/"
        await loadFolders(at: "/")
        if errorMessage == nil {
            step = .browsing
        }
    }

    /// Loads the child folders at `path` for the picker.
    func loadFolders(at path: String) async {
        guard let origin = originURL else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        switch await probe.listFolders(url: origin, path: path, credential: credential, trust: trust) {
        case .success(let folders):
            self.folders = folders
            self.currentPath = path
        case .failure(let error):
            errorMessage = Self.message(for: error)
        }
    }

    /// Confirms the current folder as the share root, producing the final config.
    func useCurrentFolder() {
        guard let origin = originURL,
              var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            errorMessage = Self.message(for: .invalidURL)
            return
        }
        components.percentEncodedPath = currentPath == "/" ? "" : currentPath
        guard let baseURL = components.url else {
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
            auth: shareAuth,
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
