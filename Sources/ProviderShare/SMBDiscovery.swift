import Foundation
import SMBClient
import CoreNetworking

/// An SMB file server found on the local network via Bonjour (`_smb._tcp`).
///
/// This is the "server" half of making a media share easy to add: instead of
/// typing an IP, the user picks a server that announced itself. `host` is a
/// resolvable name or address (a `.local` hostname or an IP literal) suitable
/// for handing straight to `SMBClient`.
public struct DiscoveredSMBServer: Sendable, Hashable, Identifiable {
    /// Human-readable service name (e.g. "MyNAS"), taken from the Bonjour
    /// instance name. Falls back to `host` when the browser gives us nothing.
    public let name: String
    /// A connect target — a `.local` hostname or an IP literal.
    public let host: String
    /// Advertised port, if any. `nil` means "use the SMB default" (445).
    public let port: Int?

    public init(name: String, host: String, port: Int?) {
        self.name = name
        self.host = host
        self.port = port
    }

    /// De-duplicate on the connect target, not the display name (two records
    /// for one box — IPv4/IPv6 — should collapse to a single row).
    public var id: String { port.map { "\(host):\($0)" } ?? host }
}

#if canImport(Network)
import Network

/// Discovers SMB servers on the local network by browsing the `_smb._tcp`
/// Bonjour service, then resolving each result to a connectable host/port.
///
/// Uses `Network.framework`'s `NWBrowser`, which only needs the Local Network
/// permission (already requested for Jellyfin discovery) plus `_smb._tcp` in
/// `NSBonjourServices` — no multicast entitlement, unlike the Jellyfin UDP
/// sweep. Mirrors `ServerDiscovering.discover(timeout:)`'s streaming shape.
public final class SMBServiceDiscovery: @unchecked Sendable {
    public init() {}

    /// Streams unique `DiscoveredSMBServer`s as they resolve, finishing after
    /// `timeout` seconds (or when the consumer stops iterating).
    public func discover(timeout: TimeInterval = 6) -> AsyncStream<DiscoveredSMBServer> {
        AsyncStream { continuation in
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: "_smb._tcp", domain: nil),
                using: params
            )
            let box = ResolveBox(continuation: continuation)

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    box.resolve(endpoint: result.endpoint, serviceName: name)
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state {
                    PlozzLog.boot("smb-discovery: browser failed \(state)")
                    box.finish()
                }
            }

            let queue = DispatchQueue(label: "com.plozz.smb.discovery")
            browser.start(queue: queue)
            PlozzLog.boot("smb-discovery: browsing _smb._tcp")

            let timeoutItem = DispatchWorkItem { box.finish() }
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            continuation.onTermination = { _ in
                timeoutItem.cancel()
                browser.cancel()
                box.cancelAll()
            }
        }
    }

    /// Serialises browser callbacks + per-endpoint resolutions onto one box so
    /// the `NWConnection` resolvers, de-dup set, and stream termination don't
    /// race across the browser queue and the resolver completion callbacks.
    private final class ResolveBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<DiscoveredSMBServer>.Continuation?
        private var seenHosts = Set<String>()
        private var inFlight = Set<ObjectIdentifier>()
        private var connections: [ObjectIdentifier: NWConnection] = [:]

        init(continuation: AsyncStream<DiscoveredSMBServer>.Continuation) {
            self.continuation = continuation
        }

        func resolve(endpoint: NWEndpoint, serviceName: String) {
            let connection = NWConnection(to: endpoint, using: .tcp)
            let key = ObjectIdentifier(connection)
            lock.lock()
            guard continuation != nil else { lock.unlock(); return }
            connections[key] = connection
            inFlight.insert(key)
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let (host, port) = Self.hostPort(from: connection.currentPath?.remoteEndpoint) {
                        self.emit(name: serviceName, host: host, port: port)
                    }
                    self.tearDown(key)
                case .failed, .cancelled:
                    self.tearDown(key)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.plozz.smb.resolve"))
        }

        private func emit(name: String, host: String, port: Int?) {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation else { return }
            // Default SMB port carries no signal; normalise so IPv4/IPv6 or
            // repeated announcements for one box collapse to a single row.
            let dedupeKey = host.lowercased()
            guard seenHosts.insert(dedupeKey).inserted else { return }
            let cleanName = name.isEmpty ? host : name
            let cleanPort = (port == 445 || port == nil) ? nil : port
            PlozzLog.boot("smb-discovery: found \(cleanName) @ \(host)\(cleanPort.map { ":\($0)" } ?? "")")
            continuation.yield(DiscoveredSMBServer(name: cleanName, host: host, port: cleanPort))
        }

        private func tearDown(_ key: ObjectIdentifier) {
            lock.lock()
            let connection = connections.removeValue(forKey: key)
            inFlight.remove(key)
            lock.unlock()
            connection?.cancel()
        }

        func finish() {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.finish()
        }

        func cancelAll() {
            lock.lock()
            let all = Array(connections.values)
            connections.removeAll()
            inFlight.removeAll()
            continuation = nil
            lock.unlock()
            all.forEach { $0.cancel() }
        }

        /// Extract a printable host + port from a resolved remote endpoint.
        /// Prefers a `.local` hostname (nicer + survives DHCP) but falls back to
        /// the resolved IP literal.
        private static func hostPort(from endpoint: NWEndpoint?) -> (String, Int?)? {
            guard let endpoint else { return nil }
            switch endpoint {
            case let .hostPort(host, port):
                let portValue = Int(port.rawValue)
                switch host {
                case let .name(name, _):
                    return (name, portValue)
                case let .ipv4(addr):
                    return ("\(addr)".components(separatedBy: "%").first ?? "\(addr)", portValue)
                case let .ipv6(addr):
                    // Rare on home SMB; keep it a plain address (no brackets) so
                    // it stays usable as an SMBClient host. .local/IPv4 are the
                    // common cases anyway.
                    return ("\(addr)".components(separatedBy: "%").first ?? "\(addr)", portValue)
                @unknown default:
                    return nil
                }
            default:
                return nil
            }
        }
    }
}
#else
/// Non-Network platforms (shouldn't happen on tvOS) get an inert discoverer so
/// the add-share flow still compiles and simply shows no LAN results.
public final class SMBServiceDiscovery: @unchecked Sendable {
    public init() {}
    public func discover(timeout: TimeInterval = 6) -> AsyncStream<DiscoveredSMBServer> {
        AsyncStream { $0.finish() }
    }
}
#endif

/// Enumerates the shares a server exposes, so the user can pick a real share
/// name instead of typing/guessing it.
public enum SMBShareEnumerator {
    public enum ListError: Error, CustomStringConvertible {
        /// A login/enumeration as guest (no credentials supplied) didn't get us
        /// the share list: either the anonymous session was refused, or it
        /// connected but the server won't enumerate shares anonymously. The UI
        /// uses this to explain that a username/password is required and prompt
        /// for one.
        case authenticationRequired
        /// The user *supplied* a username/password and the server rejected them
        /// (bad username or wrong password). Distinct from
        /// `authenticationRequired` so the UI can say "incorrect username or
        /// password" instead of silently re-showing the generic prompt.
        case credentialsRejected
        /// Couldn't establish a TCP/SMB connection at all — the server is off,
        /// the address/port is wrong, it's on another network, or something in
        /// between refused/reset the connection. Distinct from `timedOut` (which
        /// means we reached the point of waiting and gave up) and from the auth
        /// cases (which mean we *did* connect and talk SMB).
        case unreachable
        case timedOut
        case failed(String)

        public var description: String {
            switch self {
            case .authenticationRequired: return "authentication required"
            case .credentialsRejected: return "incorrect username or password"
            case .unreachable: return "couldn't connect to the server"
            case .timedOut: return "timed out"
            case .failed(let m): return m
            }
        }
    }

    /// True when `error` represents a transport/connection-level failure (the
    /// socket never carried a valid SMB conversation) rather than a protocol
    /// response from the server. Auth rejections arrive as `ErrorResponse`
    /// (they carry an NTStatus), so those are explicitly *not* transport errors.
    private static func isTransportError(_ error: Error) -> Bool {
        if error is ErrorResponse { return false }
        if error is NWError { return true }
        if error is ConnectionError { return true }
        if error is POSIXError { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain || ns.domain == NSURLErrorDomain { return true }
        if ns.domain == (kCFErrorDomainCFNetwork as String) { return true }
        return false
    }

    /// Log in (guest when no credentials given) and return the browsable disk
    /// share names, filtering out hidden/admin/IPC shares (IPC$, ADMIN$, C$,
    /// print/device shares). Empty username/password attempts guest.
    ///
    /// Login and enumeration are handled as two distinct failures: a rejected
    /// login (guest and anonymous, or supplied credentials) surfaces as
    /// `.authenticationRequired` so the UI can prompt for credentials, whereas a
    /// login that succeeds but whose share enumeration is denied surfaces as
    /// `.failed` — many NAS allow a guest *file* session yet deny guest access
    /// to `IPC$`/`NetShareEnum`, in which case the caller falls back to typing
    /// the share name (or retrying with credentials).
    public static func listShares(
        host: String,
        port: Int?,
        username: String,
        password: String,
        timeout: TimeInterval = 12
    ) async throws -> [String] {
        let client = port.map { SMBClient(host: host, port: $0) } ?? SMBClient(host: host)
        let account = username.isEmpty ? nil : username
        let secret = password.isEmpty ? nil : password
        PlozzLog.boot("share-list: connecting \(host)\(port.map { ":\($0)" } ?? "") user=\(account ?? "<guest>")")

        do {
            return try await withTimeout(timeout) {
                // Step 1 — establish a session. Distinguish auth failure from
                // everything else so the UI can prompt for credentials.
                do {
                    try await client.login(username: account ?? "guest", password: secret)
                    PlozzLog.boot("share-list: login ok (\(account ?? "guest"))")
                } catch {
                    PlozzLog.boot("share-list: login as \(account ?? "guest") failed: \(error)")
                    if isTransportError(error) {
                        // Never reached SMB at all (server off, wrong address,
                        // refused/reset). Not an auth problem — asking for a
                        // password wouldn't help, so say we couldn't connect.
                        throw ListError.unreachable
                    }
                    if account == nil {
                        // Some servers reject the literal "guest" but accept a
                        // truly anonymous session.
                        do {
                            try await client.login(username: nil, password: nil)
                            PlozzLog.boot("share-list: anonymous login ok")
                        } catch {
                            PlozzLog.boot("share-list: anonymous login failed: \(error)")
                            if isTransportError(error) {
                                // The session dropped during the anonymous
                                // fallback (server off/restarting, network blip)
                                // — not an auth problem.
                                throw ListError.unreachable
                            }
                            throw ListError.authenticationRequired
                        }
                    } else {
                        // The user typed a username/password and the server
                        // rejected them — surface that specifically.
                        throw ListError.credentialsRejected
                    }
                }

                // Some servers (e.g. Samba `map to guest = Bad User`) don't reject
                // a bad username/wrong password: they silently map it onto the
                // guest account and report SUCCESS with the IS_GUEST session flag.
                // If the user supplied credentials but we came back as guest, the
                // credentials were effectively rejected — say so rather than
                // letting the failed guest enumeration look like a generic error.
                // (Exempt users who *deliberately* typed guest/anonymous: landing
                // on a guest session is the expected success for them.)
                if account != nil,
                   account?.lowercased() != "guest",
                   account?.lowercased() != "anonymous",
                   client.session.isGuestSession {
                    PlozzLog.boot("share-list: supplied credentials were mapped to guest — treating as rejected")
                    try? await client.logoff()
                    throw ListError.credentialsRejected
                }

                // Step 2 — enumerate shares over IPC$/srvsvc. This can be denied
                // even when the file session is allowed; report it as a plain
                // failure so the caller offers the manual/credentials fallback.
                let shares: [Share]
                do {
                    shares = try await client.listShares()
                } catch {
                    PlozzLog.boot("share-list: enumerate failed: \(error)")
                    try? await client.logoff()
                    if isTransportError(error) {
                        // Session dropped mid-enumeration (server restart,
                        // network blip) — not an auth issue, so don't prompt
                        // for a password.
                        throw ListError.unreachable
                    }
                    if account == nil {
                        // Connected anonymously but the server won't list shares
                        // without a login (e.g. Samba `restrict anonymous = 2`):
                        // the fix is to supply credentials, so prompt for them.
                        throw ListError.authenticationRequired
                    }
                    // Authenticated fine but this account isn't permitted to
                    // enumerate — retrying the same credentials won't help.
                    throw ListError.failed("\(error)")
                }
                try? await client.logoff()
                let names = shares
                    .filter { isBrowsableDiskShare($0) }
                    .map(\.name)
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                PlozzLog.boot("share-list: \(shares.count) raw, \(names.count) browsable: \(names.joined(separator: ", "))")
                return names
            }
        } catch let e as ListError {
            throw e
        } catch is TimeoutError {
            PlozzLog.boot("share-list: timed out")
            throw ListError.timedOut
        } catch {
            PlozzLog.boot("share-list: error \(error)")
            if isTransportError(error) { throw ListError.unreachable }
            throw ListError.failed("\(error)")
        }
    }

    /// A share the user can actually browse: an ordinary disk tree that isn't a
    /// special/admin/IPC/print/device share and isn't a `$`-suffixed hidden one.
    private static func isBrowsableDiskShare(_ share: Share) -> Bool {
        let t = share.type
        if t.contains(.ipc) || t.contains(.special) || t.contains(.temporary)
            || t.contains(.printQueue) || t.contains(.device) {
            return false
        }
        if share.name.hasSuffix("$") { return false }
        return true
    }

    struct TimeoutError: Error {}

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
