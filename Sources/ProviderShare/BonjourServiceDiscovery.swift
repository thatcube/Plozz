import Foundation
import CoreModels
import CoreNetworking

/// A filesystem service found on the local network via Bonjour, tagged with the
/// transport that owns the advertised service type. The neutral, multi-transport
/// generalisation of `DiscoveredSMBServer` — the discovery engine yields these,
/// and the onboarding flow groups them into per-device "boxes".
public struct DiscoveredNetworkService: Sendable, Hashable, Identifiable {
    /// Which transport advertised this service (`_smb._tcp` → `.smb`, etc.).
    public let transport: MediaShareTransportKind
    /// Human-readable Bonjour instance name (e.g. "MyNAS"); falls back to `host`.
    public let name: String
    /// A connect target — a `.local` hostname or an IP literal.
    public let host: String
    /// Advertised port, if any (`nil` = use the transport's default).
    public let port: Int?

    public init(transport: MediaShareTransportKind, name: String, host: String, port: Int?) {
        self.transport = transport
        self.name = name
        self.host = host
        self.port = port
    }

    /// De-dup on transport + connect target, so one box's IPv4/IPv6 records for
    /// a given transport collapse to a single row.
    public var id: String {
        let portKey = port.map { ":\($0)" } ?? ""
        return "\(transport.rawValue)@\(host.lowercased())\(portKey)"
    }
}

/// Maps a Bonjour service type to the transport that owns it, plus that
/// transport's default port (so the engine can normalise an advertised default
/// port to `nil` without reaching up into a higher layer). Single source of
/// truth so the browser and its consumers agree.
public struct BonjourTransportMapping: Sendable {
    private struct Entry: Sendable {
        let transport: MediaShareTransportKind
        let defaultPort: Int?
    }
    private let byServiceType: [String: Entry]

    public init(_ pairs: [(serviceType: String, transport: MediaShareTransportKind, defaultPort: Int?)]) {
        var map: [String: Entry] = [:]
        for pair in pairs {
            map[pair.serviceType] = Entry(transport: pair.transport, defaultPort: pair.defaultPort)
        }
        self.byServiceType = map
    }

    public var serviceTypes: [String] { Array(byServiceType.keys) }
    public func transport(for serviceType: String) -> MediaShareTransportKind? {
        byServiceType[serviceType]?.transport
    }
    public func defaultPort(for transport: MediaShareTransportKind) -> Int? {
        byServiceType.values.first { $0.transport == transport }?.defaultPort
    }
}

#if canImport(Network)
import Network

/// Discovers filesystem services across ALL registered transports by browsing
/// each transport's Bonjour service type(s) with one `NWBrowser` per type, then
/// resolving each result to a connectable host/port. The engine half of
/// `SMBServiceDiscovery` (its `NWBrowser`/resolve/de-dup machinery) generalised
/// so a new transport is a mapping entry, not new discovery code.
public final class BonjourServiceDiscovery: @unchecked Sendable {
    private let mapping: BonjourTransportMapping

    public init(mapping: BonjourTransportMapping) {
        self.mapping = mapping
    }

    /// Streams unique `DiscoveredNetworkService`s as they resolve, finishing
    /// after `timeout` seconds (or when the consumer stops iterating).
    public func discover(timeout: TimeInterval = 6) -> AsyncStream<DiscoveredNetworkService> {
        AsyncStream { continuation in
            let box = ResolveBox(continuation: continuation)
            var browsers: [NWBrowser] = []
            let queue = DispatchQueue(label: "com.plozz.bonjour.discovery")

            for serviceType in mapping.serviceTypes {
                guard let transport = mapping.transport(for: serviceType) else { continue }
                let params = NWParameters()
                params.includePeerToPeer = true
                let browser = NWBrowser(
                    for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
                    using: params
                )
                browser.browseResultsChangedHandler = { results, _ in
                    for result in results {
                        guard case let .service(name, _, _, _) = result.endpoint else { continue }
                        box.resolve(
                            endpoint: result.endpoint,
                            serviceName: name,
                            transport: transport,
                            defaultPort: self.mapping.defaultPort(for: transport)
                        )
                    }
                }
                browser.stateUpdateHandler = { state in
                    if case .failed = state {
                        PlozzLog.boot("bonjour-discovery: browser failed for \(serviceType): \(state)")
                    }
                }
                browser.start(queue: queue)
                browsers.append(browser)
                PlozzLog.boot("bonjour-discovery: browsing \(serviceType)")
            }

            if browsers.isEmpty { continuation.finish(); return }

            let timeoutItem = DispatchWorkItem { box.finish() }
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            continuation.onTermination = { _ in
                timeoutItem.cancel()
                browsers.forEach { $0.cancel() }
                box.cancelAll()
            }
        }
    }

    /// Serialises browser callbacks + per-endpoint resolutions onto one box so the
    /// `NWConnection` resolvers, de-dup set, and stream termination don't race.
    /// Lifted from `SMBServiceDiscovery.ResolveBox`, now transport-aware.
    private final class ResolveBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<DiscoveredNetworkService>.Continuation?
        private var seen = Set<String>()
        private var connections: [ObjectIdentifier: NWConnection] = [:]

        init(continuation: AsyncStream<DiscoveredNetworkService>.Continuation) {
            self.continuation = continuation
        }

        func resolve(endpoint: NWEndpoint, serviceName: String, transport: MediaShareTransportKind, defaultPort: Int?) {
            let connection = NWConnection(to: endpoint, using: .tcp)
            let key = ObjectIdentifier(connection)
            lock.lock()
            guard continuation != nil else { lock.unlock(); return }
            connections[key] = connection
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let (host, port) = Self.hostPort(from: connection.currentPath?.remoteEndpoint) {
                        self.emit(transport: transport, name: serviceName, host: host, port: port, defaultPort: defaultPort)
                    }
                    self.tearDown(key)
                case .failed, .cancelled:
                    self.tearDown(key)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.plozz.bonjour.resolve"))
        }

        private func emit(transport: MediaShareTransportKind, name: String, host: String, port: Int?, defaultPort: Int?) {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation else { return }
            // De-dup per transport + host so IPv4/IPv6 or repeat announcements for
            // one box collapse to one row per transport.
            let dedupeKey = "\(transport.rawValue)@\(host.lowercased())"
            guard seen.insert(dedupeKey).inserted else { return }
            let cleanName = name.isEmpty ? host : name
            let cleanPort = (port == defaultPort || port == nil) ? nil : port
            PlozzLog.boot("bonjour-discovery: \(transport.rawValue) \(cleanName) @ \(host)\(cleanPort.map { ":\($0)" } ?? "")")
            continuation.yield(
                DiscoveredNetworkService(transport: transport, name: cleanName, host: host, port: cleanPort)
            )
        }

        private func tearDown(_ key: ObjectIdentifier) {
            lock.lock()
            let connection = connections.removeValue(forKey: key)
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
            continuation = nil
            lock.unlock()
            all.forEach { $0.cancel() }
        }

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
/// Non-Network platforms get an inert discoverer so onboarding still compiles.
public final class BonjourServiceDiscovery: @unchecked Sendable {
    public init(mapping: BonjourTransportMapping) {}
    public func discover(timeout: TimeInterval = 6) -> AsyncStream<DiscoveredNetworkService> {
        AsyncStream { $0.finish() }
    }
}
#endif
