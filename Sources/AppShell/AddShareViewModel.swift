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
        /// The server rejected guest/anonymous — show credential fields + retry.
        case needsAuth
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

    private let discovery = SMBServiceDiscovery()
    private var scanTask: Task<Void, Never>?
    private var shareTask: Task<Void, Never>?

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
        let (parsedHost, parsedPort) = Self.parseHost(manualHost, portText: manualPortText)
        guard !parsedHost.isEmpty else { return }
        host = parsedHost
        port = parsedPort
        serverLabel = parsedHost
        enterShareStep()
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
            case .timedOut: return "Couldn't reach the server. Check it's on and try again."
            case .authenticationRequired: return "This server needs a username and password."
            case .failed: return "Couldn't list shares on this server."
            }
        }
        return "Couldn't list shares on this server."
    }
}
#endif
