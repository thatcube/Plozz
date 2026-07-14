import Foundation
import CoreModels
import CoreNetworking

/// One physical device (a "box") on the network, grouped from the per-transport
/// services discovered for its host. The onboarding UI lists boxes (one row per
/// device), then a box's doors become the Protocol options on the Connect form.
public struct DiscoveredMediaShareBox: Sendable, Hashable, Identifiable {
    /// A door into the box: a transport reachable on this host, and the port it
    /// was found on (`nil` = the transport default).
    public struct Door: Sendable, Hashable {
        public let transport: MediaShareTransportKind
        public let port: Int?
        public init(transport: MediaShareTransportKind, port: Int?) {
            self.transport = transport
            self.port = port
        }
    }

    public let host: String
    public let displayName: String
    public private(set) var doors: [Door]

    public var id: String { host.lowercased() }

    public init(host: String, displayName: String, doors: [Door]) {
        self.host = host
        self.displayName = displayName
        self.doors = doors
    }

    /// Merge a door in, de-duping on transport (a box lists each transport once;
    /// keeps the first-seen port unless the new one is more specific).
    mutating func addDoor(_ door: Door) {
        if let idx = doors.firstIndex(where: { $0.transport == door.transport }) {
            if doors[idx].port == nil, door.port != nil { doors[idx] = door }
        } else {
            doors.append(door)
        }
    }

    /// A copy of this box with additional doors merged in (used to fold curated
    /// port-sweep results into an advertised box during discovery).
    public func mergingDoors(_ newDoors: [Door]) -> DiscoveredMediaShareBox {
        var copy = self
        for door in newDoors { copy.addDoor(door) }
        return copy
    }
}

/// Groups a flat stream of `DiscoveredNetworkService`s into per-host boxes, so a
/// device that advertised several transports (or several records) shows up once.
public struct MediaShareBoxGrouping {
    /// Fold services into boxes keyed by lowercased host, preserving first-seen
    /// display name and order.
    public static func group(_ services: [DiscoveredNetworkService]) -> [DiscoveredMediaShareBox] {
        var order: [String] = []
        var byHost: [String: DiscoveredMediaShareBox] = [:]
        for service in services {
            let key = service.host.lowercased()
            let door = DiscoveredMediaShareBox.Door(transport: service.transport, port: service.port)
            if var box = byHost[key] {
                box.addDoor(door)
                byHost[key] = box
            } else {
                order.append(key)
                byHost[key] = DiscoveredMediaShareBox(
                    host: service.host,
                    displayName: service.name.isEmpty ? service.host : service.name,
                    doors: [door]
                )
            }
        }
        return order.compactMap { byHost[$0] }
    }
}

/// How a curated sweep target proves a protocol is actually present. An open TCP
/// socket alone is not enough for HTTP-family services: a NAS admin page on port
/// 80 must never be reported as WebDAV.
public enum MediaShareServiceProbeKind: Sendable, Hashable {
    /// HTTP WebDAV: require DAV-specific response evidence.
    case webDAVHTTP
    /// HTTPS WebDAV: same evidence, accepting a self-signed certificate only for
    /// this credential-free discovery probe (trust approval still happens later).
    case webDAVHTTPS
    /// SSH/SFTP: require an `SSH-` protocol banner.
    case sshBanner
    /// FTP: require a `220` service-ready banner.
    case ftpBanner
}

/// One concrete port + protocol confirmation strategy.
public struct TransportSweepTarget: Sendable, Hashable {
    public let port: Int
    public let probe: MediaShareServiceProbeKind

    public init(port: Int, probe: MediaShareServiceProbeKind) {
        self.port = port
        self.probe = probe
    }
}

/// One transport's curated confirmation targets on an already-known host.
public struct TransportSweepSpec: Sendable {
    public let transport: MediaShareTransportKind
    public let targets: [TransportSweepTarget]
    public let defaultPort: Int

    public init(
        transport: MediaShareTransportKind,
        targets: [TransportSweepTarget],
        defaultPort: Int
    ) {
        self.transport = transport
        self.targets = targets
        self.defaultPort = defaultPort
    }
}

/// Confirms a transport-specific service on a target. Injectable so the sweep is
/// unit-testable offline.
public protocol MediaShareServiceProbing: Sendable {
    func confirms(
        host: String,
        target: TransportSweepTarget,
        timeout: TimeInterval
    ) async -> Bool
}

/// Curated port sweep on a KNOWN host (Channel B, §1.1): probe each transport's
/// curated ports in parallel and report which doors answered. Bounded to the
/// curated list — never a full 65k scan (which is slow when firewalled and reads
/// as a port scan). This is how a box that didn't Bonjour-advertise a transport
/// (e.g. Unraid WebDAV on :8384) still gets found without the user typing it.
public struct MediaSharePortSweeper: Sendable {
    private let probe: any MediaShareServiceProbing
    private let timeout: TimeInterval

    public init(
        probe: any MediaShareServiceProbing = ProtocolServiceProbe(),
        timeout: TimeInterval = 1.5
    ) {
        self.probe = probe
        self.timeout = timeout
    }

    /// Returns the doors found on `host` across the given specs. A port equal to
    /// the transport default is reported with `port == nil` (implicit).
    public func sweep(host: String, specs: [TransportSweepSpec]) async -> [DiscoveredMediaShareBox.Door] {
        await withTaskGroup(of: DiscoveredMediaShareBox.Door?.self) { group in
            for spec in specs {
                for target in spec.targets {
                    group.addTask { [probe, timeout] in
                        guard await probe.confirms(
                            host: host,
                            target: target,
                            timeout: timeout
                        ) else {
                            return nil
                        }
                        return DiscoveredMediaShareBox.Door(
                            transport: spec.transport,
                            port: target.port == spec.defaultPort ? nil : target.port
                        )
                    }
                }
            }
            var found: [DiscoveredMediaShareBox.Door] = []
            for await door in group {
                if let door, !found.contains(door) { found.append(door) }
            }
            return found
        }
    }
}

#if canImport(Network)
import Network
#if canImport(Security)
import Security
#endif

/// Real protocol confirmation probe used by the curated sweep.
public struct ProtocolServiceProbe: MediaShareServiceProbing {
    public init() {}

    public func confirms(
        host: String,
        target: TransportSweepTarget,
        timeout: TimeInterval
    ) async -> Bool {
        switch target.probe {
        case .webDAVHTTP:
            return await confirmsWebDAV(
                host: host,
                port: target.port,
                scheme: "http",
                timeout: timeout
            )
        case .webDAVHTTPS:
            return await confirmsWebDAV(
                host: host,
                port: target.port,
                scheme: "https",
                timeout: timeout
            )
        case .sshBanner:
            return await confirmsBanner(
                host: host,
                port: target.port,
                timeout: timeout
            ) { $0.hasPrefix("SSH-") }
        case .ftpBanner:
            return await confirmsBanner(
                host: host,
                port: target.port,
                timeout: timeout
            ) { $0.hasPrefix("220") }
        }
    }

    /// Strict WebDAV confirmation. We intentionally do NOT treat any HTTP
    /// response as WebDAV: that previously labeled NAS admin pages as WebDAV.
    /// Accepted evidence is protocol-specific and credential-free:
    /// - `DAV` or `MS-Author-Via: DAV`
    /// - `Allow`/`Public` advertising `PROPFIND`
    /// - HTTP 207 Multi-Status
    /// - an auth realm explicitly naming WebDAV/DAV (covers Unraid's
    ///   `Basic realm="WebDAV-Login"` response before Apache adds `DAV`).
    private func confirmsWebDAV(
        host: String,
        port: Int,
        scheme: String,
        timeout: TimeInterval
    ) async -> Bool {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = "/"
        guard let url = components.url else { return false }

        let delegate = WebDAVProbeDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )
        var request = URLRequest(url: url)
        request.httpMethod = "OPTIONS"
        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return WebDAVResponseEvidence.confirms(
                statusCode: http.statusCode,
                headers: http.allHeaderFields
            )
        } catch {
            return false
        }
    }

    private func confirmsBanner(
        host: String,
        port: Int,
        timeout: TimeInterval,
        matches: @escaping @Sendable (String) -> Bool
    ) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0),
              port > 0 else {
            return false
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )
        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)
        let box = BannerProbeBox(matches: matches)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            box.attach(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(
                        minimumIncompleteLength: 1,
                        maximumLength: 512
                    ) { data, _, _, _ in
                        box.finish(data: data)
                    }
                case .failed, .cancelled: box.finish(false)
                default: break
                }
            }
            let queue = DispatchQueue(label: "com.plozz.portprobe")
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { box.finish(false) }
        }
    }

    private final class BannerProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private let matches: @Sendable (String) -> Bool
        private var continuation: CheckedContinuation<Bool, Never>?
        private var connection: NWConnection?

        init(matches: @escaping @Sendable (String) -> Bool) {
            self.matches = matches
        }

        func attach(continuation: CheckedContinuation<Bool, Never>, connection: NWConnection) {
            lock.lock(); self.continuation = continuation; self.connection = connection; lock.unlock()
        }

        func finish(data: Data?) {
            let banner = data.flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            finish(matches(banner))
        }

        func finish(_ value: Bool) {
            lock.lock()
            let c = continuation; continuation = nil
            let conn = connection; connection = nil
            lock.unlock()
            conn?.cancel()
            c?.resume(returning: value)
        }
    }
}

/// Pure WebDAV evidence matcher, separated for deterministic unit tests.
enum WebDAVResponseEvidence {
    static func confirms(
        statusCode: Int,
        headers: [AnyHashable: Any]
    ) -> Bool {
        if statusCode == 207 { return true }

        var normalized: [String: String] = [:]
        for (key, value) in headers {
            normalized[String(describing: key).lowercased()] =
                String(describing: value).lowercased()
        }
        if normalized["dav"]?.isEmpty == false { return true }
        if normalized["ms-author-via"]?.contains("dav") == true { return true }
        if normalized["allow"]?.contains("propfind") == true { return true }
        if normalized["public"]?.contains("propfind") == true { return true }
        if let challenge = normalized["www-authenticate"] {
            return challenge.contains("webdav") || challenge.contains("realm=\"dav")
        }
        return false
    }
}

private final class WebDAVProbeDelegate: NSObject, URLSessionTaskDelegate,
    URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A redirect to a NAS admin/login page is not WebDAV evidence.
        completionHandler(nil)
    }

    #if canImport(Security)
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod
            == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    #endif
}
#else
public struct ProtocolServiceProbe: MediaShareServiceProbing {
    public init() {}
    public func confirms(
        host: String,
        target: TransportSweepTarget,
        timeout: TimeInterval
    ) async -> Bool { false }
}
#endif
