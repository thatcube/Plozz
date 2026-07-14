#if canImport(SwiftUI)
import Foundation
import Observation
import ProviderShare

/// Drives the two-step "Add a Media Share" flow:
///
///  1. **Choose a server** — SMB servers found on the LAN (Bonjour `_smb._tcp`)
///     listed for one-tap selection, with a plain address field as a fallback.
///  2. **Choose a share** — once a server is picked we log in (guest first) and
///     list its real shares so the user taps one instead of guessing the name.
///     If the server needs credentials we surface username/password and retry.
///
/// Deliberately lighter than the Jellyfin picker: no reachability probes,
/// recents, or Tailscale handling — a media share is a second-class backend.
@MainActor
@Observable
final class AddShareViewModel {
    enum Step: Equatable { case chooseServer, chooseShare }

    enum ShareLoad: Equatable {
        case idle
        case loading
        case loaded
        /// The server needs a login before it will list shares (guest was
        /// refused or not allowed to enumerate) — show credential fields.
        case needsAuth
        /// The user supplied a username/password and the server rejected them.
        case badCredentials
        /// Couldn't connect to the server at all (off, wrong address, different
        /// network). No amount of credentials will help — offer to retry.
        case unreachable
        case failed(String)
    }

    // Discovery
    private(set) var discovered: [DiscoveredSMBServer] = []
    private(set) var scanning = false

    // Step
    private(set) var step: Step = .chooseServer

    // Manual server entry (fallback)
    var manualHost = ""
    var manualPortText = ""

    // Chosen target
    private(set) var host = ""
    private(set) var port: Int?
    /// Label for the chosen server on the share step; also the default display
    /// name for the resulting account.
    private(set) var serverLabel = ""

    // Credentials (only needed if the server rejects guest)
    var username = ""
    var password = ""

    // Shares
    private(set) var shares: [String] = []
    private(set) var shareLoad: ShareLoad = .idle
    /// Manual share-name fallback when enumeration fails or returns nothing.
    var manualShare = ""

    /// Set when the typed manual address auto-detects as WebDAV instead of SMB.
    /// The hosting coordinator observes this and switches to the WebDAV flow.
    private(set) var detectedWebDAV: DetectedWebDAVRoute?
    /// True while the manual address is being auto-detected (SMB vs WebDAV).
    private(set) var detecting = false

    struct DetectedWebDAVRoute: Equatable {
        let url: URL
        let insecureHTTP: Bool
    }

    private let discovery = SMBServiceDiscovery()
    private let routeDetector = MediaShareRouteDetector()
    private var scanTask: Task<Void, Never>?
    private var shareTask: Task<Void, Never>?
    private var detectTask: Task<Void, Never>?

    var canConnectManualHost: Bool {
        !manualHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var canUseManualShare: Bool {
        !manualShare.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Discovery

    func startScan() {
        scanTask?.cancel()
        discovered = []
        scanning = true
        scanTask = Task { [discovery] in
            for await server in discovery.discover(timeout: 6) {
                if Task.isCancelled { break }
                if !self.discovered.contains(where: { $0.id == server.id }) {
                    self.discovered.append(server)
                }
            }
            // Only the CURRENT scan may clear the flag. A superseded scan (cancelled
            // by a newer `startScan`) must not flip `scanning` back off — the newer
            // scan already set it true and owns it now.
            if !Task.isCancelled {
                self.scanning = false
            }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        scanning = false
    }

    // MARK: - Step transitions

    func selectDiscovered(_ server: DiscoveredSMBServer) {
        host = server.host
        port = server.port
        serverLabel = server.name
        enterShareStep()
    }

    func connectManualHost() {
        detectTask?.cancel()
        detectedWebDAV = nil
        let raw = manualHost.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        // If the user typed an explicit port in the separate Port field, fold it
        // into the address so the detector sees it.
        let addressForDetection: String
        if let explicitPort = Int(manualPortText.trimmingCharacters(in: .whitespaces)),
           !raw.contains("/"), raw.filter({ $0 == ":" }).count == 0 {
            addressForDetection = "\(raw):\(explicitPort)"
        } else {
            addressForDetection = raw
        }

        detecting = true
        detectTask = Task { [routeDetector] in
            let result = await routeDetector.detect(address: addressForDetection)
            if Task.isCancelled { return }
            self.detecting = false
            switch result {
            case .success(.webDAV(let url, let insecureHTTP)):
                // Hand off to the WebDAV flow.
                self.detectedWebDAV = DetectedWebDAVRoute(url: url, insecureHTTP: insecureHTTP)
            case .success(.smb(let host, let port)):
                self.host = host
                self.port = port
                self.serverLabel = host
                self.enterShareStep()
            case .success(.ftp):
                // Headless branch: FTP is detected (claimant active) but the
                // unified add-share + credential-entry flow that consumes `.ftp`
                // is owned by the Discovery-UX branch. Until it lands, surface a
                // clear non-crash placeholder rather than a bespoke screen.
                self.shareLoad = .unreachable
                self.step = .chooseShare
            case .failure:
                // A host+path that answered nowhere: surface as unreachable so
                // the user can correct the address.
                self.shareLoad = .unreachable
                self.step = .chooseShare
            }
        }
    }

    func backToServers() {
        shareTask?.cancel()
        shareTask = nil
        step = .chooseServer
        shares = []
        shareLoad = .idle
        manualShare = ""
        username = ""
        password = ""
    }

    private func enterShareStep() {
        stopScan()
        step = .chooseShare
        loadShares()
    }

    // MARK: - Share enumeration

    func loadShares() {
        shareTask?.cancel()
        shareLoad = .loading
        shares = []
        let host = self.host
        let port = self.port
        let username = self.username
        let password = self.password
        shareTask = Task {
            do {
                let names = try await SMBShareEnumerator.listShares(
                    host: host, port: port, username: username, password: password
                )
                if Task.isCancelled { return }
                self.shares = names
                self.shareLoad = .loaded
            } catch SMBShareEnumerator.ListError.authenticationRequired {
                if Task.isCancelled { return }
                self.shareLoad = .needsAuth
            } catch SMBShareEnumerator.ListError.credentialsRejected {
                if Task.isCancelled { return }
                self.shareLoad = .badCredentials
            } catch SMBShareEnumerator.ListError.unreachable {
                if Task.isCancelled { return }
                self.shareLoad = .unreachable
            } catch SMBShareEnumerator.ListError.timedOut {
                // A slow/unresponsive server is a reachability problem, not an
                // auth one — show the "can't connect" panel with a retry rather
                // than the generic failure (which prompts for credentials).
                if Task.isCancelled { return }
                self.shareLoad = .unreachable
            } catch {
                if Task.isCancelled { return }
                self.shareLoad = .failed(Self.friendlyError(error))
            }
        }
    }

    /// Build the draft the onboarding flow expects, defaulting the display name
    /// to the share (or the server label) when the user didn't override it.
    func draft(forShare share: String, displayName: String) -> ShareDraft {
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let fallback = share.isEmpty ? serverLabel : share
        return ShareDraft(
            host: host,
            port: port,
            share: share.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            displayName: trimmedName.isEmpty ? fallback : trimmedName
        )
    }

    // MARK: - Helpers

    /// Parse a typed address into host + optional port. Tolerates an `smb://`
    /// prefix, a trailing `/share` path (ignored here — the share is picked on
    /// the next step), and an inline `:port`.
    static func parseHost(_ raw: String, portText: String) -> (String, Int?) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        // Drop any path component; the share is chosen separately.
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        var host = s
        let explicitPort = Int(portText.trimmingCharacters(in: .whitespaces))
        var inlinePort: Int?
        // Inline host:port (skip IPv6 literals, which contain multiple colons).
        // Always strip the `:port` suffix off the host — even when the separate
        // Port field is also filled — so a pasted `192.168.1.5:9999` never leaks
        // its port into the host and produces an unresolvable address.
        if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
            host = String(s[..<colon])
            inlinePort = Int(s[s.index(after: colon)...])
        }
        // The explicit Port field wins when both are supplied.
        return (host.trimmingCharacters(in: .whitespaces), explicitPort ?? inlinePort)
    }

    private static func friendlyError(_ error: Error) -> String {
        if let e = error as? SMBShareEnumerator.ListError {
            switch e {
            case .timedOut: return "Couldn't reach the server. Check it's on and connected to the same network, then try again."
            case .unreachable: return "Couldn't connect to the server. Check the address and that it's on the same network, then try again."
            case .authenticationRequired: return "This server requires a username and password."
            case .credentialsRejected: return "That username or password was incorrect. Please try again."
            case .failed: return "Something went wrong talking to this server. Please try again."
            }
        }
        return "Something went wrong talking to this server. Please try again."
    }
}
#endif
